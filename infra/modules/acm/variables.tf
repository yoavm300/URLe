variable "domain_name" {
  description = "FQDN the certificate covers (e.g. urle.example.com)"
  type        = string
}

variable "zone_id" {
  description = "Public hosted zone for the DNS validation records"
  type        = string
}

variable "ssm_parameter_prefix" {
  description = "Prefix for the SSM parameter publishing the certificate ARN (empty = skip)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags for all resources"
  type        = map(string)
  default     = {}
}
