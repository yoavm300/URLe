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
