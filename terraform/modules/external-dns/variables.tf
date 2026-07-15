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
  description = "Region of the cluster"
  type        = string
}

variable "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN from the eks unit"
  type        = string
}

variable "zone_arn" {
  description = "Public hosted zone ARN — the only zone the IRSA role may write records into"
  type        = string
}

variable "domain_filter" {
  description = "Domain ExternalDNS manages records for (the public zone's name)"
  type        = string
}

variable "txt_owner_id" {
  description = "Ownership marker written into TXT records so parallel ExternalDNS instances never fight over records"
  type        = string
}

variable "chart_version" {
  description = "external-dns Helm chart version (SemVer, pinned)"
  type        = string
  default     = "1.21.1"
}
