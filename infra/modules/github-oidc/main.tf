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

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  github_oidc_url = "token.actions.githubusercontent.com"

  # Service-scoped, not AdministratorAccess. Inline policies (not managed
  # attachments) because IAM caps attached policies per role at 10 and this
  # list only grows. kms/logs/autoscaling are needed just to *describe* an
  # EKS cluster (envelope-encryption key + control-plane log group + node
  # group ASGs) — found the hard way in the reference repo.
  ci_service_actions = [
    "acm:*",
    "autoscaling:*",
    "cloudfront:*",
    "cloudwatch:*",
    "ec2:*",
    "ecr:*",
    "eks:*",
    "elasticloadbalancing:*",
    "events:*",
    "iam:*",
    "kms:*",
    "logs:*",
    "rds:*",
    "route53:*",
    "s3:*",
    "secretsmanager:*",
    "sqs:*",
    "ssm:*",
    "wafv2:*",
  ]

  environments = ["dev", "prod"]
}

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

# --- Per-environment CI roles (terraform plan/apply from GitHub Actions) ----

data "aws_iam_policy_document" "ci_trust" {
  for_each = toset(local.environments)

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_url}:sub"
      values   = ["repo:${var.github_repository}:environment:${each.key}"]
    }
  }
}

resource "aws_iam_role" "cicd" {
  for_each = toset(local.environments)

  name               = "${var.role_name_prefix}-${each.key}-cicd"
  assume_role_policy = data.aws_iam_policy_document.ci_trust[each.key].json
  tags               = var.tags
}

data "aws_iam_policy_document" "ci_permissions" {
  statement {
    sid       = "ServiceScoped"
    actions   = local.ci_service_actions
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.lock_table_arn != "" ? [var.lock_table_arn] : []

    content {
      sid = "StateLockTable"
      actions = [
        "dynamodb:DescribeTable",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
      ]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role_policy" "cicd" {
  for_each = toset(local.environments)

  name   = "terraform-service-scoped"
  role   = aws_iam_role.cicd[each.key].id
  policy = data.aws_iam_policy_document.ci_permissions.json
}

# --- Release role (ECR image push on SemVer tags) ---------------------------

data "aws_iam_policy_document" "release_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.github_oidc_url}:sub"
      values   = ["repo:${var.github_repository}:ref:refs/tags/v*"]
    }
  }
}

resource "aws_iam_role" "release" {
  name               = "${var.role_name_prefix}-release"
  assume_role_policy = data.aws_iam_policy_document.release_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "release_permissions" {
  # GetAuthorizationToken is account-wide by API design — it cannot be
  # scoped to a repository.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [
      "arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repository_prefix}*",
    ]
  }
}

resource "aws_iam_role_policy" "release" {
  name   = "ecr-push-scoped"
  role   = aws_iam_role.release.id
  policy = data.aws_iam_policy_document.release_permissions.json
}
