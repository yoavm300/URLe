variable "zone_name" {
  description = "Private hosted zone name (e.g. urle-dev.internal)"
  type        = string
}

variable "vpc_id" {
  description = "VPC the private zone is associated with (resolvable only from inside it / over the VPN)"
  type        = string
}

variable "records" {
  description = "Subdomain records to create, all pointing at target_dns_name"
  type        = list(string)
  default     = ["argocd", "grafana"]
}

variable "target_dns_name" {
  description = "DNS name the records point at (the internal ingress NLB)"
  type        = string
}

variable "tags" {
  description = "Extra tags for all resources"
  type        = map(string)
  default     = {}
}
