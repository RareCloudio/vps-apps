#!/usr/bin/env bash
# Renders the base Caddyfile in all four site modes and has the pinned caddy-docker-proxy image
# parse each one (caddy adapt), so invalid syntax fails here and not on a customer's server.
# Needs Docker and network access to pull the image.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export VPS_APPS_ROOT="$tmp/root"
mkdir -p "$VPS_APPS_ROOT"
# shellcheck source=/dev/null
. "$root/lib/common.sh"
# shellcheck source=/dev/null
. "$root/base/60-proxy.sh"
export VA_HOST="app.example.com"

for mode in http-only installing failed app; do
  set_site_mode "$mode"
  conf="$tmp/$mode"
  mkdir -p "$conf"
  cp "$(p /etc/vps-apps/caddy/Caddyfile)" "$conf/Caddyfile"
  chmod 0755 "$conf"
  echo "adapting the $mode Caddyfile"
  docker run --rm --entrypoint caddy -v "$conf:/etc/caddy:ro" "$VA_CADDY_IMAGE_REF" \
    adapt --adapter caddyfile --config /etc/caddy/Caddyfile >/dev/null
done
echo "all four Caddyfiles parse"
