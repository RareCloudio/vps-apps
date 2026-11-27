#!/usr/bin/env bash
# The "docker" app: a plain Docker server with a landing page. Sourced by install.sh and by rc,
# never executed.
#
# The app hook contract every app implements (n8n follows it too):
#   app_prepare                 write the app's files and .env under /opt/vps-apps-data/<app>
#   app_up_setup                start the app without exposure
#   app_create_admin <pwfile>   create the first account from the password file
#   app_expose                  write the marker "exposed", set_site_mode app, start with the labels
#   app_ready_check             0 when the app answers healthy on its own HTTPS name
#   app_compose_files           print absolute compose file paths, one per line; the expose file only
#                               once the marker exists
#   app_domain_added <domain>   apply /etc/vps-apps/domains to the labels
#   app_domain_check <domain>   optional: return 1 with a message when the app takes no extra domain
#   app_fill_env <env>          optional: add to <env> itself what a newer release of the app needs,
#                               keeping every value; rc update runs it first, before any resolution
#   app_update_env <env> <out>  optional: write to <out> what rc update makes of the app .env, without
#                               writing <env>; fails when an image cannot be resolved. Without it, rc
#                               update re-resolves the images (resolve_env_images in lib/images.sh)
# In site mode app the app's own caddy labels carry VA_HOST; the base Caddyfile has no block for it.

VA_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VA_DOCKER_IMAGE_REF="caddy:2-alpine"

app_data_dir() {
  p /opt/vps-apps-data/docker
}

app_compose_files() {
  printf '%s\n' "$VA_APP_DIR/compose.yml"
  if [ -f "$(app_data_dir)/exposed" ]; then
    printf '%s\n' "$VA_APP_DIR/compose.expose.yml"
  fi
}

# app_compose <docker compose args...>
app_compose() {
  compose_run "$(app_data_dir)/.env" "$@"
}

# app_write_env <image>: the app .env, replaced atomically. The landing page owns the server's own
# name, so that is the only label address.
app_write_env() {
  printf 'LANDING_IMAGE=%s\nLANDING_IMAGE_REF=%s\nVA_SITE_ADDRS="%s"\n' "$1" "$VA_DOCKER_IMAGE_REF" "$VA_HOST" |
    write_atomic "$(app_data_dir)/.env" 0644
}

app_prepare() {
  local data image
  data="$(app_data_dir)"
  mkdir -p "$data/www"
  write_atomic "$data/www/index.html" 0644 <"$VA_APP_DIR/www/index.html"
  image="$(resolve_image_digest "$VA_DOCKER_IMAGE_REF")" || return 1
  app_write_env "$image"
}

app_up_setup() {
  :
}

app_create_admin() {
  :
}

app_expose() {
  : >"$(app_data_dir)/exposed"
  set_site_mode app
  if ! app_compose up -d; then
    log "docker: starting the landing page failed"
    # Stop whatever came up, drop the marker (so rc no longer names the expose file) and show the
    # failed page again instead of leaving a half-exposed server.
    app_compose down || true
    rm -f "$(app_data_dir)/exposed"
    set_site_mode failed
    return 1
  fi
}

# The landing page must answer over HTTPS on the server's own name with a valid certificate. The
# body is captured first: a pipe into grep -q can fail curl with error 23 under pipefail.
app_ready_check() {
  local body
  body="$(curl -fsS --max-time 10 --resolve "$VA_HOST:443:127.0.0.1" "https://$VA_HOST/")" || return 1
  grep -q 'Your Docker server is ready' <<<"$body"
}

# On a Docker server the landing container owns the server's own name, and a second site block for
# one name makes Caddy reject the whole config. Domains for the customer's own containers go on
# their caddy labels, so rc domain add has nothing to do here.
app_domain_check() {
  echo "On a Docker server, give a domain to your own container with the caddy labels shown on the landing page" >&2
  return 1
}

app_domain_added() {
  app_domain_check
}
