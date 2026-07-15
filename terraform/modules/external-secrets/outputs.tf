output "namespace" {
  description = "Namespace the External Secrets Operator is installed in"
  value       = helm_release.external_secrets.namespace
}

output "role_arn" {
  description = "IRSA role ARN — set as externalSecrets.roleArn in helm/urle-chart/values-prod.yaml"
  value       = module.irsa.iam_role_arn
}
