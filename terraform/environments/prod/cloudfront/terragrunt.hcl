include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/cloudfront"
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

# Survives environment teardowns: a distribution takes 15-30 minutes to
# propagate to edge locations and costs cents to leave idle — recreating it
# every cost-saving cycle would make the public hostname unreachable for that
# whole window, every time, for no benefit.
exclude {
  if      = get_terraform_command() == "destroy"
  actions = ["all"]
}

dependency "public_zone" {
  config_path = "../../global/route53-public-zone"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state  = "shallow"
  mock_outputs = {
    zone_id   = "Z0MOCK"
    zone_name = "example.com"
  }
}

dependency "acm" {
  config_path = "../acm"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state  = "shallow"
  mock_outputs = {
    certificate_arn = "arn:aws:acm:us-east-1:111111111111:certificate/mock"
  }
}

inputs = {
  domain_name     = dependency.public_zone.outputs.zone_name
  origin_hostname = "urle-origin.${dependency.public_zone.outputs.zone_name}"
  certificate_arn = dependency.acm.outputs.certificate_arn
  zone_id         = dependency.public_zone.outputs.zone_id

  ssm_parameter_prefix = "/urle/${local.env.env}"
}
