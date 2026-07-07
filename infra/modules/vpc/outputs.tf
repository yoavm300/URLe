output "vpc_id" {
  description = "VPC id"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet ids (nodes, databases)"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet ids (load balancers)"
  value       = module.vpc.public_subnets
}
