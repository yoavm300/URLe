variable "cluster_name" {
  description = "EKS cluster name (for the exec token helper and controller config)"
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
  description = "Region of the cluster"
  type        = string
}

variable "vpc_id" {
  description = "VPC the ALBs are created in"
  type        = string
}

variable "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN from the eks unit"
  type        = string
}

variable "chart_version" {
  description = "aws-load-balancer-controller Helm chart version (SemVer, pinned)"
  type        = string
  default     = "1.11.0"
}

variable "cloudfront_only_sg_name" {
  description = "Name for an ALB frontend SG admitting only CloudFront's origin-facing ranges (empty = skip). The chart's Ingress references it by this exact name via the security-groups annotation."
  type        = string
  default     = ""
}
