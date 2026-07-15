#!/usr/bin/env bash
# wg-easy (WireGuard + admin UI) fronted by Caddy for TLS. The UI listens on
# loopback only — the sole way in is Caddy on 443.
set -euo pipefail

dnf install -y docker
systemctl enable --now docker

# Values are single-quoted: bcrypt hashes contain `$`, which bash must not
# expand. Terraform's templatefile has already interpolated by the time this
# script runs.
docker run -d --name wg-easy --restart unless-stopped \
  -e WG_HOST='${wg_host}' \
  -e PASSWORD_HASH='${password_hash}' \
  -e WG_DEFAULT_DNS='${dns_server}' \
  -e WG_ALLOWED_IPS='${allowed_ips}' \
  -v /etc/wg-easy:/etc/wireguard \
  -p 51820:51820/udp \
  -p 127.0.0.1:51821:51821/tcp \
  --cap-add NET_ADMIN --cap-add SYS_MODULE \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  ghcr.io/wg-easy/wg-easy:14

docker run -d --name caddy --restart unless-stopped --network host \
  caddy:2.8-alpine \
  caddy reverse-proxy --from '${caddy_from}' --to 127.0.0.1:51821 ${caddy_extra}
