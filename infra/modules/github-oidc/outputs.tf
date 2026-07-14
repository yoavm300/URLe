output "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "dev_ci_role_arn" {
  description = "Role assumed by CI jobs with environment: dev"
  value       = aws_iam_role.cicd["dev"].arn
}

output "prod_ci_role_arn" {
  description = "Role assumed by CI jobs with environment: prod"
  value       = aws_iam_role.cicd["prod"].arn
}

output "release_role_arn" {
  description = "Role assumed by SemVer tag builds to push ECR images"
  value       = aws_iam_role.release.arn
}
