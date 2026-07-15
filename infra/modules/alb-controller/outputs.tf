output "iam_role_arn" {
  description = "IRSA role the controller runs as"
  value       = module.irsa.iam_role_arn
}

output "cloudfront_only_sg_id" {
  description = "Id of the CloudFront-only frontend SG (empty when disabled)"
  value       = try(aws_security_group.cloudfront_only[0].id, "")
}
