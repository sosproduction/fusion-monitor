# =============================================================================
# infrastructure/managed-services.tf
# Amazon MSK (Managed Kafka) + TimescaleDB on ECS Fargate + EFS
#
# NOTE: TimescaleDB is NOT supported as an RDS extension.
# We run it as a Fargate container with EFS persistent storage instead --
# identical to the local docker-compose setup, zero extra cost.
# =============================================================================

# =============================================================================
# Amazon MSK -- Managed Kafka
# =============================================================================

resource "aws_msk_cluster" "main" {
  cluster_name           = "${var.project}-kafka"
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = module.vpc.private_subnets
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = 20
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "PLAINTEXT"
      in_cluster    = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.main.arn
    revision = aws_msk_configuration.main.latest_revision
  }
}

resource "aws_msk_configuration" "main" {
  name           = "${var.project}-kafka-config"
  kafka_versions = ["3.6.0"]
  server_properties = <<-PROPS
    auto.create.topics.enable=true
    default.replication.factor=2
    min.insync.replicas=1
    num.partitions=3
    log.retention.hours=168
    log.segment.bytes=104857600
  PROPS
}

# =============================================================================
# EFS -- Persistent storage for TimescaleDB data
# EFS survives container restarts and redeployments
# =============================================================================

resource "aws_efs_file_system" "timescaledb" {
  creation_token   = "${var.project}-timescaledb-data"
  performance_mode = "generalPurpose"
  encrypted        = true

  tags = {
    Name = "${var.project}-timescaledb-data"
  }
}

resource "aws_efs_mount_target" "timescaledb" {
  count           = length(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.timescaledb.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.ecs_tasks.id]
}

# EFS access point -- scopes the container to /timescaledb path
resource "aws_efs_access_point" "timescaledb" {
  file_system_id = aws_efs_file_system.timescaledb.id

  posix_user {
    uid = 999   # postgres user in the timescaledb image
    gid = 999
  }

  root_directory {
    path = "/timescaledb"
    creation_info {
      owner_uid   = 999
      owner_gid   = 999
      permissions = "755"
    }
  }
}

# =============================================================================
# ECS -- TimescaleDB Fargate service
# Uses official timescale/timescaledb image
# =============================================================================

resource "aws_ecs_task_definition" "timescaledb" {
  family                   = "timescaledb"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"   # 1 vCPU
  memory                   = "2048"   # 2 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "timescaledb"
    image     = "timescale/timescaledb:latest-pg16"
    essential = true
    portMappings = [{ containerPort = 5432, protocol = "tcp" }]

    environment = [
      { name = "POSTGRES_DB",       value = "fusiondb" },
      { name = "POSTGRES_USER",     value = "fusion" },
      { name = "PGDATA",            value = "/var/lib/postgresql/data/pgdata" }
    ]
    secrets = [
      { name = "POSTGRES_PASSWORD", valueFrom = "/${var.project}/DB_PASSWORD" }
    ]

    mountPoints = [{
      sourceVolume  = "timescaledb-data"
      containerPath = "/var/lib/postgresql/data"
      readOnly      = false
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project}/timescaledb"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  volume {
    name = "timescaledb-data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.timescaledb.id
      transit_encryption = "DISABLED"
    }
  }
}

resource "aws_ecs_service" "timescaledb" {
  name            = "timescaledb"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.timescaledb.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Must wait for EFS mount targets to be ready
  depends_on = [aws_efs_mount_target.timescaledb]

  network_configuration {
    subnets         = module.vpc.private_subnets
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  # Prevent Terraform from restarting the DB on every apply
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# CloudWatch log group for TimescaleDB
resource "aws_cloudwatch_log_group" "timescaledb" {
  name              = "/ecs/${var.project}/timescaledb"
  retention_in_days = 14
}

# =============================================================================
# SSM Parameter Store -- runtime config for all ECS tasks
# =============================================================================

resource "aws_ssm_parameter" "db_host" {
  name      = "/${var.project}/DB_HOST"
  type      = "String"
  # Tasks connect to TimescaleDB by its ECS service discovery name
  value     = "timescaledb.${var.project}.local"
  overwrite = true
}

resource "aws_ssm_parameter" "db_password" {
  name      = "/${var.project}/DB_PASSWORD"
  type      = "SecureString"
  value     = var.db_password
  overwrite = true
}

resource "aws_ssm_parameter" "kafka_bootstrap" {
  name      = "/${var.project}/KAFKA_BOOTSTRAP"
  type      = "String"
  value     = aws_msk_cluster.main.bootstrap_brokers
  overwrite = true
}
