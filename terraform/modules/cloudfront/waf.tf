# AWS WAF for the distribution. CLOUDFRONT-scoped web ACLs must be created in
# us-east-1 — this whole project already runs there, so the root-generated
# provider is the right one as-is. DDoS (L3/L4) needs nothing here: Shield
# Standard is automatic and free on every CloudFront distribution.
#
# Rule order matters — first match wins by priority:
#   0. rate limit  1. IP reputation  2. common rule set  3. known bad inputs
resource "aws_wafv2_web_acl" "waf" {
  count = var.waf_enabled ? 1 : 0

  name        = "urle-cloudfront"
  description = "Edge protection for ${var.domain_name}"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "urle-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-ip-reputation"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "urle-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        # A URL shortener's core input is a URL in the request body/args —
        # exactly what the RFI rules treat as an inclusion attempt. Blocking
        # them would break every legitimate POST /shorten, so these two run
        # in count mode (still visible in metrics, never enforced).
        rule_action_override {
          name = "GenericRFI_BODY"
          action_to_use {
            count {}
          }
        }

        rule_action_override {
          name = "GenericRFI_QUERYARGUMENTS"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "urle-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "urle-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "urle-cloudfront"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}
