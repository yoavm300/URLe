data "aws_partition" "current" {}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Created manually, read-only here: the bootstrap credential can't be managed
# by the tool that needs it (see docs/BOOTSTRAP.md).
data "aws_ssm_parameter" "password_hash" {
  name = var.password_hash_ssm_path
}
