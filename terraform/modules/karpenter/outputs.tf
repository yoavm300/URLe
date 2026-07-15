output "node_iam_role_name" {
  description = "IAM role Karpenter-launched nodes assume"
  value       = module.karpenter.node_iam_role_name
}

output "controller_role_arn" {
  description = "IRSA role ARN for the Karpenter controller"
  value       = module.karpenter.iam_role_arn
}

output "interruption_queue_name" {
  description = "SQS queue Karpenter watches for spot interruption / health events"
  value       = module.karpenter.queue_name
}
