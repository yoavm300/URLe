# ExternalDNS (§ prod public edge). Watches Ingress resources and writes the
# matching Route53 record — for Ingress it reads spec.rules[].host directly
# (the hostname annotation is a Service-only mechanism). This is what closes
# the ALB sequencing gap: the ALB controller creates the ALB from the chart's
# Ingress after ArgoCD syncs it, ExternalDNS notices the same Ingress and
# points urle.<domain> at it — no second terraform apply.
module "irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-external-dns"

  # Record writes scoped to exactly this zone; the list/read actions the
  # policy grants account-wide are an API limitation, not a choice.
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [var.zone_arn]

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.chart_version
  namespace        = "external-dns"
  create_namespace = true

  values = [
    yamlencode({
      provider = { name = "aws" }
      env = [
        { name = "AWS_DEFAULT_REGION", value = var.aws_region }
      ]
      # upsert-only: never reconcile-by-deletion in a zone that also holds
      # records ExternalDNS doesn't own (vpn-<env>, ACM validation).
      policy        = "upsert-only"
      domainFilters = [var.domain_filter]
      txtOwnerId    = var.txt_owner_id
      extraArgs     = var.ingress_class_filter != "" ? ["--ingress-class=${var.ingress_class_filter}"] : []
      serviceAccount = {
        create = true
        name   = "external-dns"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.irsa.iam_role_arn
        }
      }
    })
  ]
}
