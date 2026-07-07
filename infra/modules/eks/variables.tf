variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  description = "VPC to place the cluster in"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet ids for nodes and control-plane ENIs"
  type        = list(string)
}

variable "node_instance_types" {
  description = "Instance types for the managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  description = "Minimum node count"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum node count"
  type        = number
  default     = 3
}

variable "node_desired_size" {
  description = "Desired node count"
  type        = number
  default     = 2
}

variable "tags" {
  description = "Extra tags for all resources"
  type        = map(string)
  default     = {}
}
