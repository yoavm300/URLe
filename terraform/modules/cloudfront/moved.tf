# This module is excluded from destroy (see terragrunt.hcl), so its state
# survives teardown cycles — a bare rename here becomes a live destroy/create
# instead of a no-op, unlike modules whose state resets every teardown.
moved {
  from = aws_cloudfront_distribution.this
  to   = aws_cloudfront_distribution.distribution
}

moved {
  from = aws_wafv2_web_acl.this[0]
  to   = aws_wafv2_web_acl.waf[0]
}
