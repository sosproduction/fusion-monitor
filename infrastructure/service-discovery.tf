# =============================================================================
# infrastructure/service-discovery.tf
# AWS Cloud Map private DNS namespace
# Gives every ECS service a stable DNS name inside the VPC:
#   pushgateway.fusion-monitor.local:9091
#   timescaledb.fusion-monitor.local:5432
#   prometheus.fusion-monitor.local:9090
# =============================================================================

# Private DNS namespace — creates a Route 53 private hosted zone
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "${var.project}.local"
  description = "Private DNS for ${var.project} ECS services"
  vpc         = module.vpc.vpc_id
}

# Service registry entries — one per service that needs to be discovered
resource "aws_service_discovery_service" "pushgateway" {
  name = "pushgateway"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "timescaledb" {
  name = "timescaledb"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_service_discovery_service" "prometheus" {
  name = "prometheus"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}
