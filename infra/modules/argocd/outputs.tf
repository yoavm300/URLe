output "namespace" {
  description = "Namespace Argo CD is installed in"
  value       = helm_release.argocd.namespace
}

output "root_application" {
  description = "Name of the bootstrap app-of-apps release"
  value       = helm_release.root_app.name
}
