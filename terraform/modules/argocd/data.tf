# Fine-grained PAT (contents: read-only) for the private GitOps repo —
# a manual SSM parameter (docs/BOOTSTRAP.md §4), never created by Terraform.
data "aws_ssm_parameter" "gitops_token" {
  count = var.gitops_token_ssm_path == "" ? 0 : 1

  name = var.gitops_token_ssm_path
}
