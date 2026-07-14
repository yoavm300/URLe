include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/route53-private"
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

dependency "ingress_nginx" {
  config_path = "../ingress-nginx"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    lb_hostname = "mock-nlb.elb.eu-central-1.amazonaws.com"
  }
}

inputs = {
  zone_name       = "urle-${local.env.env}.internal"
  vpc_id          = dependency.vpc.outputs.vpc_id
  target_dns_name = dependency.ingress_nginx.outputs.lb_hostname

  # Dev app is VPN-only too — its host record lives in the private zone.
  records = ["argocd", "grafana", "app"]
}
