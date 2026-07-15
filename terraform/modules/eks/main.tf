module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  cluster_endpoint_public_access = true

  # No implicit "whoever applies becomes admin" — every admin principal is an
  # explicit access entry below. IAM permissions alone only cover the AWS API
  # (eks:CreateCluster etc.); the helm/kubectl providers in the argocd unit
  # authenticate against the cluster's *Kubernetes* API, which is what these
  # entries grant.
  enable_cluster_creator_admin_permissions = false

  access_entries = merge(
    var.admin_principal_arn == "" ? {} : {
      personal = {
        principal_arn = var.admin_principal_arn
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    },
    var.cicd_principal_arn == "" ? {} : {
      cicd = {
        principal_arn = var.cicd_principal_arn
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    }
  )

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
    # Karpenter's controller role trusts pods.eks.amazonaws.com (the eks
    # karpenter submodule's v20.24+ default) — Pod Identity needs this agent
    # on the cluster or AssumeRole fails and the controller crash-loops.
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    default = {
      # Explicit: AL2 AMIs don't exist for k8s >= 1.33 — relying on the
      # module's default ami_type breaks cluster creation on 1.36.
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }

  tags = var.tags
}
