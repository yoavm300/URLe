include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/eks"
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    vpc_id             = "vpc-mock"
    private_subnet_ids = ["subnet-mock-a", "subnet-mock-b"]
  }
}

dependency "github_oidc" {
  config_path = "../../global/github-oidc"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    dev_ci_role_arn  = "arn:aws:iam::111111111111:role/mock-dev-cicd"
    prod_ci_role_arn = "arn:aws:iam::111111111111:role/mock-prod-cicd"
  }
}

inputs = {
  cluster_name = local.env.cluster_name
  vpc_id       = dependency.vpc.outputs.vpc_id
  subnet_ids   = dependency.vpc.outputs.private_subnet_ids

  # Set locally and as a GitHub Actions secret — see docs/BOOTSTRAP.md.
  # Empty means no personal access entry, and kubectl/helm will be locked out.
  admin_principal_arn = get_env("ADMIN_PRINCIPAL_ARN", "")
  cicd_principal_arn  = dependency.github_oidc.outputs.dev_ci_role_arn

  node_instance_types = ["t3.medium"]
  node_min_size       = 1
  node_max_size       = 2
  node_desired_size   = 1
}
