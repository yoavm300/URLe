include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/vpn"
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

dependency "vpc" {
  config_path = "../vpc"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    vpc_id            = "vpc-mock"
    public_subnet_ids = ["subnet-mock-a", "subnet-mock-b", "subnet-mock-c"]
    vpc_cidr          = "10.20.0.0/16"
  }
}

dependency "public_zone" {
  config_path = "../../global/route53-public-zone"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    zone_id   = "Z0MOCK"
    zone_name = "example.com"
  }
}

inputs = {
  name             = "urle-${local.env.env}-vpn"
  vpc_id           = dependency.vpc.outputs.vpc_id
  public_subnet_id = dependency.vpc.outputs.public_subnet_ids[0]
  vpc_cidr         = dependency.vpc.outputs.vpc_cidr

  password_hash_ssm_path = "/urle/${local.env.env}/vpn/wg-easy-password-hash"

  public_zone_id = dependency.public_zone.outputs.zone_id
  hostname       = "vpn-${local.env.env}.${dependency.public_zone.outputs.zone_name}"
}
