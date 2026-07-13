output "namespace" {
  description = "Namespace the ingress-nginx controller is installed in"
  value       = helm_release.ingress_nginx.namespace
}
