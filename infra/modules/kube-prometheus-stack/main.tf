# kube-prometheus-stack install (§10 item 6). Provides Prometheus + Operator
# CRDs (ServiceMonitor — chart item 15), Alertmanager, node-exporter,
# kube-state-metrics, and Grafana. Grafana's dashboard sidecar (enabled by
# default) auto-loads ConfigMaps labelled grafana_dashboard: "1" (chart
# item 16). Self-contained module, NOT an argocd/apps/monitoring.yaml route —
# that would need the app-of-apps bootstrap glob widened first.
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.chart_version
  namespace        = "monitoring"
  create_namespace = true

  # Discover ServiceMonitors in any namespace (the app charts set the
  # `release: kube-prometheus-stack` label the operator selects on).
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
}
