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
  description = "kube-prometheus-stack Helm chart version (SemVer, pinned)"
  type        = string
  default     = "87.16.1"
}
