variable "identifier" {
  description = "RDS instance identifier"
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16.6"
}

variable "instance_class" {
  description = "Instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Storage in GiB"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Initial database name"
  type        = string
}

variable "username" {
  description = "Master username (password is generated into Secrets Manager)"
  type        = string
}

variable "multi_az" {
  description = "Enable Multi-AZ standby"
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "VPC for the security group"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet ids for the DB subnet group"
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach Postgres (EKS node SG)"
  type        = list(string)
}

variable "tags" {
  description = "Extra tags for all resources"
  type        = map(string)
  default     = {}
}

variable "deletion_protection" {
  description = "Refuse instance deletion at the API level. Off only for environments that ride automated teardown cycles — the final snapshot still guards the data."
  type        = bool
  default     = true
}

variable "master_password_ssm_path" {
  description = "SSM SecureString holding the master password (created manually — see docs/BOOTSTRAP.md)"
  type        = string
}

variable "app_secret_name" {
  description = "Secrets Manager secret this module composes for the chart's ExternalSecret (empty = skip)"
  type        = string
  default     = ""
}

variable "secret_key_ssm_path" {
  description = "SSM SecureString holding the Flask SECRET_KEY (used only when app_secret_name is set)"
  type        = string
  default     = ""
}

variable "redis_password_ssm_path" {
  description = "SSM SecureString holding the in-cluster Redis password (used only when app_secret_name is set)"
  type        = string
  default     = ""
}

variable "redis_host" {
  description = "In-cluster Redis service name for RATELIMIT_STORAGE_URI"
  type        = string
  default     = "redis"
}

variable "ssm_parameter_prefix" {
  description = "Prefix for the SSM parameters publishing the endpoint (empty = skip)"
  type        = string
  default     = ""
}
