include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/ingress-nginx"
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
  }
}

dependency "alb_controller" {
  config_path = "../alb-controller"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    cloudfront_only_sg_id = "sg-mock"
  }
}

dependency "cloudfront" {
  config_path = "../cloudfront"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    origin_verify_value = "mock-origin-verify"
  }
}

dependency "public_zone" {
  config_path = "../../global/route53-public-zone"

  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    zone_name = "example.com"
  }
}

inputs = {
  cluster_name     = dependency.eks.outputs.cluster_name
  cluster_endpoint = dependency.eks.outputs.cluster_endpoint
  cluster_ca_data  = dependency.eks.outputs.cluster_certificate_authority_data
  aws_region       = local.env.aws_region

  # nginx still serves the VPN-gated admin surfaces (ArgoCD, Grafana) through
  # the internal NLB; the edge block below adds the public path in front of it.
  internal = true

  # Public edge: CloudFront -> ALB -> this controller -> app Ingress (nginx
  # class) -> Services -> pods. The ALB is built from the module's edge
  # Ingress; the hostnames must match the cloudfront unit's domain_name /
  # origin_hostname (and the ACM SANs).
  edge = {
    enabled           = true
    hosts             = [
      "urle.${dependency.public_zone.outputs.zone_name}",
      "urle-origin.${dependency.public_zone.outputs.zone_name}",
    ]
    group_name        = "urle-${local.env.env}"
    security_group_id = dependency.alb_controller.outputs.cloudfront_only_sg_id
  }
  edge_origin_verify_value = dependency.cloudfront.outputs.origin_verify_value
}
