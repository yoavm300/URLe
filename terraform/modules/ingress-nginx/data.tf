# The NLB hostname AWS assigned to the controller Service — consumed by the
# route53-private unit for the argocd/grafana records.
data "kubernetes_service" "controller" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = helm_release.ingress_nginx.namespace
  }

  depends_on = [helm_release.ingress_nginx]
}
