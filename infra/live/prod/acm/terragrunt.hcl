include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/acm"
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

# Survives environment teardowns: certificates are free to keep, recreating
# one changes the ARN, and a fresh cert re-validates with latency — none of
# that belongs on a cost-saving teardown cycle.
exclude {
  if      = get_terraform_command() == "destroy"
  actions = ["all"]
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
  domain_name = "urle.${dependency.public_zone.outputs.zone_name}"
  zone_id     = dependency.public_zone.outputs.zone_id

  ssm_parameter_prefix = "/urle/${local.env.env}"
}
