#!/usr/bin/env bash
# Base step 6: the HTTPS reverse proxy (caddy-docker-proxy behind a socket proxy), the install
# status over HTTP, the landing pages and the wait for DNS. Sourced after lib/common.sh and
# lib/images.sh, never executed.

VA_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Image tags; the compose .env stores them as image@sha256:... (resolved at install).
VA_CADDY_IMAGE_REF="lucaslorentz/caddy-docker-proxy:2.13.1-alpine"
VA_SOCKET_PROXY_IMAGE_REF="tecnativa/docker-socket-proxy:latest"

# set_site_mode http-only|installing|failed|app
#   http-only   the installing page on http://<VA_HOST>, no HTTPS site (no certificate yet)
#   installing  HTTPS site for VA_HOST with the installing page
#   failed      HTTPS site for VA_HOST with the failed page
#   app         no site for VA_HOST here: the app container's labels own it
# The status on :80 is in every mode. Never reloads caddy: caddy-docker-proxy rebuilds its config
# from this file and the labels on Docker events and every polling interval.
set_site_mode() {
  local mode="$1" page="" addr="" dir sites="" line
  case "$mode" in
    http-only) page=installing.html addr="http://${VA_HOST:-}" ;;
    installing) page=installing.html addr="${VA_HOST:-}" ;;
    failed) page=failed.html addr="${VA_HOST:-}" ;;
    app) ;;
    *)
      log "set_site_mode: unknown mode $mode"
      return 1
      ;;
  esac
  if [ -n "$page" ]; then
    if [ -z "${VA_HOST:-}" ]; then
      log "set_site_mode: $mode needs VA_HOST"
      return 1
    fi
    sites="$(printf '\n%s {\n\troot * /srv/public\n\thandle /.well-known/rarecloud-app-status {\n\t\theader Content-Type text/plain\n\t\theader Cache-Control no-store\n\t\tfile_server\n\t}\n\thandle {\n\t\trewrite * /%s\n\t\tfile_server\n\t}\n}\n' "$addr" "$page")"
  fi

  dir="$(p /etc/vps-apps/caddy)"
  mkdir -p "$dir"
  {
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "@SITES@" ]; then
        [ -z "$sites" ] || printf '%s\n' "$sites"
      else
        printf '%s\n' "${line//@MODE@/$mode}"
      fi
    done <"$VA_BASE_DIR/proxy/Caddyfile.tmpl"
  } | write_atomic "$dir/Caddyfile" 0644

  mkdir -p "$(p /var/lib/vps-apps)"
  printf '%s' "$mode" | write_atomic "$(p /var/lib/vps-apps/site-mode)" 0644
  log "site mode: $mode"
}

# wait_for_name <host> <ip> <max_seconds>: 0 once the public resolver 1.1.1.1 (not the local one,
# which caches "no such name") returns <ip> for <host>, 1 at the wall-clock deadline. Each dig
# call is capped at about 2 seconds, so the total stays near max_seconds. Callers carry on either way.
wait_for_name() {
  local host="$1" ip="$2" max="$3" deadline
  deadline=$((SECONDS + max))
  while :; do
    if dig +short +time=2 +tries=1 @1.1.1.1 A "$host" | grep -qxF "$ip"; then
      return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

base_proxy() {
  local data pub caddy_image socket_image
  data="$(p /opt/vps-apps-data/proxy)"
  pub="$(p /var/lib/vps-apps/public)"
  mkdir -p "$data" "$pub"

  caddy_image="$(resolve_image_digest "$VA_CADDY_IMAGE_REF")" || return 1
  socket_image="$(resolve_image_digest "$VA_SOCKET_PROXY_IMAGE_REF")" || return 1
  write_atomic "$data/compose.yml" 0644 <"$VA_BASE_DIR/proxy/compose.yml"
  printf 'CADDY_IMAGE=%s\nSOCKET_PROXY_IMAGE=%s\n' "$caddy_image" "$socket_image" | write_atomic "$data/.env" 0644

  write_atomic "$pub/installing.html" 0644 <"$VA_BASE_DIR/www/installing.html"
  write_atomic "$pub/failed.html" 0644 <"$VA_BASE_DIR/www/failed.html"

  set_site_mode http-only
  docker network inspect web >/dev/null 2>&1 || docker network create web
  docker compose -f "$data/compose.yml" --env-file "$data/.env" up -d
  # The step succeeds only once the proxy answers on port 80.
  curl -fsS --retry 15 --retry-connrefused --retry-delay 2 http://127.0.0.1/.well-known/rarecloud-app-status || {
    log "proxy: nothing answers on port 80"
    return 1
  }

  # No certificate can be issued before the name points here; carry on after the wait either way.
  if ! wait_for_name "$VA_HOST" "$VA_IP" 300; then
    log "proxy: $VA_HOST does not resolve to $VA_IP yet, continuing"
  fi
  set_site_mode installing
}
