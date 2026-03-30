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
  description = "Full subdomain for the app e.g. fusion-monitor.southofsleep.com"
  type        = string
}

variable "hosted_zone_name" {
  description = "The Route 53 hosted zone root domain e.g. southofsleep.com"
  type        = string
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
