# Public hosted zone for the app domain. Lives in global/ (never part of an
# environment teardown): recreating a zone changes its NS set, which would
# require re-delegating at the registrar every cycle.
#
# Terraform creates the zone only. The records inside arrive from elsewhere:
# the app record from ExternalDNS (watching the prod Ingress), ACM validation
# records from the acm unit, vpn-<env> records from the vpn units.
resource "aws_route53_zone" "this" {
  name = var.domain_name
  tags = var.tags
}

# Published for discoverability and cross-repo automation; plain String —
# a zone id is not a secret.
resource "aws_ssm_parameter" "zone_id" {
  count = var.ssm_parameter_prefix != "" ? 1 : 0

  name  = "${var.ssm_parameter_prefix}/route53/zone-id"
  type  = "String"
  value = aws_route53_zone.this.zone_id

  # A stale value left by a prior destroy/apply cycle should always be
  # replaced with what the current apply actually produced.
  overwrite = true
  tags      = var.tags
}
