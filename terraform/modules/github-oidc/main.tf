# GitHub Actions OIDC federation: one provider + three roles.
#
#   <prefix>-dev-cicd  — assumed by jobs declaring `environment: dev`
#   <prefix>-prod-cicd — assumed by jobs declaring `environment: prod`
#   <prefix>-release   — assumed by SemVer tag builds (refs/tags/v*) to push ECR images
#
# Trust is scoped via the token's `sub` claim per GitHub Environment (this is a
# single-branch repo, so the per-branch scoping the reference repo uses does not
# apply). If a provider for token.actions.githubusercontent.com already exists
# in the account, import it instead of creating a duplicate:
#   terragrunt import aws_iam_openid_connect_provider.github <provider-arn>

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.github_oidc_url}"
  client_id_list = ["sts.amazonaws.com"]

  # AWS validates GitHub's OIDC tokens against trusted root CAs and ignores
  # these thumbprints, but the argument is still required by the API.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = var.tags
}

resource "aws_iam_role" "cicd" {
  for_each = toset(local.environments)

  name               = "${var.role_name_prefix}-${each.key}-cicd"
  assume_role_policy = data.aws_iam_policy_document.ci_trust[each.key].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "cicd" {
  for_each = toset(local.environments)

  name   = "terraform-service-scoped"
  role   = aws_iam_role.cicd[each.key].id
  policy = data.aws_iam_policy_document.ci_permissions.json
}

resource "aws_iam_role" "release" {
  name               = "${var.role_name_prefix}-release"
  assume_role_policy = data.aws_iam_policy_document.release_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "release" {
  name   = "ecr-push-scoped"
  role   = aws_iam_role.release.id
  policy = data.aws_iam_policy_document.release_permissions.json
}
