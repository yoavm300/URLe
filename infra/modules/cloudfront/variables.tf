variable "domain_name" {
  description = "Public hostname end users hit (e.g. urle.example.com) — becomes the distribution alias and its Route53 record"
  type        = string
}

variable "origin_hostname" {
  description = "Stable hostname CloudFront forwards to (e.g. urle-origin.example.com). Doesn't need to resolve at apply time — ExternalDNS points it at the ALB once the Ingress exists; CloudFront only resolves origins per-request"
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate for the viewer-facing alias (must live in us-east-1 — a CloudFront requirement)"
  type        = string
}

variable "zone_id" {
  description = "Public hosted zone for the alias record"
  type        = string
}

variable "price_class" {
  description = "Edge-location coverage tier"
  type        = string
  default     = "PriceClass_100" # NA + EU — cheapest, plenty for this project
}

variable "ssm_parameter_prefix" {
  description = "Prefix for the SSM parameter publishing the distribution id (empty = skip)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags for all resources"
  type        = map(string)
  default     = {}
}
