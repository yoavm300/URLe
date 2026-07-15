module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = var.name
  cidr = var.cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_dns_support = true

  enable_dns_hostnames = true

  # Subnet discovery tags for the AWS Load Balancer / EKS controllers.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    # §10 item 4: Karpenter's EC2NodeClass subnetSelectorTerms discover
    # subnets by this tag. Harmless when Karpenter isn't installed.
    "karpenter.sh/discovery" = var.cluster_name
  }

  tags = var.tags
}
