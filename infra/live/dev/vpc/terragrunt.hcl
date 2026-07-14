include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/vpc"
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

inputs = {
  name            = "urle-${local.env.env}"
  cidr            = local.env.vpc_cidr
  azs             = local.env.azs
  private_subnets = local.env.private_subnets
  public_subnets  = local.env.public_subnets
  cluster_name    = local.env.cluster_name
}
