variable "domain_name" {
  description = "Domain you own — the public hosted zone created here must be delegated at your registrar (one-time NS copy, see docs/BOOTSTRAP.md)"
  type        = string
}

variable "ssm_parameter_prefix" {
  description = "Prefix for the SSM parameters publishing the zone id (empty = skip)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags for all resources"
  type        = map(string)
  default     = {}
}
