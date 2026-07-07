resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_version
  namespace        = "argocd"
  create_namespace = true
}

# App-of-apps bootstrap: one root Application syncing the AppProject and this
# environment's Application from argocd/ in the GitOps repo. Everything else
# is managed from git, not terraform.
resource "helm_release" "root_app" {
  name       = "urle-root"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.apps_chart_version
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      urle-root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "argocd"
          directory = {
            recurse = true
            include = "{projects/*.yaml,apps/${var.environment}.yaml}"
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
        }
      }
    }
  })]

  depends_on = [helm_release.argocd]
}
