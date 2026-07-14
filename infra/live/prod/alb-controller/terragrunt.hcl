include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/alb-controller"
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    vpc_id = "vpc-mock"
  }
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
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
  vpc_id            = dependency.vpc.outputs.vpc_id
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn
}
