# =============================================================================
# infrastructure/variables.tf
# =============================================================================

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name used as prefix for all resources"
  type        = string
  default     = "fusion-monitor"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "production"
}

variable "domain" {
  description = "Root domain name — must have a Route 53 hosted zone"
  type        = string
  # e.g. "fusion-monitor.yourdomain.com"
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}

variable "db_password" {
  description = "TimescaleDB / RDS master password"
  type        = string
  sensitive   = true
}
