# AWS Load Balancer Controller (§ prod public edge). Terraform installs the
# CONTROLLER only — the actual ALB is created by it later, from the alb-class
# edge Ingress the prod/ingress-nginx unit deploys (its target is the nginx
# controller, which routes to the app via the chart's nginx-class Ingress).
# No sequencing problem: ExternalDNS writes the public record once that ALB
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

# --- Origin cloaking (optional) ----------------------------------------------
# A frontend SG for the ALB that only admits CloudFront's origin-facing
# address ranges (AWS-managed prefix list, updated by AWS as edges change).
# Consumed by the prod/ingress-nginx unit's edge Ingress (security-groups
# annotation, via the cloudfront_only_sg_id output). The prefix list admits
# EVERY CloudFront customer's origin traffic, so this SG alone isn't enough —
# the edge Ingress also requires the secret X-Origin-Verify header the
# cloudfront module attaches to origin requests.

resource "aws_security_group" "cloudfront_only" {
  count = var.cloudfront_only_sg_name != "" ? 1 : 0

  name        = var.cloudfront_only_sg_name
  description = "ALB frontend SG - HTTPS from CloudFront origin-facing ranges only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "cloudfront_https" {
  count = var.cloudfront_only_sg_name != "" ? 1 : 0

  security_group_id = aws_security_group.cloudfront_only[0].id
  description       = "HTTPS from CloudFront edges"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin[0].id
}

resource "aws_vpc_security_group_egress_rule" "cloudfront_only_all" {
  count = var.cloudfront_only_sg_name != "" ? 1 : 0

  security_group_id = aws_security_group.cloudfront_only[0].id
  description       = "ALB egress to targets and health checks"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
