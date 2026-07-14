locals {
  env        = "dev"
  aws_region = "us-east-1"

  vpc_cidr        = "10.10.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.10.1.0/24", "10.10.2.0/24"]
  public_subnets  = ["10.10.101.0/24", "10.10.102.0/24"]

  cluster_name = "urle-dev"
}
