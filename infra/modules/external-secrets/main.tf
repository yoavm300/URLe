# External Secrets Operator install + IRSA (§10 item 5). The operator syncs
# `urlshortener-secrets` from AWS Secrets Manager (chart item 10). The IRSA
# role is assumed (via the chart's SecretStore jwt.serviceAccountRef) by the
# in-namespace SA the umbrella chart creates — trust is scoped to that SA
# subject, permissions to urle/<env>/* only.
data "aws_caller_identity" "current" {}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.chart_version
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
}

resource "aws_iam_policy" "read_secrets" {
  name        = "${var.cluster_name}-external-secrets-read"
  description = "Read only the URLe app secrets in Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.secrets_path_prefix}/*"
    }]
  })
}

module "irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-external-secrets"

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.app_namespace}:${var.service_account_name}"]
    }
  }

  role_policy_arns = {
    read_secrets = aws_iam_policy.read_secrets.arn
  }
}
