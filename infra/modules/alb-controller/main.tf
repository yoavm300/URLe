# AWS Load Balancer Controller (§ prod public edge). Terraform installs the
# CONTROLLER only — the actual ALB is created by it later, from the Ingress
# objects ArgoCD deploys (ingressClassName: alb in values-prod.yaml). No
# sequencing problem: ExternalDNS writes the public record once that ALB
# exists, autonomously.
module "irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.cluster_name}-alb-controller"

  # AWS's maintained controller policy — don't hand-write it.
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_version
  namespace  = "kube-system"

  values = [
    yamlencode({
      clusterName = var.cluster_name
      region      = var.aws_region
      vpcId       = var.vpc_id
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.irsa.iam_role_arn
        }
      }
      # The Service mutator webhook races Service creation during a cold
      # bootstrap (everything applies at once) and this project doesn't use
      # its feature (NLB target injection) — off.
      enableServiceMutatorWebhook = false
    })
  ]
}
