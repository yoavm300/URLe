variable "name" {
  description = "Repository name"
  type        = string
}

variable "keep_last_images" {
  description = "How many images the lifecycle policy retains"
  type        = number
  default     = 20
}

variable "tags" {
  description = "Extra tags for all resources"
  type        = map(string)
  default     = {}
}

variable "ssm_parameter_prefix" {
  description = "Prefix for the SSM parameter publishing the repository URL (empty = skip)"
  type        = string
  default     = ""
}
