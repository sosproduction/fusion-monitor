# =============================================================================
# infrastructure/outputs.tf
# =============================================================================

output "alb_dns_name" {
  description = "ALB DNS name — point your domain here if not using Route 53"
  value       = aws_lb.main.dns_name
}

output "react_dashboard_url" {
  value = "https://${var.domain}"
}

output "grafana_url" {
  value = "https://grafana.${var.domain}"
}

output "prometheus_url" {
  value = "https://prometheus.${var.domain}"
}

output "kafka_ui_url" {
  value = "https://kafka.${var.domain}"
}

output "kafka_bootstrap_brokers" {
  description = "MSK bootstrap broker string — use in producer/consumer config"
  value       = aws_msk_cluster.main.bootstrap_brokers
  sensitive   = true
}

output "rds_endpoint" {
  description = "TimescaleDB RDS endpoint"
  value       = aws_db_instance.timescaledb.address
}

output "ecr_registry" {
  description = "ECR registry base URL"
  value       = "${var.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}
