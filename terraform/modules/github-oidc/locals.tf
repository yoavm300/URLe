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
