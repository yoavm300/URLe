output "distribution_id" {
  description = "Distribution id (cache invalidations)"
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_domain_name" {
  description = "The d123.cloudfront.net hostname behind the alias"
  value       = aws_cloudfront_distribution.this.domain_name
}
