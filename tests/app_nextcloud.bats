#!/usr/bin/env bats
load test_helper

setup() {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  APP_DIR="$ROOT_DIR/apps/nextcloud"
  # shellcheck source=../lib/common.sh
  . "$ROOT_DIR/lib/common.sh"
  # shellcheck source=../lib/compose.sh
  . "$ROOT_DIR/lib/compose.sh"
  # shellcheck source=../lib/images.sh
  . "$ROOT_DIR/lib/images.sh"
  # shellcheck source=../lib/steps.sh
  . "$ROOT_DIR/lib/steps.sh"
  # shellcheck source=../base/60-proxy.sh
  . "$ROOT_DIR/base/60-proxy.sh"
  # shellcheck source=../apps/nextcloud/app.sh
  . "$APP_DIR/app.sh"
  VA_HOST=nc.example.com
  export VA_HOST
  DATA="$(p /opt/vps-apps-data/nextcloud)"
  CRED="$(p /root/vps-apps-credentials.txt)"
  PWF="$BATS_TEST_TMPDIR/password"
  printf '%s' 'Secret1234X' >"$PWF"
  export VA_NC_WAIT=2 VA_NC_INTERVAL=0
  # The fake Nextcloud's state: files in NC (see fake_occ).
  NC="$BATS_TEST_TMPDIR/nc"
  mkdir -p "$NC"
  DLOG="$STUB_TMP/docker.log"
  CURL_ARGV="$BATS_TEST_TMPDIR/curl_argv"
  : >"$CURL_ARGV"
  stub_docker
  stub_curl
}

# A docker that answers the compose and network calls the app makes, and hands every other call
# (the image digest lookups) to the docker stub on PATH. Every call is logged to docker.log as one
# line of its arguments, like the stub on PATH.
stub_docker() {
  docker() {
    case "$1" in
      compose)
        printf '%s\n' "$*" >>"$DLOG"
        if [[ " $* " == *" exec "* ]]; then
          fake_occ "$@"
          return
        fi
        if [ -n "${COMPOSE_FAIL_MATCH:-}" ] && [[ "$*" == *$COMPOSE_FAIL_MATCH* ]]; then
          return 1
        fi
        return 0
        ;;
      network)
        printf '%s\n' "$*" >>"$DLOG"
        [ ! -e "$NC/no_subnet" ] || return 1
        printf '%s\n' "${WEB_SUBNETS-172.18.0.0/16}"
        return 0
        ;;
    esac
    command docker "$@"
  }
}

# fake_password_from_env: what occ does with --password-from-env, judged like Nextcloud's default
# password policy (10 characters at least, not on the common list in NC/common). The value is read
# by a child process, so only an exported OC_PASS counts.
fake_password_from_env() {
  local pw
  sh -c 'printf "%s" "${OC_PASS-}"' >"$NC/oc_pass"
  pw="$(cat "$NC/oc_pass")"
  if [ -z "$pw" ]; then
    echo '--password-from-env given, but NC_PASS/OC_PASS is empty!'
    return 1
  fi
  if [ "${#pw}" -lt 10 ]; then
    if [ -e "$NC/ansi" ]; then
      printf '[37;41mPassword needs to be at least 10 characters long.[39;49m
'
    else
      echo 'Password needs to be at least 10 characters long.'
    fi
    return 1
  fi
  if grep -qxF -- "$pw" "$NC/common" 2>/dev/null; then
    echo 'Password is among the 1,000,000 most common ones. Please make it unique.'
    return 1
  fi
}

# fake_occ <docker compose args...>: the occ commands the app runs through docker compose exec.
#   NC/installed    Nextcloud is installed (maintenance:install creates it; NC/install_fail fails it)
#   NC/admin        the admin account exists, holding its password; NC/admin_group: it is an admin
#   NC/add_fail     user:add fails with a generic error; NC/config_fail: config:system:set fails
#   NC/registration the registration app is enabled
#   NC/noise        a PHP notice line comes before every JSON answer
fake_occ() {
  if [ -e "$NC/noise" ] && [[ "$*" == *"--output=json" ]]; then
    echo 'PHP Deprecated:  Something is deprecated in /var/www/html/lib/base.php on line 1'
  fi
  case "$*" in
    *" maintenance:install "*)
      sh -c 'printf "%s" "${POSTGRES_PASSWORD-}"' >"$NC/install_db_pass"
      if [ -e "$NC/install_fail" ]; then
        echo 'Error while trying to initialise the database: boom'
        return 1
      fi
      : >"$NC/installed"
      echo 'Nextcloud was successfully installed'
      ;;
    *" user:info admin --output=json")
      if [ ! -e "$NC/admin" ]; then
        echo 'user not found'
        return 1
      fi
      if [ -e "$NC/admin_group" ]; then
        printf '{"user_id":"admin","display_name":"admin","enabled":true,"groups":["admin"]}\n'
      else
        printf '{"user_id":"admin","display_name":"admin","enabled":true,"groups":[]}\n'
      fi
      ;;
    *" user:add --password-from-env --group admin admin")
      fake_password_from_env || return 1
      if [ -e "$NC/admin" ]; then
        echo 'The account "admin" already exists.'
        return 1
      fi
      if [ -e "$NC/add_fail" ]; then
        echo 'An error occurred while creating the account'
        return 1
      fi
      cp "$NC/oc_pass" "$NC/admin"
      : >"$NC/admin_group"
      echo 'The account "admin" was created successfully'
      ;;
    *" user:resetpassword --password-from-env admin")
      fake_password_from_env || return 1
      if [ ! -e "$NC/admin" ]; then
        echo 'User does not exist'
        return 1
      fi
      cp "$NC/oc_pass" "$NC/admin"
      echo 'Successfully reset password for admin'
      ;;
    *" group:adduser admin admin")
      : >"$NC/admin_group"
      ;;
    *" app:list --output=json")
      if [ -e "$NC/registration" ]; then
        printf '{"enabled":{"files":"2.0","registration":"2.5"},"disabled":{}}\n'
      else
        printf '{"enabled":{"files":"2.0","password_policy":"3.0"},"disabled":{"admin_audit":"1.0"}}\n'
      fi
      ;;
    *" config:system:set "* | *" background:cron")
      [ ! -e "$NC/config_fail" ] || return 1
      ;;
  esac
  return 0
}

# fake_status: what status.php answers.
fake_status() {
  local installed=false maintenance=false
  [ ! -e "$NC/installed" ] || installed=true
  [ ! -e "$NC/maintenance" ] || maintenance=true
  printf '{"installed":%s,"maintenance":%s,"needsDbUpgrade":false,"version":"34.0.6.1","versionstring":"34.0.6","edition":"","productname":"Nextcloud","extendedSupport":false}\n' \
    "$installed" "$maintenance"
}

# A curl that records every argv entry on its own line. The loopback status.php fails as many times
# as the number in NC/web_down (then answers fake_status).
stub_curl() {
  curl() {
    local n
    printf '%s\n' "$@" >>"$CURL_ARGV"
    if [[ "$*" == *"http://127.0.0.1:8080/status.php" ]]; then
      n="$(cat "$NC/web_down" 2>/dev/null || echo 0)"
      if [ "$n" -gt 0 ]; then
        echo $((n - 1)) >"$NC/web_down"
        return 7
      fi
      fake_status
    fi
    return 0
  }
}

# installed_with_admin: a Nextcloud that is installed and has its admin account.
installed_with_admin() {
  : >"$NC/installed"
  printf '%s' 'Secret1234X' >"$NC/admin"
  : >"$NC/admin_group"
}

# line_of <fixed text>: the number of the first docker.log line holding the text, 0 when none.
line_of() {
  local n
  n="$(grep -nF -- "$1" "$DLOG" | head -n 1 | cut -d: -f1)"
  echo "${n:-0}"
}

# occ_calls <text>: how many occ calls in docker.log hold the text.
occ_calls() {
  grep -F ' exec ' "$DLOG" | grep -cF -- "$1" || true
}

# The real docker, when the machine has one (the stub is first on PATH): merged config checks.
real_docker() {
  local d
  while IFS= read -r d; do
    [ "$d" = "$BATS_TEST_DIRNAME/stubs" ] && continue
    [ -x "$d/docker" ] && { echo "$d/docker"; return 0; }
  done < <(tr ':' '\n' <<<"$PATH")
  return 1
}

# Docker Desktop reached from WSL is a Windows binary and wants Windows paths; elsewhere a no-op.
native_path() {
  if command -v wslpath >/dev/null; then wslpath -w "$1"; else echo "$1"; fi
}

merged_config() {
  local docker f
  local -a args=()
  docker="$(real_docker)" || skip "no real docker on this machine"
  for f in "$@"; do args+=(-f "$(native_path "$APP_DIR/$f")"); done
  "$docker" compose "${args[@]}" --env-file "$(native_path "$DATA/.env")" config --format json
}

# --- app_prepare and the .env ---------------------------------------------------------------------

@test "secrets are generated once and a second run keeps them byte-identical" {
  app_prepare
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  grep -Eq '^POSTGRES_PASSWORD=[0-9a-f]{48}$' "$DATA/.env"
  grep -Eq '^VALKEY_PASSWORD=[0-9a-f]{64}$' "$DATA/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  app_prepare
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
}

@test "the .env carries a digest and a ref for nextcloud, postgres and valkey" {
  app_prepare
  grep -Eq '^NEXTCLOUD_IMAGE=nextcloud@sha256:[0-9a-f]{64}$' "$DATA/.env"
  grep -Eq '^POSTGRES_IMAGE=postgres@sha256:[0-9a-f]{64}$' "$DATA/.env"
  grep -Eq '^VALKEY_IMAGE=valkey/valkey@sha256:[0-9a-f]{64}$' "$DATA/.env"
  grep -qxF 'NEXTCLOUD_IMAGE_REF=nextcloud:34-apache' "$DATA/.env"
  grep -qxF 'POSTGRES_IMAGE_REF=postgres:16-alpine' "$DATA/.env"
  grep -qxF 'VALKEY_IMAGE_REF=valkey/valkey:8-alpine' "$DATA/.env"
}

@test "Nextcloud comes from its major-version Apache tag, pinned by digest, never a moving channel tag" {
  app_prepare
  grep -qxF 'buildx imagetools inspect nextcloud:34-apache --format {{json .Manifest}}' "$DLOG"
  want="$(printf '%s' nextcloud:34-apache | sha256sum | cut -d' ' -f1)"
  grep -qxF "NEXTCLOUD_IMAGE=nextcloud@sha256:$want" "$DATA/.env"
  [ "$VA_NEXTCLOUD_IMAGE_REF" = nextcloud:34-apache ]
  grep -qF 'image: ${NEXTCLOUD_IMAGE:-nextcloud:34-apache}' "$APP_DIR/compose.yml"
  # latest, apache, stable and production all move to a new major version one day.
  refute_grep -qE 'nextcloud:(latest|apache|stable|production)' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl" "$APP_DIR/app.sh"
}

@test "the site addresses are the host and the valid extra domains, invalid ones dropped" {
  mkdir -p "$(p /etc/vps-apps)"
  printf 'www.example.org\nnot a domain\n$(id).example.net\nnc.example.com\n' >"$(p /etc/vps-apps/domains)"
  app_prepare
  grep -qxF 'VA_SITE_ADDRS="nc.example.com www.example.org"' "$DATA/.env"
}

@test "an image that cannot be resolved fails app_prepare and leaves no .env" {
  : >"$STUB_TMP/inspect_fail"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
}

@test "the template substitution is literal for a value with an ampersand and a backslash" {
  resolve_image_digest() { printf '%s\n' 'x/y&z\w@sha256:abc'; }
  app_prepare
  grep -qxF 'NEXTCLOUD_IMAGE=x/y&z\w@sha256:abc' "$DATA/.env"
  grep -qxF 'VALKEY_IMAGE=x/y&z\w@sha256:abc' "$DATA/.env"
}

@test "the compose files are base and setup, then base and expose once the marker exists" {
  app_prepare
  run app_compose_files
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$APP_DIR/compose.yml" ]
  [ "${lines[1]}" = "$APP_DIR/compose.setup.yml" ]
  : >"$DATA/exposed"
  run app_compose_files
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "$APP_DIR/compose.expose.yml" ]
}

@test "app_up_setup starts the stack with the setup file" {
  app_prepare
  app_up_setup
  grep -qF "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.setup.yml --env-file $DATA/.env up -d" "$DLOG"
}

# --- the compose files ------------------------------------------------------------------------------

@test "before exposure only Nextcloud is published, on the loopback port 8080, with no caddy label" {
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services | keys | join(",")' <<<"$cfg")" = "cron,nextcloud,postgres,valkey" ]
  [ "$(jq -r '.services.nextcloud.ports | length' <<<"$cfg")" = 1 ]
  [ "$(jq -r '.services.nextcloud.ports[0] | "\(.host_ip):\(.published):\(.target)"' <<<"$cfg")" = "127.0.0.1:8080:80" ]
  [ "$(jq -r '.services.nextcloud.labels // {} | length' <<<"$cfg")" = 0 ]
  for s in postgres valkey cron; do
    [ "$(jq -r --arg s "$s" '.services[$s].ports // [] | length' <<<"$cfg")" = 0 ]
  done
  refute_grep -q caddy "$APP_DIR/compose.setup.yml"
  # No other file publishes anything.
  refute_grep -qE '^[[:space:]]*ports:' "$APP_DIR/compose.yml" "$APP_DIR/compose.expose.yml"
}

@test "after exposure nothing is published; Nextcloud joins web with the caddy labels, the rest stays internal" {
  app_prepare
  cfg="$(merged_config compose.yml compose.expose.yml)"
  for s in nextcloud postgres valkey cron; do
    [ "$(jq -r --arg s "$s" '.services[$s].ports // [] | length' <<<"$cfg")" = 0 ]
  done
  [ "$(jq -r '.services.nextcloud.networks | keys | join(",")' <<<"$cfg")" = "default,web" ]
  for s in postgres valkey cron; do
    [ "$(jq -r --arg s "$s" '.services[$s].networks | keys | join(",")' <<<"$cfg")" = default ]
  done
  [ "$(jq -r '.services.nextcloud.labels.caddy' <<<"$cfg")" = nc.example.com ]
  [ "$(jq -r '.services.nextcloud.labels["caddy.reverse_proxy"]' <<<"$cfg")" = "{{upstreams 80}}" ]
  # The CalDAV and CardDAV discovery redirects the proxy owns, and HSTS for the admin checks.
  [ "$(jq -r '.services.nextcloud.labels["caddy.redir_0"]' <<<"$cfg")" = "/.well-known/carddav /remote.php/dav/ 301" ]
  [ "$(jq -r '.services.nextcloud.labels["caddy.redir_1"]' <<<"$cfg")" = "/.well-known/caldav /remote.php/dav/ 301" ]
  [ "$(jq -r '.services.nextcloud.labels["caddy.header"]' <<<"$cfg")" = "Strict-Transport-Security max-age=15552000" ]
}

@test "the expose label is exactly the hostnames, with no scheme or port" {
  grep -qF 'caddy: ${VA_SITE_ADDRS:?VA_SITE_ADDRS is not set}' "$APP_DIR/compose.expose.yml"
  refute_grep -qE 'caddy: .*(https?://|:443)' "$APP_DIR/compose.expose.yml"
}

@test "Nextcloud and cron run the same image on the same volume and share the Valkey settings" {
  app_prepare
  cfg="$(merged_config compose.yml compose.expose.yml)"
  vpw="$(sed -n 's/^VALKEY_PASSWORD=//p' "$DATA/.env")"
  img="$(sed -n 's/^NEXTCLOUD_IMAGE=//p' "$DATA/.env")"
  [ "$(jq -r '.services.cron.entrypoint | join(" ")' <<<"$cfg")" = /cron.sh ]
  for s in nextcloud cron; do
    [ "$(jq -r --arg s "$s" '.services[$s].image' <<<"$cfg")" = "$img" ]
    [ "$(jq -r --arg s "$s" '.services[$s].volumes[] | select(.target == "/var/www/html") | .source' <<<"$cfg")" = nextcloud_data ]
    [ "$(jq -r --arg s "$s" '.services[$s].environment.REDIS_HOST' <<<"$cfg")" = valkey ]
    [ "$(jq -r --arg s "$s" '.services[$s].environment.REDIS_HOST_PASSWORD' <<<"$cfg")" = "$vpw" ]
  done
  # Apache's own X-Real-IP rewrite is off, so only Nextcloud's trusted_proxies decides the client IP.
  [ "$(jq -r '.services.nextcloud.environment.APACHE_DISABLE_REWRITE_IP' <<<"$cfg")" = 1 ]
  [ "$(jq -r '.services.valkey.environment.VALKEY_PASSWORD' <<<"$cfg")" = "$vpw" ]
}

@test "the Nextcloud containers get no install or database variable: no auto-install, no prefilled installer" {
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services.nextcloud.environment | keys | join(",")' <<<"$cfg")" = "APACHE_DISABLE_REWRITE_IP,REDIS_HOST,REDIS_HOST_PASSWORD" ]
  [ "$(jq -r '.services.cron.environment | keys | join(",")' <<<"$cfg")" = "REDIS_HOST,REDIS_HOST_PASSWORD" ]
  refute_grep -qE 'NEXTCLOUD_ADMIN|SQLITE_DATABASE|MYSQL_' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl" "$APP_DIR/app.sh"
}

@test "no compose file carries a password but the database and Valkey ones from the .env" {
  run grep -hiE 'password|pass' "$APP_DIR"/compose.yml "$APP_DIR"/compose.setup.yml "$APP_DIR"/compose.expose.yml
  [ -n "$output" ]
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *'${POSTGRES_PASSWORD:?'* || "$line" == *'${VALKEY_PASSWORD:?'* || "$line" == *'$${VALKEY_PASSWORD'* ]]
  done <<<"$output"
}

@test "without VALKEY_PASSWORD or POSTGRES_PASSWORD in the .env, compose refuses the stack" {
  app_prepare
  for key in VALKEY_PASSWORD POSTGRES_PASSWORD; do
    cp "$DATA/.env" "$BATS_TEST_TMPDIR/env.keep"
    sed -i "/^$key=/d" "$DATA/.env"
    run merged_config compose.yml compose.expose.yml
    [ "$status" -ne 0 ]
    [[ "$output" == *"$key"* ]]
    cp "$BATS_TEST_TMPDIR/env.keep" "$DATA/.env"
  done
}

# valkey_cmd <cfg> <jq path>: a command string from the merged config as the container's shell gets
# it (compose turns $$ into $).
valkey_cmd() {
  jq -r "$2 | gsub(\"\\\\$\\\\$\"; \"\$\")" <<<"$1"
}

@test "Valkey gets requirepass on stdin through its own entrypoint, never as an argument" {
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services.valkey.command[0:2] | join(" ")' <<<"$cfg")" = "sh -c" ]
  script="$(valkey_cmd "$cfg" '.services.valkey.command[2]')"$'\n'
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >"$STUB_TMP/valkey_argv"\ncat >"$STUB_TMP/valkey_stdin"\n' >"$bin/docker-entrypoint.sh"
  chmod +x "$bin/docker-entrypoint.sh"
  VALKEY_PASSWORD=s3cr3t PATH="$bin:$PATH" sh -c "$script"
  [ "$(cat "$STUB_TMP/valkey_argv")" = "valkey-server -" ]
  [ "$(cat "$STUB_TMP/valkey_stdin")" = "requirepass s3cr3t" ]
  hc="$(valkey_cmd "$cfg" '.services.valkey.healthcheck.test[1]')"
  printf '#!/bin/sh\nif [ "$REDISCLI_AUTH" = s3cr3t ] && [ "$*" = ping ]; then echo PONG; else echo NOAUTH; fi\n' >"$bin/valkey-cli"
  chmod +x "$bin/valkey-cli"
  VALKEY_PASSWORD=s3cr3t PATH="$bin:$PATH" sh -c "$hc"
  run env VALKEY_PASSWORD=wrong PATH="$bin:$PATH" sh -c "$hc"
  [ "$status" -ne 0 ]
}

# --- app_create_admin -------------------------------------------------------------------------------

@test "the order: setup stack, Nextcloud installed without an admin, the admin created, then exposed" {
  app_prepare
  app_up_setup
  app_create_admin "$PWF"
  app_expose
  setup_up="$(line_of "compose.setup.yml --env-file $DATA/.env up -d")"
  install="$(line_of 'maintenance:install')"
  add="$(line_of 'user:add --password-from-env --group admin admin')"
  expose_up="$(line_of "compose.expose.yml --env-file $DATA/.env up -d")"
  [ "$setup_up" -gt 0 ] && [ "$setup_up" -lt "$install" ] && [ "$install" -lt "$add" ] && [ "$add" -lt "$expose_up" ]
  # Nothing ran with the expose file before the admin existed.
  [ "$(grep -nF compose.expose.yml "$DLOG" | head -n 1 | cut -d: -f1)" -eq "$expose_up" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
}

@test "maintenance:install makes no admin and gets the database password from the exec environment" {
  app_prepare
  app_create_admin "$PWF"
  pg="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$DATA/.env")"
  line="$(grep -F 'maintenance:install' "$DLOG")"
  [[ "$line" == *" exec -T -u www-data -e POSTGRES_PASSWORD nextcloud sh -c "* ]]
  [[ "$line" == *"--database pgsql --database-host postgres --database-name nextcloud --database-user nextcloud"* ]]
  [[ "$line" == *'--database-pass "$POSTGRES_PASSWORD"'* ]]
  [[ "$line" == *"--disable-admin-user"* ]]
  [[ "$line" != *"--admin-pass"* ]]
  # The value went through the environment only.
  [ "$(cat "$NC/install_db_pass")" = "$pg" ]
  refute_grep -qF "$pg" "$DLOG"
}

@test "the admin is created with the exact password bytes, through OC_PASS in the exec environment" {
  app_prepare
  PW=$'Ab1$"\x60\x27\\ x;Z9'
  printf '%s' "$PW" >"$PWF"
  app_create_admin "$PWF"
  cmp "$NC/oc_pass" "$PWF"
  cmp "$NC/admin" "$PWF"
  grep -qE " exec -T -u www-data -e OC_PASS nextcloud php occ --no-interaction user:add --password-from-env --group admin admin$" "$DLOG"
  # Never on a command line, in the .env, or in the shell's own environment afterwards.
  refute_grep -qF "$PW" "$DLOG" "$CURL_ARGV" "$DATA/.env"
  refute_grep -qF 'Ab1$' "$DLOG"
  [ -z "${OC_PASS+x}" ]
  [ ! -e "$CRED" ]
}

@test "the admin login is admin, in the admin group, and every occ call runs as www-data without a prompt" {
  app_prepare
  app_create_admin "$PWF"
  [ -e "$NC/admin_group" ]
  while IFS= read -r line; do
    [[ "$line" == *" exec -T -u www-data "* ]]
    [[ "$line" == *" sh -c "* || "$line" == *" php occ --no-interaction "* ]]
  done < <(grep -F ' exec ' "$DLOG")
}

@test "a retry after Nextcloud was installed does not install again" {
  app_prepare
  : >"$NC/installed"
  app_create_admin "$PWF"
  [ "$(occ_calls maintenance:install)" -eq 0 ]
  [ "$(occ_calls 'user:add')" -eq 1 ]
}

@test "a failed maintenance:install fails the step before any admin or setting is made" {
  app_prepare
  : >"$NC/install_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  [ "$(occ_calls 'user:')" -eq 0 ]
  [ "$(occ_calls 'config:system:set')" -eq 0 ]
  # The install output is not logged as a whole (its traces may hold connection arguments).
  refute_grep -qF 'Trace' "$(p /var/log/vps-apps-install.log)"
}

@test "app_create_admin waits for Nextcloud on the loopback port, bounded, and fails when it never answers" {
  app_prepare
  echo 999 >"$NC/web_down"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  grep -qxF 'http://127.0.0.1:8080/status.php' "$CURL_ARGV"
  grep -qxF -- '--max-time' "$CURL_ARGV"
  refute_grep -qF ' exec ' "$DLOG"
}

@test "Nextcloud still starting (no answer twice) is waited out before occ runs" {
  app_prepare
  echo 2 >"$NC/web_down"
  app_create_admin "$PWF"
  [ "$(grep -cxF 'http://127.0.0.1:8080/status.php' "$CURL_ARGV")" -ge 3 ]
  [ -e "$NC/admin" ]
}

@test "the occ settings: trusted domains, the proxy network, HTTPS, the CLI URL, the maintenance window, cron" {
  mkdir -p "$(p /etc/vps-apps)"
  printf 'www.example.org\n' >"$(p /etc/vps-apps/domains)"
  app_prepare
  app_create_admin "$PWF"
  occ='php occ --no-interaction'
  grep -qxF "network inspect web --format {{range .IPAM.Config}}{{println .Subnet}}{{end}}" "$DLOG"
  grep -qF "$occ config:system:set trusted_domains --type=json --value=[\"nc.example.com\",\"www.example.org\"]" "$DLOG"
  grep -qF "$occ config:system:set trusted_proxies --type=json --value=[\"172.18.0.0/16\"]" "$DLOG"
  grep -qF "$occ config:system:set overwriteprotocol --value=https" "$DLOG"
  grep -qF "$occ config:system:set overwrite.cli.url --value=https://nc.example.com" "$DLOG"
  grep -qF "$occ config:system:set maintenance_window_start --type=integer --value=1" "$DLOG"
  grep -qE "$occ background:cron$" "$DLOG"
  # overwritehost stays unset, so every trusted domain keeps its own name in links.
  refute_grep -qF overwritehost "$DLOG"
}

@test "every subnet of the web network is a trusted proxy, IPv6 included" {
  app_prepare
  WEB_SUBNETS=$'172.18.0.0/16\nfd00:dead:beef::/64' app_create_admin "$PWF"
  grep -qF 'config:system:set trusted_proxies --type=json --value=["172.18.0.0/16","fd00:dead:beef::/64"]' "$DLOG"
}

@test "a web network subnet that cannot be read fails the step before the admin is made" {
  app_prepare
  : >"$NC/no_subnet"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  rm -f "$NC/no_subnet"
  WEB_SUBNETS='not-a-subnet' run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  WEB_SUBNETS='' run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  [ "$(occ_calls 'user:add')" -eq 0 ]
  [ "$(occ_calls 'trusted_proxies')" -eq 0 ]
}

@test "a failed occ setting fails the step before the admin is made" {
  app_prepare
  : >"$NC/config_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  [ "$(occ_calls 'user:add')" -eq 0 ]
}

@test "a password shorter than Nextcloud's minimum takes a generated one, kept in the credentials file" {
  app_prepare
  for short in Secret12 Secret123; do
    rm -f "$CRED" "$NC/admin" "$NC/admin_group"
    : >"$DLOG"
    printf '%s' "$short" >"$PWF"
    app_create_admin "$PWF"
    [ "$(stat -c %a "$CRED")" = 600 ]
    sent="$(cat "$NC/oc_pass")"
    [ "$sent" != "$short" ]
    [[ "${#sent}" -ge 10 && "$sent" =~ [A-Z] && "$sent" =~ [a-z] && "$sent" =~ [0-9] ]]
    grep -qxF "Password: $sent" "$CRED"
    grep -qxF 'Login: admin' "$CRED"
    # The short password is never sent: Nextcloud's verdict is known.
    [ "$(occ_calls 'user:add')" -eq 1 ]
  done
}

@test "a policy message in terminal colours is still read as the policy's verdict" {
  app_prepare
  : >"$NC/ansi"
  # Past the length check here, so the verdict is Nextcloud's own.
  VA_NC_MIN_PASSWORD=8
  printf '%s' Secret12 >"$PWF"
  app_create_admin "$PWF"
  [ "$(occ_calls 'user:add')" -eq 2 ]
  [ -f "$CRED" ]
}

@test "a PHP notice before occ's JSON answer does not hide the answer" {
  app_prepare
  : >"$NC/noise"
  app_create_admin "$PWF"
  [ "$(occ_calls 'user:add')" -eq 1 ]
  app_expose
  [ -f "$DATA/exposed" ]
}

@test "a password Nextcloud's policy refuses takes a generated one, and the call is made again" {
  app_prepare
  printf 'Password123\n' >"$NC/common"
  printf '%s' Password123 >"$PWF"
  app_create_admin "$PWF"
  [ "$(occ_calls 'user:add')" -eq 2 ]
  [ -f "$CRED" ]
  [ "$(cat "$NC/admin")" != Password123 ]
  grep -qxF "Password: $(cat "$NC/admin")" "$CRED"
}

@test "any other admin failure fails the step, with no generated password" {
  app_prepare
  : >"$NC/add_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  [ ! -e "$CRED" ]
  [ "$(occ_calls 'user:add')" -eq 1 ]
  grep -qF 'An error occurred while creating the account' "$(p /var/log/vps-apps-install.log)"
}

@test "a retry with the admin already there sets its password again instead of creating it" {
  app_prepare
  app_create_admin "$PWF"
  app_create_admin "$PWF"
  [ "$(occ_calls 'user:add')" -eq 1 ]
  [ "$(occ_calls 'user:resetpassword --password-from-env admin')" -eq 1 ]
  cmp "$NC/admin" "$PWF"
  [ ! -e "$CRED" ]
}

@test "an existing admin outside the admin group is put back in it" {
  app_prepare
  : >"$NC/installed"
  printf '%s' 'something' >"$NC/admin"
  app_create_admin "$PWF"
  [ "$(occ_calls 'group:adduser admin admin')" -eq 1 ]
  [ -e "$NC/admin_group" ]
  cmp "$NC/admin" "$PWF"
}

@test "a retry after a fallback keeps the credentials file and its password, even if the chosen one would pass now" {
  app_prepare
  printf 'Password123\n' >"$NC/common"
  printf '%s' Password123 >"$PWF"
  app_create_admin "$PWF"
  cp "$CRED" "$BATS_TEST_TMPDIR/cred1"
  first="$(cat "$NC/admin")"
  rm -f "$NC/common"
  app_create_admin "$PWF"
  cmp "$CRED" "$BATS_TEST_TMPDIR/cred1"
  [ "$(cat "$NC/admin")" = "$first" ]
}

@test "a non-ASCII or non-printable password takes the generated fallback" {
  app_prepare
  for bad in 'Pässword1xyz' $'Tab\tPass1word' $'Pass\nword1Xyz' 'Пароль1Abcdef'; do
    rm -f "$CRED" "$NC/admin" "$NC/admin_group"
    printf '%s' "$bad" >"$PWF"
    app_create_admin "$PWF"
    [ "$(cat "$NC/admin")" != "$bad" ]
    [ -f "$CRED" ]
  done
}

@test "passwords that meet the policy are sent as they are, at 10 and 64 characters" {
  app_prepare
  for good in Abcdefgh12 'Ab1$"`x\ y' "A1$(printf 'x%.0s' $(seq 62))"; do
    rm -f "$NC/admin" "$NC/admin_group"
    printf '%s' "$good" >"$PWF"
    app_create_admin "$PWF"
    cmp "$NC/admin" "$PWF"
    [ ! -e "$CRED" ]
  done
  [ "${#good}" -eq 64 ]
}

@test "the MOTD points at the credentials file only when it exists and never prints its content" {
  motd="$ROOT_DIR/base/files/99-vps-apps-motd"
  mkdir -p "$(p /root)"
  printf 'Login: admin\nPassword: TopSecret1234\n' >"$CRED"
  run "$motd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/root/vps-apps-credentials.txt"* ]]
  refute_grep -qF 'TopSecret' <<<"$output"
}

# --- app_expose -------------------------------------------------------------------------------------

@test "app_expose writes the marker, puts the site in app mode and starts the expose file" {
  app_prepare
  installed_with_admin
  app_expose
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
  grep -qF "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.expose.yml --env-file $DATA/.env up -d" "$DLOG"
}

# refused: app_expose failed and changed nothing.
refused() {
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ ! -e "$(p /var/lib/vps-apps/site-mode)" ]
  refute_grep -q compose.expose.yml "$DLOG"
}

@test "app_expose refuses while Nextcloud is not installed: its installer is never put on the internet" {
  app_prepare
  run app_expose
  refused
}

@test "app_expose refuses while the admin is missing or not an admin" {
  app_prepare
  : >"$NC/installed"
  run app_expose
  refused
  printf x >"$NC/admin"
  run app_expose
  refused
}

@test "app_expose refuses while the registration app (open signup) is enabled" {
  app_prepare
  installed_with_admin
  : >"$NC/registration"
  run app_expose
  refused
}

@test "app_expose refuses in maintenance mode, and when Nextcloud never answers" {
  app_prepare
  installed_with_admin
  : >"$NC/maintenance"
  run app_expose
  refused
  rm -f "$NC/maintenance"
  echo 999 >"$NC/web_down"
  run app_expose
  refused
}

@test "app_expose fails closed when the user or app list cannot be read" {
  app_prepare
  installed_with_admin
  fake_occ() { [[ "$*" != *"user:info"* ]] || { echo 'not json'; return 0; }; }
  run app_expose
  refused
  fake_occ() { [[ "$*" != *"app:list"* ]] || return 1; [[ "$*" != *"user:info"* ]] || printf '{"user_id":"admin","enabled":true,"groups":["admin"]}\n'; }
  run app_expose
  refused
}

@test "app_expose brings the setup stack up and waits for Nextcloud before it checks" {
  app_prepare
  installed_with_admin
  : >"$DATA/exposed"
  app_expose
  setup_line="$(line_of "compose.setup.yml --env-file $DATA/.env up -d")"
  expose_line="$(line_of "compose.expose.yml --env-file $DATA/.env up -d")"
  check_line="$(line_of 'user:info admin')"
  [ "$setup_line" -gt 0 ] && [ "$setup_line" -lt "$check_line" ] && [ "$check_line" -lt "$expose_line" ]
  grep -qxF 'http://127.0.0.1:8080/status.php' "$CURL_ARGV"
}

@test "a failed start in app_expose takes the stack down, drops the marker and shows the failed page" {
  app_prepare
  installed_with_admin
  COMPOSE_FAIL_MATCH='compose.expose.yml --env-file*up -d' run app_expose
  [ "$status" -ne 0 ]
  grep -qE 'compose.expose.yml .* down$' "$DLOG"
  [ ! -e "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
  # A retry recovers.
  run app_expose
  [ "$status" -eq 0 ]
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
}

# --- app_ready_check --------------------------------------------------------------------------------

@test "app_ready_check needs Nextcloud installed and running over HTTPS on the server's own name" {
  curl() { printf '%s\n' "$*" >"$BATS_TEST_TMPDIR/curl_args"; printf '{"installed":true,"maintenance":false,"needsDbUpgrade":false}'; }
  app_ready_check
  # Exactly these arguments: through the proxy on the real name, and no flag that skips the
  # certificate check.
  [ "$(cat "$BATS_TEST_TMPDIR/curl_args")" = "-fsS --max-time 10 --resolve nc.example.com:443:127.0.0.1 https://nc.example.com/status.php" ]
  for body in '{"installed":false,"maintenance":false,"needsDbUpgrade":false}' \
    '{"installed":true,"maintenance":true,"needsDbUpgrade":false}' \
    '{"installed":true,"maintenance":false,"needsDbUpgrade":true}' 'Your Docker server is ready' ''; do
    curl() { printf '%s' "$READY_BODY"; }
    READY_BODY="$body" run app_ready_check
    [ "$status" -ne 0 ]
  done
  curl() { printf '{"installed":true,"maintenance":false,"needsDbUpgrade":false}'; return 60; }
  run app_ready_check
  [ "$status" -ne 0 ]
}

# --- app_domain_added -------------------------------------------------------------------------------

@test "app_domain_added trusts and serves every name and moves the CLI URL to the new domain" {
  app_prepare
  installed_with_admin
  : >"$DATA/exposed"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  mkdir -p "$(p /etc/vps-apps)"
  printf 'www.example.org\n' >"$(p /etc/vps-apps/domains)"
  : >"$DLOG"
  app_domain_added www.example.org
  grep -qxF 'VA_SITE_ADDRS="nc.example.com www.example.org"' "$DATA/.env"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  diff <(grep -v '^VA_SITE_ADDRS=' "$BATS_TEST_TMPDIR/before") <(grep -v '^VA_SITE_ADDRS=' "$DATA/.env")
  grep -qF 'config:system:set trusted_domains --type=json --value=["nc.example.com","www.example.org"]' "$DLOG"
  grep -qF 'config:system:set overwrite.cli.url --value=https://www.example.org' "$DLOG"
  # Nextcloud trusts the name before the proxy routes it there.
  [ "$(line_of 'trusted_domains')" -lt "$(line_of "compose.expose.yml --env-file $DATA/.env up -d")" ]
}

@test "each domain added later takes the CLI URL over; the server's own name stays served" {
  app_prepare
  installed_with_admin
  mkdir -p "$(p /etc/vps-apps)"
  printf 'one.example.org\ntwo.example.org\n' >"$(p /etc/vps-apps/domains)"
  app_domain_added two.example.org
  grep -qxF 'VA_SITE_ADDRS="nc.example.com one.example.org two.example.org"' "$DATA/.env"
  [ "$(grep -F 'overwrite.cli.url' "$DLOG" | tail -n 1 | sed 's/.*--value=//')" = https://two.example.org ]
  app_domain_added one.example.org
  [ "$(grep -F 'overwrite.cli.url' "$DLOG" | tail -n 1 | sed 's/.*--value=//')" = https://one.example.org ]
}

@test "an invalid domain given to app_domain_added leaves the CLI URL on the host" {
  app_prepare
  installed_with_admin
  app_domain_added 'bad domain;id'
  [ "$(grep -F 'overwrite.cli.url' "$DLOG" | tail -n 1 | sed 's/.*--value=//')" = https://nc.example.com ]
}

@test "a failed occ setting in app_domain_added leaves the .env and the running stack as they are" {
  app_prepare
  installed_with_admin
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  mkdir -p "$(p /etc/vps-apps)"
  printf 'www.example.org\n' >"$(p /etc/vps-apps/domains)"
  : >"$NC/config_fail"
  : >"$DLOG"
  run app_domain_added www.example.org
  [ "$status" -ne 0 ]
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  refute_grep -q ' up -d' "$DLOG"
}

@test "Nextcloud defines no app_domain_check, so rc domain add accepts extra domains" {
  run declare -F app_domain_check
  [ "$status" -ne 0 ]
}

# --- rc update --------------------------------------------------------------------------------------

@test "rc update re-resolves Nextcloud from its major tag only, so it never leaves the installed major" {
  app_prepare
  run declare -F app_update_env
  [ "$status" -ne 0 ]
  sed -i "s#^NEXTCLOUD_IMAGE=.*#NEXTCLOUD_IMAGE=nextcloud@sha256:$(printf '1%.0s' $(seq 64))#" "$DATA/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  resolve_env_images "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  want="$(printf '%s' nextcloud:34-apache | sha256sum | cut -d' ' -f1)"
  grep -qxF "NEXTCLOUD_IMAGE=nextcloud@sha256:$want" "$BATS_TEST_TMPDIR/out"
  grep -qxF 'NEXTCLOUD_IMAGE_REF=nextcloud:34-apache' "$BATS_TEST_TMPDIR/out"
  diff <(grep -v '_IMAGE=' "$BATS_TEST_TMPDIR/before") <(grep -v '_IMAGE=' "$BATS_TEST_TMPDIR/out")
}
