include "root" {
  path = find_in_parent_folders()
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

inputs = {
  cluster_name = local.env.cluster_name
  vpc_id       = dependency.vpc.outputs.vpc_id
  subnet_ids   = dependency.vpc.outputs.private_subnet_ids

  node_instance_types = ["t3.medium"]
  node_min_size       = 1
  node_max_size       = 2
  node_desired_size   = 1
}
