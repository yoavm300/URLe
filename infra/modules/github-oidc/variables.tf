variable "github_repository" {
  description = "GitHub org/repo allowed to assume the CI roles (e.g. yoavm300/URLe)"
  type        = string
}

variable "role_name_prefix" {
  description = "Prefix for all IAM role names created here"
  type        = string
  default     = "urle"
}

variable "ecr_repository_prefix" {
  description = "ECR repository name prefix the release role may push to"
  type        = string
  default     = "urle-"
}

variable "lock_table_arn" {
  description = "DynamoDB lock table ARN the CI roles need until S3-native locking lands (empty = skip)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags for all resources"
  type        = map(string)
  default     = {}
}
