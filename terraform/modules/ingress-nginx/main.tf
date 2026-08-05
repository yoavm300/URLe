# ingress-nginx controller install (§10 item 2). The app Ingress
# (helm/urle-chart/templates/ingress.yaml) uses ingressClassName: nginx but nothing
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
      controller = merge(
        {
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
        },
        # Behind the edge ALB, nginx must trust the X-Forwarded-* chain instead
        # of overwriting it with its own view (the ALB's IP, scheme http):
        # use-forwarded-headers passes the incoming headers through, and
        # compute-full-forwarded-for appends the peer instead of replacing —
        # the pod then sees XFF [viewer, cf-edge, alb] (trustProxy 3).
        var.edge.enabled ? {
          config = {
            use-forwarded-headers      = "true"
            compute-full-forwarded-for = "true"
          }
        } : {}
      )
    })
  ]
}

# The public edge (prod): the AWS LB Controller builds the internet-facing ALB
# from this Ingress; its sole target is the controller pods (target-type ip),
# and the app Ingress (nginx class, deployed by ArgoCD) does the path routing
# in-cluster. Lives here (not in the umbrella chart) because Ingress backends
# can't cross namespaces — it must sit next to the controller Service.
resource "kubernetes_ingress_v1" "edge" {
  count = var.edge.enabled ? 1 : 0

  metadata {
    name      = "urle-edge"
    namespace = helm_release.ingress_nginx.namespace

    annotations = {
      "alb.ingress.kubernetes.io/scheme"      = "internet-facing"
      "alb.ingress.kubernetes.io/target-type" = "ip"
      "alb.ingress.kubernetes.io/group.name"  = var.edge.group_name
      # HTTPS only: CloudFront redirects HTTP at the edge, and the
      # CloudFront-only SG doesn't admit port 80 anyway.
      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTPS\":443}]"
      # Origin cloaking half 1: frontend SG admitting only CloudFront's
      # origin-facing ranges (created by the alb-controller unit). The second
      # annotation keeps the controller managing ALB->pod rules, which it
      # stops doing by default when handed an explicit frontend SG.
      "alb.ingress.kubernetes.io/security-groups"                     = var.edge.security_group_id
      "alb.ingress.kubernetes.io/manage-backend-security-group-rules" = "true"
      # nginx's default server answers /healthz on the traffic port; without
      # this the ALB health-checks / with no matching Host and gets a 404.
      "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"
      # Origin cloaking half 2: only forward requests carrying the secret
      # header CloudFront attaches (see the cloudfront module) — anything
      # else falls through to the ALB's default 404, so other CloudFront
      # customers inside the SG's prefix list still can't reach the origin.
      # The value is readable by cluster users with Ingress access; it grants
      # nothing beyond origin reachability.
      "alb.ingress.kubernetes.io/conditions.ingress-nginx-controller" = jsonencode([
        {
          field = "http-header"
          httpHeaderConfig = {
            httpHeaderName = "X-Origin-Verify"
            values         = [var.edge_origin_verify_value]
          }
        }
      ])
    }
  }

  spec {
    ingress_class_name = "alb"

    # One rule per hostname (the public name CloudFront forwards as the viewer
    # Host, plus the origin hostname ExternalDNS points at this ALB). ACM cert
    # auto-discovery matches these against the SANs — no ARN to wire.
    dynamic "rule" {
      for_each = var.edge.hosts
      content {
        host = rule.value
        http {
          path {
            path      = "/"
            path_type = "Prefix"
            backend {
              service {
                name = "ingress-nginx-controller"
                port {
                  number = 80
                }
              }
            }
          }
        }
      }
    }
  }
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
