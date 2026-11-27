#!/usr/bin/env bash
# The "nextcloud" app: Nextcloud on Postgres, with Valkey for the cache and file locking and a cron
# container for the background jobs. Sourced by install.sh and by rc, never executed. It implements
# the hook contract described in apps/docker/app.sh.
#
# The order that matters: the stack starts with Nextcloud published on 127.0.0.1 only
# (compose.setup.yml). There Nextcloud is installed through occ without any account
# (maintenance:install --disable-admin-user), configured through occ, and only then gets its admin
# account, "admin", from occ user:add. Only then does app_expose swap in compose.expose.yml (the
# caddy labels, no published port), and it refuses while Nextcloud is not installed or the admin is
# missing. Nobody else can ever reach the web installer.
#
# The admin password is only ever read from the password file and reaches occ through OC_PASS in
# the environment of the docker compose exec (--password-from-env, which Nextcloud documents as
# keeping the password out of the process list:
# https://docs.nextcloud.com/server/34/admin_manual/occ_users.html#user-add). It is in no command
# line, compose file, env file or container's configuration.
#
# Nextcloud has no self-registration: the registration app is not shipped, and app_expose refuses
# to expose an instance where it is enabled.

VA_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Nextcloud 34, the major the image's stable and production tags point to (Nextcloud's own stable
# update channel; 35 is the newest major but not on that channel yet): https://github.com/nextcloud/docker/blob/master/generate-stackbrew-library.sh
# A tag per major version, so rc update moves to the newest 34.x and never to another major:
# Nextcloud upgrades one major version at a time, and the image refuses to skip one
# (https://docs.nextcloud.com/server/34/admin_manual/maintenance/upgrade.html).
VA_NEXTCLOUD_IMAGE_REF="nextcloud:34-apache"
# Postgres 16 is supported by Nextcloud 34:
# https://docs.nextcloud.com/server/34/admin_manual/installation/system_requirements.html
VA_NEXTCLOUD_POSTGRES_IMAGE_REF="postgres:16-alpine"
VA_NEXTCLOUD_VALKEY_IMAGE_REF="valkey/valkey:8-alpine"
# Nextcloud on the loopback port of compose.setup.yml.
VA_NC_LOOPBACK="http://127.0.0.1:8080"
# The minimum length of Nextcloud's default password policy (the password_policy app's minLength).
VA_NC_MIN_PASSWORD=10

app_data_dir() {
  p /opt/vps-apps-data/nextcloud
}

app_compose_files() {
  printf '%s\n' "$VA_APP_DIR/compose.yml"
  if [ -f "$(app_data_dir)/exposed" ]; then
    printf '%s\n' "$VA_APP_DIR/compose.expose.yml"
  else
    printf '%s\n' "$VA_APP_DIR/compose.setup.yml"
  fi
}

# app_compose <docker compose args...>
app_compose() {
  compose_run "$(app_data_dir)/.env" "$@"
}

# app_site_addrs: the server's own name first, then every valid extra domain from
# /etc/vps-apps/domains (one per line), separated by spaces. The caddy label uses it byte for byte,
# and trusted_domains holds the same names.
app_site_addrs() {
  local addrs="$VA_HOST" f line
  f="$(p /etc/vps-apps/domains)"
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if valid_hostname "$line" && [ "$line" != "$VA_HOST" ] && [[ " $addrs " != *" $line "* ]]; then
        addrs+=" $line"
      fi
    done <"$f"
  fi
  printf '%s' "$addrs"
}

# app_prepare: the .env, created once. An existing .env is kept as it is, so every secret stays
# byte-identical on a re-run. Every image is resolved before anything is written.
app_prepare() {
  local data nc_image pg_image valkey_image line out="" key
  data="$(app_data_dir)"
  mkdir -p "$data"
  [ ! -f "$data/.env" ] || return 0

  nc_image="$(resolve_image_digest "$VA_NEXTCLOUD_IMAGE_REF")" || return 1
  pg_image="$(resolve_image_digest "$VA_NEXTCLOUD_POSTGRES_IMAGE_REF")" || return 1
  valkey_image="$(resolve_image_digest "$VA_NEXTCLOUD_VALKEY_IMAGE_REF")" || return 1

  local -A vars=(
    [NEXTCLOUD_IMAGE]="$nc_image" [NEXTCLOUD_IMAGE_REF]="$VA_NEXTCLOUD_IMAGE_REF"
    [POSTGRES_IMAGE]="$pg_image" [POSTGRES_IMAGE_REF]="$VA_NEXTCLOUD_POSTGRES_IMAGE_REF"
    [VALKEY_IMAGE]="$valkey_image" [VALKEY_IMAGE_REF]="$VA_NEXTCLOUD_VALKEY_IMAGE_REF"
    [POSTGRES_PASSWORD]="$(openssl rand -hex 24)"
    [VALKEY_PASSWORD]="$(openssl rand -hex 32)"
    [VA_SITE_ADDRS]="$(app_site_addrs)"
  )
  while IFS= read -r line || [ -n "$line" ]; do
    for key in "${!vars[@]}"; do
      line="${line//@${key}@/"${vars[$key]}"}"
    done
    out+="$line"$'\n'
  done <"$VA_APP_DIR/env.tmpl"
  printf '%s' "$out" | write_atomic "$data/.env" 0600
}

app_up_setup() {
  app_compose up -d
}

# nc_occ <occ args...>: one occ command as www-data in the running Nextcloud container, with no TTY,
# no prompt and no stdin (https://github.com/nextcloud/docker#accessing-the-nextcloud-command-line-interface-occ).
nc_occ() {
  app_compose exec -T -u www-data nextcloud php occ --no-interaction "$@" </dev/null
}

# nc_status: what status.php answers on the loopback port (a JSON object with "installed"), or a
# failure. Apache only starts once the image's entrypoint has copied the code into the volume, and
# status.php always trusts a 127.0.0.1 host.
nc_status() {
  local body
  body="$(curl -fsS --max-time 30 "$VA_NC_LOOPBACK/status.php" 2>/dev/null)" || return 1
  jq -e 'type == "object" and has("installed")' <<<"$body" >/dev/null 2>&1 || return 1
  printf '%s\n' "$body"
}

# nc_wait_for_web: wait, bounded, until Nextcloud answers status.php on the loopback port. The first
# start copies the whole code into the volume before Apache listens, so the wait is long.
nc_wait_for_web() {
  local deadline
  deadline=$((SECONDS + ${VA_NC_WAIT:-600}))
  until nc_status >/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "nextcloud: no answer on $VA_NC_LOOPBACK/status.php"
      return 1
    fi
    sleep "${VA_NC_INTERVAL:-3}"
  done
}

# nc_installed: status.php says Nextcloud is installed.
nc_installed() {
  local body
  body="$(nc_status)" || return 1
  jq -e '.installed == true' <<<"$body" >/dev/null 2>&1
}

# nc_install: occ maintenance:install on Postgres, with no admin account (user:add makes it next, so
# no throwaway admin password exists at any point). maintenance:install takes the database password
# only as --database-pass (https://docs.nextcloud.com/server/34/admin_manual/occ_system.html#command-line-installation):
# it reaches the exec through its environment, taken by docker compose from this function's own,
# and the container's shell puts it there, as the image's own entrypoint does at auto-install. It is
# the Postgres superuser's password from the .env, used only here: Nextcloud then makes its own
# database login with a password of its own in config.php. Only the first line of a failure is
# logged, because the install prints traces that can hold connection arguments.
nc_install() {
  local pw out
  pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$(app_data_dir)/.env" | tail -n 1)"
  if [ -z "$pw" ]; then
    log "nextcloud: no POSTGRES_PASSWORD in $(app_data_dir)/.env"
    return 1
  fi
  # shellcheck disable=SC2016 # the container's shell expands POSTGRES_PASSWORD
  if ! out="$(
    export POSTGRES_PASSWORD="$pw"
    app_compose exec -T -u www-data -e POSTGRES_PASSWORD nextcloud sh -c \
      'exec php occ --no-interaction maintenance:install --database pgsql --database-host postgres --database-name nextcloud --database-user nextcloud --database-pass "$POSTGRES_PASSWORD" --disable-admin-user' \
      </dev/null 2>&1
  )"; then
    log "nextcloud: maintenance:install failed: $(head -n 1 <<<"$out" | head -c 200)"
    return 1
  fi
}

# nc_web_subnets: the subnets of the proxy's web network, one per line: Caddy reaches Nextcloud from
# an address there. Fails when there is none or one is not an IPv4 or IPv6 CIDR.
nc_web_subnets() {
  local out s n=0
  out="$(docker network inspect web --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}')" || return 1
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if ! [[ "$s" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ || "$s" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; then
      log "nextcloud: '$s' from the web network is not a subnet"
      return 1
    fi
    printf '%s\n' "$s"
    n=$((n + 1))
  done <<<"$out"
  [ "$n" -gt 0 ]
}

# nc_configure <url-host>: the system settings, through occ, idempotent:
#   - trusted_domains: every name the proxy serves (app_site_addrs);
#   - trusted_proxies: the web network, so the client address comes from Caddy's X-Forwarded-For;
#   - overwriteprotocol https, since Nextcloud only sees plain HTTP from Caddy, and
#     overwrite.cli.url on <url-host> for the links background jobs write. overwritehost stays unset,
#     so every trusted name keeps its own links
#     (https://docs.nextcloud.com/server/34/admin_manual/configuration_server/reverse_proxy_configuration.html);
#   - maintenance_window_start at 01:00 UTC for the heavy daily jobs, and background jobs in cron
#     mode (https://docs.nextcloud.com/server/34/admin_manual/configuration_server/background_jobs_configuration.html).
# Everything is read before the first setting is written.
nc_configure() {
  local subnets domains proxies
  if ! subnets="$(nc_web_subnets)"; then
    log "nextcloud: cannot read the subnets of the web network"
    return 1
  fi
  domains="$(jq -cn --arg s "$(app_site_addrs)" '$s | split(" ")')" || return 1
  proxies="$(jq -cRn '[inputs | select(length > 0)]' <<<"$subnets")" || return 1
  nc_occ config:system:set trusted_domains --type=json "--value=$domains" >/dev/null &&
    nc_occ config:system:set trusted_proxies --type=json "--value=$proxies" >/dev/null &&
    nc_occ config:system:set overwriteprotocol --value=https >/dev/null &&
    nc_occ config:system:set overwrite.cli.url "--value=https://$1" >/dev/null &&
    nc_occ config:system:set maintenance_window_start --type=integer --value=1 >/dev/null &&
    nc_occ background:cron >/dev/null
}

# nc_password_ok <file>: a password Nextcloud's default policy can take, judged on the exact bytes
# of the file: printable ASCII (space included), from VA_NC_MIN_PASSWORD characters up to
# Nextcloud's maximum of 469. Anything else deterministically takes the generated fallback. The
# rest of the policy (not among the common passwords, not in a known breach) is Nextcloud's own
# verdict, read by nc_put_admin.
nc_password_ok() {
  local LC_ALL=C pw
  pw="$(
    cat "$1"
    printf x
  )"
  pw="${pw%x}"
  [[ "$pw" =~ ^[[:print:]]+$ ]] || return 1
  [ "${#pw}" -ge "$VA_NC_MIN_PASSWORD" ] && [ "${#pw}" -le 469 ]
}

# nc_occ_json <occ args...>: the JSON line an occ command prints with --output=json, which is its
# last line (a PHP notice can come before it), or a failure.
nc_occ_json() {
  local out
  out="$(nc_occ "$@" --output=json 2>/dev/null)" || return 1
  out="$(tail -n 1 <<<"$out")"
  jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

# nc_admin_info: the admin account as occ user:info prints it (JSON), or a failure when it does not
# exist or the answer cannot be read.
nc_admin_info() {
  local out
  out="$(nc_occ_json user:info admin)" || return 1
  jq -e '.user_id == "admin"' <<<"$out" >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

# nc_admin_ready: the admin account exists, is enabled and is in the admin group.
nc_admin_ready() {
  local info
  info="$(nc_admin_info)" || return 1
  jq -e '.enabled == true and ((.groups // []) | index("admin") != null)' <<<"$info" >/dev/null 2>&1
}

# nc_put_admin <password-file>: the admin account with the exact password from the file: created in
# the admin group (user:add) when it does not exist yet, else its password set again
# (user:resetpassword) and its admin group membership made sure, for a retry after an interrupted
# run. The password reaches occ only as OC_PASS in the exec's environment, which docker compose
# takes from this function's own (-e with a name and no value). Returns 0 once the admin is ready,
# 2 when Nextcloud's password policy refuses the password (its messages start "Password needs" or
# "Password is"), 1 for anything else.
nc_put_admin() {
  local out
  local -a cmd=(user:add --password-from-env --group admin admin)
  if nc_admin_info >/dev/null; then
    cmd=(user:resetpassword --password-from-env admin)
  fi
  if ! out="$(
    OC_PASS="$(
      cat "$1"
      printf x
    )"
    OC_PASS="${OC_PASS%x}"
    export OC_PASS
    app_compose exec -T -u www-data -e OC_PASS nextcloud php occ --no-interaction "${cmd[@]}" </dev/null 2>&1
  )"; then
    # The message starts its line, after any terminal colour codes.
    if grep -qE $'^(\e\\[[0-9;]*m)*Password (needs|is) ' <<<"$out"; then
      return 2
    fi
    log "nextcloud: ${cmd[0]} for the admin failed: $(head -n 1 <<<"$out" | head -c 200)"
    return 1
  fi
  if ! nc_admin_ready; then
    nc_occ group:adduser admin admin >/dev/null 2>&1 || true
    if ! nc_admin_ready; then
      log "nextcloud: the admin account is not an enabled member of the admin group"
      return 1
    fi
  fi
}

# nc_fallback_password_file <file>: write a password that satisfies Nextcloud's policy into <file>
# and keep it in /root/vps-apps-credentials.txt (mode 600). A retry reuses the one already there.
nc_fallback_password_file() {
  local cred
  cred="$(p /root/vps-apps-credentials.txt)"
  if [ -f "$cred" ]; then
    sed -n 's/^Password: //p' "$cred" | head -n1 | tr -d '\n' >"$1"
  fi
  if [ ! -s "$1" ]; then
    printf 'Rc9%s' "$(openssl rand -hex 16)" >"$1"
    (
      umask 077
      mkdir -p "$(dirname "$cred")"
      printf 'Nextcloud admin login, generated because the password you chose does not meet the Nextcloud password policy\nLogin: admin\nPassword: %s\n' \
        "$(cat "$1")" | write_atomic "$cred" 0600
    )
  fi
}

# app_create_admin <password-file>: install Nextcloud when status.php says it is not installed yet,
# apply the occ settings, then make the admin account. A password that Nextcloud's policy refuses
# (by nc_password_ok or by Nextcloud's own verdict) is replaced by a generated one in
# /root/vps-apps-credentials.txt, and the call is made again. Once that file exists, a retry uses
# its password, so the file always holds the login that works.
app_create_admin() {
  local pwfile="$1" tmp="" rc=0 cred
  cred="$(p /root/vps-apps-credentials.txt)"
  nc_wait_for_web || return 1
  if ! nc_installed; then
    nc_install || return 1
    if ! nc_installed; then
      log "nextcloud: status.php does not say installed after maintenance:install"
      return 1
    fi
  fi
  if ! nc_configure "$VA_HOST"; then
    log "nextcloud: the occ settings failed"
    return 1
  fi
  tmp="$(mktemp "$(app_data_dir)/.admin-pw.XXXXXX")"
  chmod 600 "$tmp"
  if [ -f "$cred" ]; then
    log "nextcloud: using the generated password from an earlier attempt"
    nc_fallback_password_file "$tmp"
    pwfile="$tmp"
  elif ! nc_password_ok "$pwfile"; then
    log "nextcloud: the chosen password does not meet Nextcloud's password policy, using a generated one"
    nc_fallback_password_file "$tmp"
    pwfile="$tmp"
  fi
  nc_put_admin "$pwfile" || rc=$?
  if [ "$rc" -eq 2 ] && [ "$pwfile" != "$tmp" ]; then
    log "nextcloud: Nextcloud's password policy refused the chosen password, using a generated one"
    nc_fallback_password_file "$tmp"
    rc=0
    nc_put_admin "$tmp" || rc=$?
  fi
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || return 1
}

# nc_exposable: Nextcloud may face the internet: status.php says installed, not in maintenance and
# not waiting for a database upgrade; the admin account is ready; the registration app (open signup)
# is not enabled. Fails closed on any answer it cannot read.
nc_exposable() {
  local body apps
  body="$(nc_status)" || return 1
  jq -e '.installed == true and .maintenance == false and .needsDbUpgrade == false' <<<"$body" >/dev/null 2>&1 || return 1
  nc_admin_ready || return 1
  apps="$(nc_occ_json app:list)" || return 1
  jq -e '(.enabled | type) == "object" and (.enabled | has("registration") | not)' <<<"$apps" >/dev/null 2>&1
}

# app_expose: first puts the stack back into setup state (marker removed, Nextcloud published on the
# loopback port only) and waits for it. That makes a retry after a failed or interrupted expose
# recover on its own, and it is where the checks can be made. Then it refuses unless nc_exposable
# holds, so Nextcloud's installer or an instance without its admin is never put on the internet.
app_expose() {
  rm -f "$(app_data_dir)/exposed"
  if ! app_compose up -d; then
    log "nextcloud: cannot bring the setup stack up before exposing"
    return 1
  fi
  if ! nc_wait_for_web; then
    return 1
  fi
  if ! nc_exposable; then
    log "nextcloud: refusing to expose, it is not installed with its admin, or its state is unreadable"
    return 1
  fi
  : >"$(app_data_dir)/exposed"
  set_site_mode app
  if ! app_compose up -d; then
    log "nextcloud: starting the exposed stack failed"
    # Stop whatever came up, drop the marker (so rc names the setup file again) and show the failed
    # page instead of leaving a half-exposed server.
    app_compose down || true
    rm -f "$(app_data_dir)/exposed"
    set_site_mode failed
    return 1
  fi
}

# Nextcloud must answer status.php over HTTPS on the server's own name with a valid certificate,
# installed, out of maintenance and with no database upgrade pending, so ready means the login page
# works.
app_ready_check() {
  local body
  body="$(curl -fsS --max-time 10 --resolve "$VA_HOST:443:127.0.0.1" "https://$VA_HOST/status.php")" || return 1
  jq -e '.installed == true and .maintenance == false and .needsDbUpgrade == false' <<<"$body" >/dev/null 2>&1
}

# app_domain_added <domain>: Nextcloud first trusts every name (the host and /etc/vps-apps/domains)
# and moves overwrite.cli.url to the domain just added, the newest one; then the label's address
# list is rewritten and Nextcloud recreated with it. An invalid name leaves overwrite.cli.url on the
# server's own name. A failed setting changes neither the .env nor the running stack.
app_domain_added() {
  local env_file line key out="" site_addrs url_host="$VA_HOST"
  env_file="$(app_data_dir)/.env"
  site_addrs="$(app_site_addrs)"
  if valid_hostname "${1:-}"; then
    url_host="$1"
  fi
  if ! nc_configure "$url_host"; then
    log "nextcloud: the occ settings for $url_host failed"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    if [ "$key" = VA_SITE_ADDRS ]; then
      line="VA_SITE_ADDRS=\"$site_addrs\""
    fi
    out+="$line"$'\n'
  done <"$env_file"
  printf '%s' "$out" | write_atomic "$env_file" 0600
  app_compose up -d
}
