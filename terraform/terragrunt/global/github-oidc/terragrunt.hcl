# GitHub Actions OIDC provider + CI/release roles. Applied ONCE, locally, with
# personal credentials — this is the chicken-and-egg unit that gives CI its
# identity, so CI can never bootstrap it itself. See docs/BOOTSTRAP.md.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/github-oidc"
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

inputs = {
  github_repository = "yoavm300/URLe"

  # Dropped once S3-native locking replaces the DynamoDB table.
  lock_table_arn = "arn:aws:dynamodb:${local.env.aws_region}:${get_aws_account_id()}:table/urle-tfstate-locks"
}
