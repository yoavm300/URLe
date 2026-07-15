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
  # The bare domain (registered at the external registrar; NS delegation
  # happens after the first apply — see docs/BOOTSTRAP.md step 5).
  # The app lives at urle.<domain>, the VPNs at vpn-<env>.<domain>.
  domain_name = "url-e.online"

  ssm_parameter_prefix = "/urle/global"
}
