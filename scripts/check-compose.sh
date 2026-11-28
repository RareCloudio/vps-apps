#!/usr/bin/env bash
# Validates every compose file combination the apps really run, with placeholder values for the
# variables the app .env supplies. An overlay is not valid alone, so each file is checked inside a
# combination. Needs docker compose.
set -euo pipefail
cd "$(dirname "$0")/.."

export VA_SITE_ADDRS=ci.example.com
export POSTGRES_PASSWORD=ci N8N_ENCRYPTION_KEY=ci VALKEY_PASSWORD=ci N8N_HOST=ci.example.com
export WEBHOOK_URL=https://ci.example.com/ N8N_EDITOR_BASE_URL=https://ci.example.com

checked=" "

check() {
  local f label="" args=()
  for f in "$@"; do
    args+=(-f "$f")
    label+=" $f"
    checked+="$f "
  done
  echo "validating$label"
  docker compose "${args[@]}" config -q
}

check base/proxy/compose.yml
check apps/docker/compose.yml
check apps/docker/compose.yml apps/docker/compose.expose.yml
n8n=apps/n8n
check $n8n/compose.yml $n8n/compose.setup.yml
check $n8n/compose.yml $n8n/compose.expose.yml
check $n8n/compose.yml $n8n/compose.pro.yml $n8n/compose.setup.yml
check $n8n/compose.yml $n8n/compose.pro.yml $n8n/compose.expose.yml
# Nextcloud needs only POSTGRES_PASSWORD, VALKEY_PASSWORD and VA_SITE_ADDRS, set above. The other
# apps' variable names do not overlap, so each app's exports sit right before its checks.
nc=apps/nextcloud
check $nc/compose.yml $nc/compose.setup.yml
check $nc/compose.yml $nc/compose.expose.yml
export FORGEJO_SECRET_KEY=ci FORGEJO_DOMAIN=ci.example.com FORGEJO_ROOT_URL=https://ci.example.com/
fj=apps/forgejo
check $fj/compose.yml $fj/compose.setup.yml
check $fj/compose.yml $fj/compose.expose.yml
export DB_PASSWORD=ci DB_ROOT_PASSWORD=ci WP_HOST=ci.example.com
export WORDPRESS_AUTH_KEY=ci WORDPRESS_SECURE_AUTH_KEY=ci WORDPRESS_LOGGED_IN_KEY=ci WORDPRESS_NONCE_KEY=ci
export WORDPRESS_AUTH_SALT=ci WORDPRESS_SECURE_AUTH_SALT=ci WORDPRESS_LOGGED_IN_SALT=ci WORDPRESS_NONCE_SALT=ci
wp=apps/wordpress
check $wp/compose.yml $wp/compose.setup.yml
check $wp/compose.yml $wp/compose.expose.yml
uk=apps/uptimekuma
check $uk/compose.yml $uk/compose.setup.yml
check $uk/compose.yml $uk/compose.expose.yml
# Grafana: its secret key, root URL and the Loki push hash (single-quoted bcrypt in the real .env).
export GRAFANA_SECRET_KEY=ci GRAFANA_ROOT_URL=https://ci.example.com/ LOKI_PUSH_HASH=ci
gf=apps/grafana
check $gf/compose.yml $gf/compose.setup.yml
check $gf/compose.yml $gf/compose.expose.yml
# The CI runner apps have no setup overlay: before exposure the stack is compose.yml alone. They need
# the page's user and group and the login hash (single-quoted bcrypt in the real .env).
export PAGE_UID=999 PAGE_GID=999 RUNNER_PAGE_AUTH_HASH=ci
for rn in apps/ghrunner apps/glrunner; do
  check "$rn/compose.yml"
  check "$rn/compose.yml" "$rn/compose.expose.yml"
done

# Every compose file in the repo must be part of at least one combination above, so a new overlay
# cannot ship unvalidated.
missing=0
for f in apps/*/compose*.y*ml base/*/compose*.y*ml; do
  if [[ "$checked" != *" $f "* ]]; then
    echo "check-compose: $f is in no checked combination" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ]
