include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/argocd"
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state  = "shallow"
  mock_outputs = {
    cluster_name                       = "mock-cluster"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw=="
  }
}

# Ordering-only (no outputs consumed): ArgoCD auto-syncs the app chart the
# moment it installs, so everything the chart's resources need on a cold
# bootstrap must exist first — the ALB controller (chart Ingress), ExternalDNS
# (public record), the ExternalSecret backend, RDS (DATABASE_URL target), and
# the Prometheus Operator CRDs (chart ServiceMonitors).
dependencies {
  paths = [
    "../ingress-nginx",
    "../external-secrets",
    "../rds-postgres",
    "../alb-controller",
    "../external-dns",
    "../monitoring",
    # CloudFront must own the public urle.<domain> record before ExternalDNS
    # (triggered by the chart's Ingress) gets a chance to create it — with the
    # record already present and unowned, upsert-only ExternalDNS skips it and
    # manages only the origin hostname.
    "../cloudfront",
  ]
}

inputs = {
  cluster_name     = dependency.eks.outputs.cluster_name
  cluster_endpoint = dependency.eks.outputs.cluster_endpoint
  cluster_ca_data  = dependency.eks.outputs.cluster_certificate_authority_data
  aws_region       = local.env.aws_region
  environment      = local.env.env

  gitops_repo_url = "https://github.com/yoavm300/URLe.git"
  gitops_revision = "main"

  # The repo is private — fine-grained PAT from the manual SSM parameter
  # (docs/BOOTSTRAP.md §4). Shared by both environments, hence global.
  gitops_token_ssm_path = "/urle/global/github/gitops-token"

  # VPN-only UI — resolves via the urle-prod.internal private zone.
  ingress_host = "argocd.urle-${local.env.env}.internal"
}
