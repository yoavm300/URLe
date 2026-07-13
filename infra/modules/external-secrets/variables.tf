variable "cluster_name" {
  description = "EKS cluster name (for the exec token helper and resource naming)"
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
  description = "Region of the cluster and the Secrets Manager secrets"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS IRSA OIDC provider ARN (eks module output)"
  type        = string
}

variable "app_namespace" {
  description = "Namespace running the app (where the SecretStore SA lives)"
  type        = string
  default     = "urle-prod"
}

variable "service_account_name" {
  description = "In-namespace SA the SecretStore authenticates as (chart item 10)"
  type        = string
  default     = "urle-external-secrets"
}

variable "secrets_path_prefix" {
  description = "Secrets Manager path prefix the role may read (no trailing /*)"
  type        = string
  default     = "urle/prod"
}

variable "chart_version" {
  description = "external-secrets Helm chart version (SemVer, pinned)"
  type        = string
  default     = "0.10.7"
}
