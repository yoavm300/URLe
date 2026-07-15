include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/rds-postgres"
}

# Not excluded from destroy: RDS lives inside the prod VPC (its SG references
# the EKS node SG), so sparing it would fail the VPC/EKS destroy with
# DependencyViolation and leave a half-torn-down, still-billing environment.
# Instead the guard rails are the infra-destroy typed confirmation, the prod
# environment reviewer, and the final snapshot taken on deletion.

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    vpc_id             = "vpc-mock"
    private_subnet_ids = ["subnet-mock-a", "subnet-mock-b", "subnet-mock-c"]
  }
}

dependency "eks" {
  config_path = "../eks"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state = "shallow"
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

  # This project's prod is torn down between sessions for cost; the guard
  # rails against an accidental destroy are the infra-destroy workflow's
  # typed confirmation + prod reviewer, and the final snapshot on deletion.
  deletion_protection = false

  vpc_id                     = dependency.vpc.outputs.vpc_id
  subnet_ids                 = dependency.vpc.outputs.private_subnet_ids
  allowed_security_group_ids = [dependency.eks.outputs.node_security_group_id]

  # Manually-created SecureStrings (docs/BOOTSTRAP.md) composed into the
  # Secrets Manager secret the chart's ExternalSecret consumes.
  master_password_ssm_path = "/urle/${local.env.env}/rds/master-password"
  secret_key_ssm_path      = "/urle/${local.env.env}/secret-key"
  redis_password_ssm_path  = "/urle/${local.env.env}/redis-password"
  app_secret_name          = "urle/${local.env.env}/app"

  ssm_parameter_prefix = "/urle/${local.env.env}"
}
