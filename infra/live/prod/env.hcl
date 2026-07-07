locals {
  env        = "prod"
  aws_region = "eu-central-1"

  vpc_cidr        = "10.20.0.0/16"
  azs             = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  private_subnets = ["10.20.1.0/24", "10.20.2.0/24", "10.20.3.0/24"]
  public_subnets  = ["10.20.101.0/24", "10.20.102.0/24", "10.20.103.0/24"]

  cluster_name = "urle-prod"
}
