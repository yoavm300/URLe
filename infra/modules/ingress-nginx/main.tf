# ingress-nginx controller install (§10 item 2). The app Ingress
# (charts/urle/templates/ingress.yaml) uses ingressClassName: nginx but nothing
# installed the controller — so the Ingress was undeployed. This provisions it
# (fronted by an AWS NLB via the service annotations).
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.chart_version
  namespace        = "ingress-nginx"
  create_namespace = true

  # `wait` (helm default, kept) blocks until the LoadBalancer Service has a
  # hostname — which is what the lb_hostname output reads below.
  values = [
    yamlencode({
      controller = {
        service = {
          annotations = merge(
            {
              "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"
            },
            # Internal NLB: reachable only inside the VPC (i.e. over the VPN).
            var.internal ? {
              "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internal"
            } : {}
          )
        }
      }
    })
  ]
}

# The NLB hostname AWS assigned to the controller Service — consumed by the
# route53-private unit for the argocd/grafana records.
data "kubernetes_service" "controller" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = helm_release.ingress_nginx.namespace
  }

  depends_on = [helm_release.ingress_nginx]
}
