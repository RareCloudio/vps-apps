#!/usr/bin/env bash
# Base step 6: the HTTPS reverse proxy (caddy-docker-proxy behind a socket proxy), the install
# status over HTTP, the landing pages and the wait for DNS. Sourced, never executed.

VA_PROXY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Image tags; the compose .env stores them as image@sha256:... (resolved at install).
VA_CADDY_IMAGE_REF="lucaslorentz/caddy-docker-proxy:2.13.1-alpine"
VA_SOCKET_PROXY_IMAGE_REF="tecnativa/docker-socket-proxy:latest"

# resolve_image_digest <repo:tag>: echo repo@sha256:<64 hex> for the manifest the tag points to
# today. Also used by rc update.
resolve_image_digest() {
  local ref="$1" digest
  digest="$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' | jq -r '.digest')"
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    log "cannot resolve a digest for $ref"
    return 1
  fi
  printf '%s@%s\n' "${ref%:*}" "$digest"
}

# install_atomic <src> <dest> <mode>: copy through a temp file in the destination directory
# and rename, so a reader of a mounted directory never sees a partial file.
install_atomic() {
  local src="$1" dest="$2" mode="$3" tmp
  tmp="$(mktemp "$(dirname "$dest")/.tmp.XXXXXX")"
  if ! { cat "$src" >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# set_site_mode http-only|installing|failed|app
#   http-only   the installing page on http://<VA_HOST>, no HTTPS site (no certificate yet)
#   installing  HTTPS site for VA_HOST with the installing page
#   failed      HTTPS site for VA_HOST with the failed page
#   app         no site for VA_HOST here: the app container's labels own it
# The status on :80 by IP is in every mode. Never reloads caddy: caddy-docker-proxy rebuilds its
# config from this file and the labels on Docker events and every polling interval.
set_site_mode() {
  local mode="$1" page="" addr="" dir tmp sites=""
  case "$mode" in
    http-only) page=installing.html addr="http://${VA_HOST}" ;;
    installing) page=installing.html addr="${VA_HOST}" ;;
    failed) page=failed.html addr="${VA_HOST}" ;;
    app) ;;
    *)
      log "set_site_mode: unknown mode $mode"
      return 1
      ;;
  esac
  if [ -n "$page" ]; then
    sites="$(printf '\n%s {\n\troot * /srv/public\n\thandle /.well-known/rarecloud-app-status {\n\t\theader Content-Type text/plain\n\t\theader Cache-Control no-store\n\t\tfile_server\n\t}\n\thandle {\n\t\trewrite * /%s\n\t\tfile_server\n\t}\n}\n' "$addr" "$page")"
  fi

  dir="$(p /etc/vps-apps/caddy)"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.Caddyfile.XXXXXX")"
  if ! {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "@SITES@" ]; then
        [ -z "$sites" ] || printf '%s\n' "$sites"
      else
        printf '%s\n' "${line//@MODE@/$mode}"
      fi
    done <"$VA_PROXY_DIR/proxy/Caddyfile.tmpl" >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$dir/Caddyfile"
  }; then
    rm -f "$tmp"
    return 1
  fi

  mkdir -p "$(p /var/lib/vps-apps)"
  printf '%s' "$mode" >"$(p /var/lib/vps-apps/site-mode.tmp)"
  mv -f "$(p /var/lib/vps-apps/site-mode.tmp)" "$(p /var/lib/vps-apps/site-mode)"
  log "site mode: $mode"
}

# wait_for_name <host> <ip> <max_seconds>: 0 once the public resolver 1.1.1.1 (not the local one,
# which caches "no such name") returns <ip> for <host>, 1 after max_seconds. Callers carry on either way.
wait_for_name() {
  local host="$1" ip="$2" max="$3" waited=0
  while :; do
    if dig +short @1.1.1.1 A "$host" | grep -qxF "$ip"; then
      return 0
    fi
    [ "$waited" -lt "$max" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
}

base_proxy() {
  local data pub caddy_image socket_image env_tmp
  data="$(p /opt/vps-apps-data/proxy)"
  pub="$(p /var/lib/vps-apps/public)"
  mkdir -p "$data" "$pub"

  caddy_image="$(resolve_image_digest "$VA_CADDY_IMAGE_REF")"
  socket_image="$(resolve_image_digest "$VA_SOCKET_PROXY_IMAGE_REF")"
  install_atomic "$VA_PROXY_DIR/proxy/compose.yml" "$data/compose.yml" 0644
  env_tmp="$(mktemp "$data/.env.XXXXXX")"
  printf 'CADDY_IMAGE=%s\nSOCKET_PROXY_IMAGE=%s\n' "$caddy_image" "$socket_image" >"$env_tmp"
  chmod 0644 "$env_tmp"
  mv -f "$env_tmp" "$data/.env"

  install_atomic "$VA_PROXY_DIR/www/installing.html" "$pub/installing.html" 0644
  install_atomic "$VA_PROXY_DIR/www/failed.html" "$pub/failed.html" 0644

  set_site_mode http-only
  docker network inspect web >/dev/null 2>&1 || docker network create web
  docker compose -f "$data/compose.yml" --env-file "$data/.env" up -d

  # No certificate can be issued before the name points here; carry on after the wait either way.
  if ! wait_for_name "$VA_HOST" "$VA_IP" 300; then
    log "proxy: $VA_HOST does not resolve to $VA_IP yet, continuing"
  fi
  set_site_mode installing
}
