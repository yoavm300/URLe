module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  cluster_endpoint_public_access = true

  # Grants the identity running terraform admin on the cluster,
  # which the argocd unit needs to install the Helm releases.
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    # §10 item 3: HPA (item 12) needs a metrics source. If this addon isn't in
    # the catalog for cluster_version, replace it with a Helm install of
    # metrics-server in the argocd module pattern.
    metrics-server = {
      most_recent = true
    }
    # §10 item 7: the VPC CNI does not enforce NetworkPolicy (chart item 9)
    # unless this is set — otherwise the policies are accepted and ignored.
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }

  tags = var.tags
}
