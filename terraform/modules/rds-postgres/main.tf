resource "aws_db_subnet_group" "postgres" {
  name       = var.identifier
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "postgres" {
  name        = "${var.identifier}-postgres"
  description = "Postgres access for ${var.identifier}"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.postgres.id
  description                  = "Postgres from cluster nodes"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = each.value
}

resource "aws_db_instance" "postgres" {
  identifier     = var.identifier
  engine         = "postgres"
  engine_version = var.engine_version

  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_encrypted = true
  multi_az          = var.multi_az

  db_name  = var.db_name
  username = var.username
  # Master password is a manually-created SSM SecureString (docs/BOOTSTRAP.md)
  # read here — a credential the operator chooses and rotates, with its source
  # of truth outside Terraform, but resolvable by the app-secret composition
  # below (manage_master_user_password couldn't be: RDS would own it and this
  # module could never read the value to build DATABASE_URL).
  password = data.aws_ssm_parameter.master_password.value

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [aws_security_group.postgres.id]
  publicly_accessible    = false

  backup_retention_period = 7
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = false
  # Suffixed per instance lifecycle: a fixed name collides with the snapshot
  # left by the previous teardown ("DBSnapshotAlreadyExists") and blocks the
  # destroy. The random_id is created at bootstrap and stable until the next
  # one, so each cycle snapshots under a fresh name.
  final_snapshot_identifier = "${var.identifier}-final-${random_id.final_snapshot.hex}"

  tags = var.tags
}

resource "random_id" "final_snapshot" {
  byte_length = 4
}

# --- App secret composition -------------------------------------------------
# This module is the SOLE composer/owner of the Secrets Manager secret the
# chart's ExternalSecret consumes (externalSecrets.remoteKey). It combines the
# DATABASE_URL only this module can derive with the manually-bootstrapped app
# credentials (docs/BOOTSTRAP.md) — closing the previously-undocumented gap of
# who creates that secret. Nothing else writes it.

resource "aws_secretsmanager_secret" "app" {
  count = var.app_secret_name != "" ? 1 : 0

  name        = var.app_secret_name
  description = "URLe app secrets (composed by the rds-postgres module — do not edit by hand)"
  tags        = var.tags

  # Derived data, recomposed from SSM on every bootstrap. The default 30-day
  # recovery window holds the name hostage after a teardown ("scheduled for
  # deletion" blocks recreation), so delete immediately instead.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app" {
  count = var.app_secret_name != "" ? 1 : 0

  secret_id = aws_secretsmanager_secret.app[0].id
  secret_string = jsonencode({
    SECRET_KEY            = data.aws_ssm_parameter.secret_key[0].value
    DATABASE_URL          = "postgresql://${var.username}:${data.aws_ssm_parameter.master_password.value}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/${var.db_name}"
    REDIS_PASSWORD        = data.aws_ssm_parameter.redis_password[0].value
    RATELIMIT_STORAGE_URI = "redis://:${data.aws_ssm_parameter.redis_password[0].value}@${var.redis_host}:6379/0"
  })
}

# Published for discoverability; plain String — an endpoint is not a secret.
resource "aws_ssm_parameter" "address" {
  count = var.ssm_parameter_prefix != "" ? 1 : 0

  name      = "${var.ssm_parameter_prefix}/rds/address"
  type      = "String"
  value     = aws_db_instance.postgres.address
  overwrite = true
  tags      = var.tags
}
