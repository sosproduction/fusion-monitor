# =============================================================================
# infrastructure/ecs-services.tf
# ECS Fargate service definitions for all fusion-monitor containers
# =============================================================================

locals {
  ecr_base = "${var.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

# =============================================================================
# Helper: reusable task definition template
# =============================================================================

# fusion-producer ─────────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "fusion_producer" {
  family                   = "fusion-producer"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "fusion-producer"
    image     = "${local.ecr_base}/fusion-producer:latest"
    essential = true
    environment = [
      { name = "KAFKA_TOPIC",      value = "metrics.fusion-reactor" },
      { name = "PUBLISH_INTERVAL", value = "5" }
    ]
    secrets = [
      { name = "KAFKA_BOOTSTRAP", valueFrom = "/${var.project}/KAFKA_BOOTSTRAP" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project}/fusion-producer"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "fusion_producer" {
  name            = "fusion-producer"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.fusion_producer.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }
}

# prometheus-bridge ───────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "prometheus_bridge" {
  family                   = "prometheus-bridge"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "prometheus-bridge"
    image     = "${local.ecr_base}/prometheus-bridge:latest"
    essential = true
    environment = [
      { name = "KAFKA_TOPICS",      value = "metrics.fusion-reactor" },
      { name = "KAFKA_GROUP_ID",    value = "prometheus-bridge" },
      { name = "PUSHGATEWAY_URL",   value = "http://pushgateway.${var.project}.local:9091" },
      { name = "PUSH_INTERVAL_S",   value = "5" }
    ]
    secrets = [
      { name = "KAFKA_BOOTSTRAP", valueFrom = "/${var.project}/KAFKA_BOOTSTRAP" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project}/prometheus-bridge"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "prometheus_bridge" {
  name            = "prometheus-bridge"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.prometheus_bridge.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = module.vpc.private_subnets
    security_groups = [aws_security_group.ecs_tasks.id]
  }
}

# timescale-writer ────────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "timescale_writer" {
  family                   = "timescale-writer"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "timescale-writer"
    image     = "${local.ecr_base}/timescale-writer:latest"
    essential = true
    environment = [
      { name = "KAFKA_TOPICS",      value = "metrics.fusion-reactor" },
      { name = "KAFKA_GROUP_ID",    value = "timescale-writer" },
      { name = "BATCH_SIZE",        value = "200" },
      { name = "FLUSH_INTERVAL_S",  value = "5" }
    ]
    secrets = [
      { name = "KAFKA_BOOTSTRAP", valueFrom = "/${var.project}/KAFKA_BOOTSTRAP" },
      { name = "DB_HOST",         valueFrom = "/${var.project}/DB_HOST" },
      { name = "DB_PASSWORD",     valueFrom = "/${var.project}/DB_PASSWORD" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project}/timescale-writer"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "timescale_writer" {
  name            = "timescale-writer"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.timescale_writer.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = module.vpc.private_subnets
    security_groups = [aws_security_group.ecs_tasks.id]
  }
}

# prometheus ──────────────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "prometheus" {
  family                   = "prometheus"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "prometheus"
    image     = "prom/prometheus:v2.51.0"
    essential = true
    portMappings = [{ containerPort = 9090, protocol = "tcp" }]
    command = [
      "--config.file=/etc/prometheus/prometheus.yml",
      "--storage.tsdb.path=/prometheus",
      "--storage.tsdb.retention.time=15d",
      "--web.enable-lifecycle"
    ]
    mountPoints = [
      { sourceVolume = "prometheus-config", containerPath = "/etc/prometheus" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project}/prometheus"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  volume {
    name = "prometheus-config"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.prometheus_config.id
      transit_encryption = "ENABLED"
    }
  }
}

resource "aws_ecs_service" "prometheus" {
  name            = "prometheus"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.prometheus.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = module.vpc.private_subnets
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.prometheus.arn
    container_name   = "prometheus"
    container_port   = 9090
  }
}

# grafana ─────────────────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "grafana" {
  family                   = "grafana"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "grafana"
    image     = "grafana/grafana:10.4.0"
    essential = true
    portMappings = [{ containerPort = 3000, protocol = "tcp" }]
    environment = [
      { name = "GF_SECURITY_ADMIN_USER",     value = "admin" },
      { name = "GF_USERS_ALLOW_SIGN_UP",     value = "false" },
      { name = "GF_SERVER_ROOT_URL",         value = "https://grafana.${var.domain}" }
    ]
    secrets = [
      { name = "GF_SECURITY_ADMIN_PASSWORD", valueFrom = "/${var.project}/GRAFANA_PASSWORD" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project}/grafana"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "grafana" {
  name            = "grafana"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = module.vpc.private_subnets
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.grafana.arn
    container_name   = "grafana"
    container_port   = 3000
  }
}

# fusion-ui ───────────────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "fusion_ui" {
  family                   = "fusion-ui"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "fusion-ui"
    image     = "${local.ecr_base}/fusion-ui:latest"
    essential = true
    portMappings = [{ containerPort = 80, protocol = "tcp" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project}/fusion-ui"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "fusion_ui" {
  name            = "fusion-ui"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.fusion_ui.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = module.vpc.private_subnets
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.fusion_ui.arn
    container_name   = "fusion-ui"
    container_port   = 80
  }
}

# pushgateway ─────────────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "pushgateway" {
  family                   = "pushgateway"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "pushgateway"
    image     = "prom/pushgateway:v1.8.0"
    essential = true
    portMappings = [{ containerPort = 9091, protocol = "tcp" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project}/pushgateway"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "pushgateway" {
  name            = "pushgateway"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.pushgateway.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = module.vpc.private_subnets
    security_groups = [aws_security_group.ecs_tasks.id]
  }
}

# kafka-ui ────────────────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "kafka_ui" {
  family                   = "kafka-ui"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "kafka-ui"
    image     = "provectuslabs/kafka-ui:latest"
    essential = true
    portMappings = [{ containerPort = 8080, protocol = "tcp" }]
    secrets = [
      { name = "KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS", valueFrom = "/${var.project}/KAFKA_BOOTSTRAP" }
    ]
    environment = [
      { name = "KAFKA_CLUSTERS_0_NAME", value = "fusion-cluster" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/${var.project}/kafka-ui"
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "kafka_ui" {
  name            = "kafka-ui"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.kafka_ui.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = module.vpc.private_subnets
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.kafka_ui.arn
    container_name   = "kafka-ui"
    container_port   = 8080
  }
}

# =============================================================================
# EFS — persistent storage for Prometheus config + TSDB data
# =============================================================================

resource "aws_efs_file_system" "prometheus_config" {
  creation_token   = "${var.project}-prometheus-config"
  performance_mode = "generalPurpose"
  encrypted        = true
}

resource "aws_efs_mount_target" "prometheus_config" {
  for_each        = toset(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.prometheus_config.id
  subnet_id       = each.value
  security_groups = [aws_security_group.ecs_tasks.id]
}
