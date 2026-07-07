locals {
  env        = "dev"
  aws_region = "eu-central-1"

  vpc_cidr        = "10.10.0.0/16"
  azs             = ["eu-central-1a", "eu-central-1b"]
  private_subnets = ["10.10.1.0/24", "10.10.2.0/24"]
  public_subnets  = ["10.10.101.0/24", "10.10.102.0/24"]

  cluster_name = "urle-dev"
}
