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
