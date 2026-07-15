variable "name" {
  description = "Name prefix for all VPN resources (e.g. urle-dev-vpn)"
  type        = string
}

variable "vpc_id" {
  description = "VPC the VPN gives access to"
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet for the VPN instance"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR — the only range routed through the tunnel (split-tunnel)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "password_hash_ssm_path" {
  description = "SSM SecureString holding the bcrypt hash for the wg-easy admin UI (created manually — see docs/BOOTSTRAP.md)"
  type        = string
}

variable "public_zone_id" {
  description = "Public hosted zone for the optional vpn-<env> record (empty = skip)"
  type        = string
  default     = ""
}

variable "hostname" {
  description = "FQDN for the VPN record and the admin UI's TLS certificate (empty = skip; UI falls back to a self-signed cert)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags for all resources"
  type        = map(string)
  default     = {}
}
