output "iam_role_arn" {
  description = "IRSA role the controller runs as"
  value       = module.irsa.iam_role_arn
}
