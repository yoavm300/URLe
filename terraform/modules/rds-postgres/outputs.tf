output "address" {
  description = "DNS address of the instance"
  value       = aws_db_instance.postgres.address
}

output "port" {
  description = "Postgres port"
  value       = aws_db_instance.postgres.port
}

output "db_name" {
  description = "Initial database name"
  value       = aws_db_instance.postgres.db_name
}

output "security_group_id" {
  description = "Security group attached to the instance"
  value       = aws_security_group.postgres.id
}
