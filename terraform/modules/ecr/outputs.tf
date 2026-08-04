output "repository_url" {
  description = "Full registry/repository URL for docker push and Helm values"
  value       = aws_ecr_repository.repository.repository_url
}

output "repository_arn" {
  description = "Repository ARN (for CI IAM policies)"
  value       = aws_ecr_repository.repository.arn
}
