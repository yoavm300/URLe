resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_version
  namespace        = "argocd"
  create_namespace = true

  # `values` yamls only, never `set` blocks: Helm's --set parses unescaped
  # commas/dots in values as extra key=value pairs. Helm deep-merges the
  # list, so each concern stays its own document.
  values = concat(
    var.ingress_host == "" ? [] : [
      yamlencode({
        configs = {
          params = {
            # TLS terminates at ingress-nginx; without this the argocd-server
            # pod redirects to its own self-signed HTTPS in a loop.
            "server.insecure" = true
          }
        }
        server = {
          ingress = {
            enabled          = true
            ingressClassName = "nginx"
            hostname         = var.ingress_host
          }
        }
      })
    ],
    var.gitops_token_ssm_path == "" ? [] : [
      yamlencode({
        configs = {
          # Renders the argocd.argoproj.io/secret-type=repository Secret the
          # repo-server needs to read the private GitOps repo over HTTPS.
          repositories = {
            gitops = {
              url      = var.gitops_repo_url
              username = "x-access-token" # any non-empty value; the PAT is what counts
              password = data.aws_ssm_parameter.gitops_token[0].value
            }
          }
        }
      })
    ],
  )
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
          path           = "helm/git-ops"
          directory = {
            recurse = true
            include = "{projects/*.yaml,${var.environment}.yaml}"
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
