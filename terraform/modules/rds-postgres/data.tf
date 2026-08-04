# Created manually, read-only here (see docs/BOOTSTRAP.md).
data "aws_ssm_parameter" "master_password" {
  name = var.master_password_ssm_path
}

# Manually-bootstrapped values read for the composed app secret in main.tf.
data "aws_ssm_parameter" "secret_key" {
  count = var.app_secret_name != "" ? 1 : 0
  name  = var.secret_key_ssm_path
}

data "aws_ssm_parameter" "redis_password" {
  count = var.app_secret_name != "" ? 1 : 0
  name  = var.redis_password_ssm_path
}
