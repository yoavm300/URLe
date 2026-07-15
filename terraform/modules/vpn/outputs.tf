output "public_ip" {
  description = "Stable public address of the VPN endpoint (WG_HOST)"
  value       = aws_eip.this.public_ip
}

output "security_group_id" {
  description = "Security group of the VPN instance"
  value       = aws_security_group.this.id
}
