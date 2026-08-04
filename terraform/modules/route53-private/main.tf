# Private hosted zone for admin surfaces (ArgoCD, Grafana) behind the internal
# ingress NLB. Resolvable only from inside the VPC — VPN peers get the VPC
# resolver pushed as their DNS server, so these names work over the tunnel.
resource "aws_route53_zone" "zone" {
  name = var.zone_name

  vpc {
    vpc_id = var.vpc_id
  }

  tags = var.tags
}

resource "aws_route53_record" "record" {
  for_each = toset(var.records)

  zone_id = aws_route53_zone.zone.zone_id
  name    = "${each.value}.${var.zone_name}"
  type    = "CNAME"
  ttl     = 300
  records = [var.target_dns_name]
}
