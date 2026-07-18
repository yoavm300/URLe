# Account-wide units, not tied to dev or prod. Never part of an environment
# teardown — `run --all destroy` from dev/ or prod/ can't reach this directory.
locals {
  env        = "global"
  aws_region = "us-east-1"
}
