include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "../../../modules/rds-postgres"
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    vpc_id             = "vpc-mock"
    private_subnet_ids = ["subnet-mock-a", "subnet-mock-b", "subnet-mock-c"]
  }
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    node_security_group_id = "sg-mock"
  }
}

inputs = {
  identifier = "urle-${local.env.env}"
  db_name    = "urlshortener"
  username   = "urlshortener"

  instance_class    = "db.t4g.small"
  allocated_storage = 20
  multi_az          = true

  vpc_id                     = dependency.vpc.outputs.vpc_id
  subnet_ids                 = dependency.vpc.outputs.private_subnet_ids
  allowed_security_group_ids = [dependency.eks.outputs.node_security_group_id]
}
