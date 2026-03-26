# =============================================================================
# infrastructure/managed-services.tf
# Amazon MSK (Managed Kafka) + Amazon RDS (TimescaleDB via custom image on ECS)
# =============================================================================

# =============================================================================
# Amazon MSK — Managed Kafka
# Replaces the self-managed kafka + zookeeper containers
# =============================================================================

resource "aws_msk_cluster" "main" {
  cluster_name           = "${var.project}-kafka"
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 2       # 2 brokers across 2 AZs for HA

  broker_node_group_info {
    instance_type   = "kafka.t3.small"    # sufficient for demo workload
    client_subnets  = module.vpc.private_subnets
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = 20   # GB per broker
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "PLAINTEXT"   # simplifies producer/consumer config
      in_cluster    = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.main.arn
    revision = aws_msk_configuration.main.latest_revision
  }
}

resource "aws_msk_configuration" "main" {
  name              = "${var.project}-kafka-config"
  kafka_versions    = ["3.6.0"]
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
# RDS — PostgreSQL 16 with TimescaleDB extension
# Using a custom parameter group to enable TimescaleDB
# =============================================================================

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_db_parameter_group" "timescale" {
  name   = "${var.project}-timescaledb-pg16"
  family = "postgres16"

  parameter {
    name  = "shared_preload_libraries"
    value = "timescaledb"
    apply_method = "pending-reboot"
  }
  parameter {
    name  = "max_connections"
    value = "100"
  }
}

resource "aws_db_instance" "timescaledb" {
  identifier             = "${var.project}-timescaledb"
  engine                 = "postgres"
  engine_version         = "16.3"
  instance_class         = "db.t3.medium"
  allocated_storage      = 50
  max_allocated_storage  = 200    # autoscale up to 200 GB

  db_name  = "fusiondb"
  username = "fusion"
  password = var.db_password     # passed via TF_VAR_db_password env var in CI

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.timescale.name

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  deletion_protection     = false   # set true for production
  skip_final_snapshot     = true    # set false for production
  multi_az                = false   # set true for production HA

  # Run init.sql via a Lambda or ECS one-shot task after creation
  # (see scripts/run-migrations.sh)
}

# Store DB endpoint and MSK bootstrap in SSM Parameter Store
# so ECS tasks can read them at startup without hardcoding
resource "aws_ssm_parameter" "db_host" {
  name  = "/${var.project}/DB_HOST"
  type  = "String"
  value = aws_db_instance.timescaledb.address
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/${var.project}/DB_PASSWORD"
  type  = "SecureString"
  value = var.db_password
}

resource "aws_ssm_parameter" "kafka_bootstrap" {
  name  = "/${var.project}/KAFKA_BOOTSTRAP"
  type  = "String"
  value = aws_msk_cluster.main.bootstrap_brokers
}
