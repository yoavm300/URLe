output "namespace" {
  description = "Namespace the ingress-nginx controller is installed in"
  value       = helm_release.ingress_nginx.namespace
}

output "lb_hostname" {
  description = "Hostname of the NLB fronting the controller"
  value       = try(data.kubernetes_service.controller.status[0].load_balancer[0].ingress[0].hostname, "")
}
