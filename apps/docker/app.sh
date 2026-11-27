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
  local f
  local -a args=()
  while IFS= read -r f; do
    args+=(-f "$f")
  done < <(app_compose_files)
  docker compose "${args[@]}" --env-file "$(app_data_dir)/.env" "$@"
}

# app_site_addrs: VA_HOST first, then every valid, new line of /etc/vps-apps/domains, space separated.
# Each line is validated again here because it ends up inside a caddy label.
app_site_addrs() {
  local addrs="$VA_HOST" line file
  file="$(p /etc/vps-apps/domains)"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line,,}"
      if ! valid_hostname "$line"; then
        [ -z "$line" ] || log "docker: ignoring invalid domain line in $file"
        continue
      fi
      case " $addrs " in *" $line "*) continue ;; esac
      addrs="$addrs $line"
    done <"$file"
  fi
  printf '%s\n' "$addrs"
}

# app_write_env <image> <addrs>: the app .env, replaced atomically.
app_write_env() {
  printf 'LANDING_IMAGE=%s\nLANDING_IMAGE_REF=%s\nVA_SITE_ADDRS="%s"\n' "$1" "$VA_DOCKER_IMAGE_REF" "$2" |
    write_atomic "$(app_data_dir)/.env" 0644
}

app_prepare() {
  local data image
  data="$(app_data_dir)"
  mkdir -p "$data/www"
  write_atomic "$data/www/index.html" 0644 <"$VA_APP_DIR/www/index.html"
  image="$(resolve_image_digest "$VA_DOCKER_IMAGE_REF")" || return 1
  app_write_env "$image" "$(app_site_addrs)"
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
    set_site_mode failed
    return 1
  fi
}

# The landing page must answer over HTTPS on the server's own name with a valid certificate.
app_ready_check() {
  curl -fsS --max-time 10 --resolve "$VA_HOST:443:127.0.0.1" "https://$VA_HOST/" |
    grep -q 'Your Docker server is ready'
}

app_domain_added() {
  local image
  image="$(sed -n 's/^LANDING_IMAGE=//p' "$(app_data_dir)/.env" | head -n1)"
  app_write_env "$image" "$(app_site_addrs)"
  app_compose up -d
}
