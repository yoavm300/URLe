include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/external-secrets"
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs = {
    cluster_name                       = "mock-cluster"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw=="
    oidc_provider_arn                  = "arn:aws:iam::111111111111:oidc-provider/mock"
  }
}

inputs = {
  cluster_name      = dependency.eks.outputs.cluster_name
  cluster_endpoint  = dependency.eks.outputs.cluster_endpoint
  cluster_ca_data   = dependency.eks.outputs.cluster_certificate_authority_data
  aws_region        = local.env.aws_region
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn

  # SecretStore SA namespace + Secrets Manager path scope, per environment.
  app_namespace        = "urle-${local.env.env}"
  secrets_path_prefix  = "urle/${local.env.env}"
  ssm_parameter_prefix = "/urle/${local.env.env}"
}
