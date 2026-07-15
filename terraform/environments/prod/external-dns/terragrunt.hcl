include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/external-dns"
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    cluster_name                       = "mock-cluster"
    cluster_endpoint                   = "https://mock.eks.amazonaws.com"
    cluster_certificate_authority_data = "bW9jaw=="
    oidc_provider_arn                  = "arn:aws:iam::111111111111:oidc-provider/mock"
  }
}

dependency "public_zone" {
  config_path = "../../global/route53-public-zone"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    zone_id   = "Z0MOCK"
    zone_name = "example.com"
    zone_arn  = "arn:aws:route53:::hostedzone/Z0MOCK"
  }
}

inputs = {
  cluster_name      = dependency.eks.outputs.cluster_name
  cluster_endpoint  = dependency.eks.outputs.cluster_endpoint
  cluster_ca_data   = dependency.eks.outputs.cluster_certificate_authority_data
  aws_region        = local.env.aws_region
  oidc_provider_arn = dependency.eks.outputs.oidc_provider_arn

  zone_arn      = dependency.public_zone.outputs.zone_arn
  domain_filter = dependency.public_zone.outputs.zone_name
  txt_owner_id  = "urle-${local.env.env}"
}
