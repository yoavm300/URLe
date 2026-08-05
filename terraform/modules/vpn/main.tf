# WireGuard VPN for admin access to in-VPC surfaces (ArgoCD, Grafana, dev app).
# wg-easy (WireGuard + admin UI) behind Caddy for TLS, on a single EC2 instance
# in the public subnet. SSM-only management — no SSH, no port 22, sessions
# logged to CloudTrail. Split-tunnel: clients route only the VPC CIDR through
# the tunnel, and use the VPC resolver so *.internal private zones resolve.

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

resource "aws_security_group" "vpn" {
  name        = var.name
  description = "WireGuard tunnel + admin UI for ${var.name}"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "wireguard" {
  security_group_id = aws_security_group.vpn.id
  description       = "WireGuard tunnel"
  from_port         = 51820
  to_port           = 51820
  ip_protocol       = "udp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "admin_ui" {
  security_group_id = aws_security_group.vpn.id
  description       = "wg-easy admin UI via Caddy TLS"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.vpn.id
  description       = "All egress (image pulls, DNS, VPC traffic)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_iam_role" "vpn" {
  name = var.name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.vpn.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "vpn" {
  name = var.name
  role = aws_iam_role.vpn.name
}

# EIP first (standalone), so user_data can bake the stable address into
# WG_HOST before the instance exists; association comes after.
resource "aws_eip" "vpn" {
  domain = "vpc"
  tags   = merge(var.tags, { Name = var.name })
}

resource "aws_instance" "vpn" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [aws_security_group.vpn.id]
  iam_instance_profile   = aws_iam_instance_profile.vpn.name

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    wg_host       = var.hostname != "" ? var.hostname : aws_eip.vpn.public_ip
    password_hash = data.aws_ssm_parameter.password_hash.value
    allowed_ips   = var.vpc_cidr
    # The VPC resolver (.2 of the VPC CIDR) — pushed to peers so the
    # *.internal private zones resolve over the tunnel.
    dns_server = cidrhost(var.vpc_cidr, 2)
    # With a real hostname Caddy gets a Let's Encrypt cert; without one it
    # falls back to a self-signed internal cert.
    caddy_from  = var.hostname != "" ? "https://${var.hostname}" : "https://:443"
    caddy_extra = var.hostname != "" ? "" : "--internal-certs"
  })

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_eip_association" "vpn" {
  instance_id   = aws_instance.vpn.id
  allocation_id = aws_eip.vpn.id
}

resource "aws_route53_record" "vpn" {
  count = var.public_zone_id != "" && var.hostname != "" ? 1 : 0

  zone_id = var.public_zone_id
  name    = var.hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.vpn.public_ip]
}
