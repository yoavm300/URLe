variable "cluster_name" {
  description = "EKS cluster name (for the exec token helper and discovery tags)"
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

variable "node_security_group_id" {
  description = "EKS node security group id to tag for discovery (eks module output)"
  type        = string
}

variable "chart_version" {
  description = "Karpenter Helm (OCI) chart version (SemVer, pinned)"
  type        = string
  default     = "1.14.0"
}

variable "nodepool_cpu_limit" {
  description = "Max total vCPUs Karpenter may provision for the default NodePool"
  type        = string
  default     = "100"
}

variable "tags" {
  description = "Extra tags for all resources"
  type        = map(string)
  default     = {}
}
