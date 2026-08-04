output "zone_id" {
  description = "Public hosted zone id"
  value       = aws_route53_zone.zone.zone_id
}

output "zone_name" {
  description = "The domain the zone serves"
  value       = var.domain_name
}

output "zone_arn" {
  description = "Zone ARN (ExternalDNS IRSA scoping)"
  value       = aws_route53_zone.zone.arn
}

output "name_servers" {
  description = "NS set to delegate at the registrar (one-time)"
  value       = aws_route53_zone.zone.name_servers
}
