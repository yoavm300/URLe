output "address" {
  description = "DNS address of the instance"
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Postgres port"
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Initial database name"
  value       = aws_db_instance.this.db_name
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the generated master password"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "Security group attached to the instance"
  value       = aws_security_group.this.id
}
