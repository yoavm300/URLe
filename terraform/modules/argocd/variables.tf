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

variable "environment" {
  description = "Environment name; selects helm/git-ops/<environment>.yaml"
  type        = string
}

variable "chart_version" {
  description = "argo-cd Helm chart version (SemVer, pinned)"
  type        = string
  default     = "7.7.11"
}

variable "apps_chart_version" {
  description = "argocd-apps Helm chart version (SemVer, pinned)"
  type        = string
  default     = "2.0.2"
}

variable "gitops_repo_url" {
  description = "Git repository Argo CD watches"
  type        = string
}

variable "gitops_revision" {
  description = "Branch or tag Argo CD tracks"
  type        = string
  default     = "main"
}

variable "ingress_host" {
  description = "Hostname for the ArgoCD UI ingress on the internal nginx class (empty = no ingress, port-forward only)"
  type        = string
  default     = ""
}
