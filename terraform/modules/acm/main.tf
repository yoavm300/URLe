# DNS-validated ACM certificate for the public app hostname. The ALB
# controller auto-discovers it by matching the Ingress host — no
# certificate-arn annotation to copy around.
resource "aws_acm_certificate" "certificate" {
  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.certificate.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = var.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 300
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "validation" {
  certificate_arn         = aws_acm_certificate.certificate.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

resource "aws_ssm_parameter" "certificate_arn" {
  count = var.ssm_parameter_prefix != "" ? 1 : 0

  name      = "${var.ssm_parameter_prefix}/acm/certificate-arn"
  type      = "String"
  value     = aws_acm_certificate.certificate.arn
  overwrite = true
  tags      = var.tags
}
