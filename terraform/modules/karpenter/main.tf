# Karpenter node autoscaler (§10 item 4). Without it, the HPA (chart item 12)
# can request replicas that sit Pending once the fixed managed node group is
# full. The IAM roles / instance profile / interruption SQS queue come from the
# eks karpenter submodule; this module adds the controller + a default
# NodePool/EC2NodeClass, and tags the node security group for discovery.
#
# ⚠️ UNVERIFIED + version-sensitive: the karpenter submodule's input/output
# names and the NodePool/EC2NodeClass v1 API shape shift between versions. Pin
# chart_version and the submodule version to a matched pair and `terragrunt
# plan` before apply. Requires the VPC subnet discovery tag (added to
# terraform/modules/vpc) to already exist.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name          = var.cluster_name
  enable_v1_permissions = true
  namespace             = "kube-system"

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"

  tags = var.tags
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.chart_version
  namespace  = "kube-system"

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "settings.interruptionQueue"
    value = module.karpenter.queue_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.karpenter.iam_role_arn
  }
}

# EC2NodeClass discovers the node security group by this tag (subnets are
# tagged in terraform/modules/vpc).
resource "aws_ec2_tag" "node_sg_discovery" {
  resource_id = var.node_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "kubectl_manifest" "ec2nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      role                       = module.karpenter.node_iam_role_name
      amiSelectorTerms           = [{ alias = "al2023@latest" }]
      subnetSelectorTerms        = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]
      securityGroupSelectorTerms = [{ tags = { "karpenter.sh/discovery" = var.cluster_name } }]
    }
  })

  depends_on = [helm_release.karpenter, aws_ec2_tag.node_sg_discovery]
}

resource "kubectl_manifest" "nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = [
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
          ]
        }
      }
      limits = { cpu = var.nodepool_cpu_limit }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass]
}
