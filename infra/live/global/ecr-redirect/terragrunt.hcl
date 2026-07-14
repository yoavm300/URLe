# See ecr-auth/terragrunt.hcl for why ECR lives in global/.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/ecr"
}

inputs = {
  name = "urle-redirect"

  ssm_parameter_prefix = "/urle/global"
}
