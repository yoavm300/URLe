# ECR repos are account-wide: one SemVer release ships one image consumed by
# every environment (MANIFEST §5/§6), and the release workflow pushes to
# <registry>/urle-auth. Living in global/ also means environment teardowns
# never delete released images — a cold bootstrap can pull them immediately.
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/ecr"
}

inputs = {
  name = "urle-auth"

  ssm_parameter_prefix = "/urle/global"
}
