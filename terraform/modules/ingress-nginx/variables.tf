variable "cluster_name" {
  description = "EKS cluster name (for the exec token helper)"
  type        = string
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  type        = string
}

variable "cluster_ca_data" {
  description = "Base64-encoded cluster CA certificate"
  type        = string
}

variable "aws_region" {
  description = "Region of the cluster (for the exec token helper)"
  type        = string
}

variable "chart_version" {
  description = "ingress-nginx Helm chart version (SemVer, pinned)"
  type        = string
  default     = "4.15.1"
}

variable "internal" {
  description = "Provision the NLB as internal (VPC/VPN-only) instead of internet-facing"
  type        = bool
  default     = false
}

variable "edge" {
  description = <<-EOT
    Public edge in front of this controller (prod): an alb-class Ingress that
    makes the AWS LB Controller build an internet-facing ALB whose only target
    is the nginx controller pods (target-type ip — the internal NLB for admin
    traffic is unaffected). Requests must carry the X-Origin-Verify secret
    CloudFront attaches (origin_verify_value, from the cloudfront unit) or
    they fall through to the ALB's default 404. Disabled by default (dev).
  EOT
  type = object({
    enabled           = bool
    hosts             = optional(list(string), [])
    group_name        = optional(string, "")
    security_group_id = optional(string, "")
  })
  default = { enabled = false }
}

# Separate from var.edge: sensitive values can't drive count/for_each, and the
# edge resources are count-gated on edge.enabled.
variable "edge_origin_verify_value" {
  description = "Secret X-Origin-Verify value the ALB requires on every request (cloudfront unit output). Required when edge.enabled."
  type        = string
  default     = ""
  sensitive   = true
}
