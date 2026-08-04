output "zone_id" {
  description = "Private hosted zone id"
  value       = aws_route53_zone.zone.zone_id
}

output "zone_name" {
  description = "Private hosted zone name"
  value       = aws_route53_zone.zone.name
}
