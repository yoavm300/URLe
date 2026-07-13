output "namespace" {
  description = "Namespace cert-manager is installed in"
  value       = helm_release.cert_manager.namespace
}
