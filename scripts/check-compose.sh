#!/usr/bin/env bash
# Validates every compose file combination the apps really run, with placeholder values for the
# variables the app .env supplies. An overlay is not valid alone, so each file is checked inside a
# combination. Needs docker compose.
set -euo pipefail
cd "$(dirname "$0")/.."

export VA_SITE_ADDRS=ci.example.com
export POSTGRES_PASSWORD=ci N8N_ENCRYPTION_KEY=ci N8N_HOST=ci.example.com
export WEBHOOK_URL=https://ci.example.com/ N8N_EDITOR_BASE_URL=https://ci.example.com

check() {
  local f label="" args=()
  for f in "$@"; do
    args+=(-f "$f")
    label+=" $f"
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
