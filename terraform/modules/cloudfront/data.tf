# AWS-managed policies looked up by name — never hardcode their IDs.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# Forwards the viewer's Host header (among everything else): the pods build
# short links from request.host_url, and the ALB's host rule matches on it —
# both must see the public hostname, not the origin's.
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

# HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy on every
# response — including WAF-generated blocks, which edge functions can't touch.
data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}
