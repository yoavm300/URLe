# This module is excluded from destroy (see terragrunt.hcl), so its state
# survives teardown cycles — a bare rename here becomes a live destroy/create
# instead of a no-op, unlike modules whose state resets every teardown.
moved {
  from = aws_acm_certificate.this
  to   = aws_acm_certificate.certificate
}

moved {
  from = aws_acm_certificate_validation.this
  to   = aws_acm_certificate_validation.validation
}
