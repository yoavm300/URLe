# The single source of truth for the app's public domain. Everything else
# reads it as a dependency output (vpn records, ACM, ExternalDNS scoping) —
# change the domain here and only here.
#
# After the first apply, delegate at your registrar:
#   terragrunt output name_servers
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../modules/route53-public-zone"
}

inputs = {
  # PLACEHOLDER — set the bare domain you actually own before applying.
  # The app lives at urle.<domain>, the VPNs at vpn-<env>.<domain>.
  domain_name = "example.com"

  ssm_parameter_prefix = "/urle/global"
}
