locals {
  env        = "prod"
  aws_region = "us-east-1"

  vpc_cidr        = "10.20.0.0/16"
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.20.1.0/24", "10.20.2.0/24", "10.20.3.0/24"]
  public_subnets  = ["10.20.101.0/24", "10.20.102.0/24", "10.20.103.0/24"]

  cluster_name = "urle-prod"
}
