# cert-manager install (§10 item 1). Provisions TLS certs for the app Ingress
# (chart item 8). The ClusterIssuer itself is managed via the umbrella chart
# (charts/urle/templates/clusterissuer.yaml) so the ACME email/host stay
# env-valued and GitOps-managed — this module only installs the controller+CRDs.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.chart_version
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "crds.enabled"
    value = "true"
  }
}
