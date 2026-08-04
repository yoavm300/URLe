# CloudFront in front of the prod ALB. The app is server-rendered Flask, so
# this is NOT a static-hosting setup: the default behavior forwards everything
# (cookies, CSRF headers, all methods) with caching disabled, and only
# /static/* is cached at the edge. What it buys: edge TLS termination close to
# users, cached assets, a WAF attachment point, and — with the prefix-list SG
# on the ALB (see alb-controller module) — an origin nobody can bypass.
#
# Sequencing: the ALB doesn't exist when this applies. The origin points at a
# stable hostname ExternalDNS later populates from the Ingress — CloudFront
# resolves origins per-request, not at distribution creation.

# Origin cloaking, half 2 (half 1 is the CloudFront-only SG in alb-controller):
# the SG's prefix list admits every CloudFront customer's origin-facing
# traffic, so anyone can point their own distribution at our origin hostname
# and sail past the WAF. This secret rides on every origin request; the ALB
# (edge Ingress in the ingress-nginx unit) only forwards requests carrying it.
# Rotation: taint this resource, re-apply cloudfront then prod/ingress-nginx —
# the brief origin-404 window between the two applies is acceptable here.
resource "random_password" "origin_verify" {
  length  = 32
  special = false
}

resource "aws_cloudfront_distribution" "distribution" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "URLe prod edge (${var.domain_name})"
  price_class     = var.price_class
  aliases         = [var.domain_name]

  # For CLOUDFRONT-scoped WAFv2, the association is this attribute (the ACL's
  # full ARN), not a wafv2 association resource — those are regional-only.
  web_acl_id = var.waf_enabled ? aws_wafv2_web_acl.waf[0].arn : null

  origin {
    origin_id   = "alb"
    domain_name = var.origin_hostname

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }

    custom_origin_config {
      origin_protocol_policy = "https-only"
      https_port             = 443
      http_port              = 80 # required argument; unused with https-only
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Dynamic app traffic: no edge caching, everything forwarded.
  default_cache_behavior {
    target_origin_id           = "alb"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
    compress                   = true
  }

  # The one thing worth caching: dashboard-served CSS/JS.
  ordered_cache_behavior {
    path_pattern               = "/static/*"
    target_origin_id           = "alb"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
    compress                   = true
  }

  viewer_certificate {
    acm_certificate_arn      = var.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = var.tags
}

# The public record now belongs to CloudFront (Terraform-owned). ExternalDNS
# is upsert-only with TXT ownership, so it skips this record and only manages
# the origin hostname — no fighting, provided this unit applies before the
# chart's Ingress does (see the argocd unit's ordering dependencies).
resource "aws_route53_record" "alias" {
  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.distribution.domain_name
    zone_id                = aws_cloudfront_distribution.distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "alias_ipv6" {
  zone_id = var.zone_id
  name    = var.domain_name
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.distribution.domain_name
    zone_id                = aws_cloudfront_distribution.distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_ssm_parameter" "distribution_id" {
  count = var.ssm_parameter_prefix != "" ? 1 : 0

  name      = "${var.ssm_parameter_prefix}/cloudfront/distribution-id"
  type      = "String"
  value     = aws_cloudfront_distribution.distribution.id
  overwrite = true
  tags      = var.tags
}
