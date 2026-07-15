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
    bucket = "urle-tfstate-${get_aws_account_id()}"
    # path_relative_to_include() returns OS-native separators — backslashes
    # from a Windows apply, forward slashes from WSL/CI — which would compute
    # two different S3 keys for the same unit. Normalize so every platform
    # reads and writes the same state object.
    key     = "${replace(path_relative_to_include(), "\\", "/")}/terraform.tfstate"
    region  = local.aws_region
    encrypt = true

    # S3-native locking (Terraform >= 1.10). The legacy DynamoDB lock table
    # from the old account was never carried to this one — the dual-locking
    # migration described in docs/BOOTSTRAP.md completed with the account move.
    use_lockfile = true
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
