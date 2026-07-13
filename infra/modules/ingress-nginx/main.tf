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

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }
}
