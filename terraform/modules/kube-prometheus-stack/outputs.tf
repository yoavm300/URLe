output "namespace" {
  description = "Namespace the monitoring stack is installed in"
  value       = helm_release.kube_prometheus_stack.namespace
}
