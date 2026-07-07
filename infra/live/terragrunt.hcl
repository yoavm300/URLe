# Root Terragrunt config: remote state + provider generation for every unit.

locals {
  env_hcl    = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  env        = local.env_hcl.locals.env
  aws_region = local.env_hcl.locals.aws_region
}

remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket         = "urle-tfstate-${get_aws_account_id()}"
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.aws_region
    encrypt        = true
    dynamodb_table = "urle-tfstate-locks"
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<EOF
provider "aws" {
  region = "${local.aws_region}"

  default_tags {
    tags = {
      Project     = "urle"
      Environment = "${local.env}"
      ManagedBy   = "terraform"
    }
  }
}
EOF
}
