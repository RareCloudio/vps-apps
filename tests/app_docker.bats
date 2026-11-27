#!/usr/bin/env bats
load test_helper

setup() {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PWF="$BATS_TEST_TMPDIR/password"
  echo 'Secret123' >"$PWF"
  mkdir -p "$VPS_APPS_ROOT/etc"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$VPS_APPS_ROOT/etc/os-release"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  STATUS_FILE="$VPS_APPS_ROOT/var/lib/vps-apps/public/.well-known/rarecloud-app-status"
  DRIVER="$BATS_TEST_TMPDIR/driver.sh"
  # The driver sources install.sh, replaces load_code with stubs that log their name, and runs main.
  # EXTRA is extra shell code that runs after the stubs (to make one of them fail, for example).
  cat >"$DRIVER" <<DRV
set -euo pipefail
. "$ROOT_DIR/install.sh"
load_code() {
  local f
  for f in packages swap sysctl docker firewall proxy ssh motd; do
    eval "base_\$f() { echo \$f >>\"$CALLS\"; }"
  done
  app_prepare() { echo app_prepare >>"$CALLS"; }
  app_up_setup() { echo app_up_setup >>"$CALLS"; }
  app_create_admin() { echo app_create_admin >>"$CALLS"; [ "\$1" = "$PWF" ]; }
  app_expose() { echo app_expose >>"$CALLS"; printf app >"\$VPS_APPS_ROOT/var/lib/vps-apps/site-mode"; }
  app_ready_check() {
    echo "ready_check status=\$(cat "$STATUS_FILE")" >>"$CALLS"
    [ ! -e "$BATS_TEST_TMPDIR/check_fail" ]
  }
  eval "\${EXTRA:-:}"
}
main --app docker --host a.example.com --ip 1.2.3.4 --password-file "$PWF"
DRV
}

run_driver() {
  run env VA_READY_TIMEOUT=2 VA_READY_INTERVAL=1 "$@" bash "$DRIVER"
}

@test "install.sh --app docker runs every step in order" {
  run_driver
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' <"$CALLS")" = "packages swap sysctl docker firewall proxy ssh motd app_prepare app_up_setup app_create_admin app_expose ready_check status=installing " ]
  [ "$(cat "$STATUS_FILE")" = ready ]
}

@test "the status is ready only after the readiness check passes" {
  run_driver
  [ "$status" -eq 0 ]
  grep -qxF 'ready_check status=installing' "$CALLS"
  [ "$(cat "$STATUS_FILE")" = ready ]
}

@test "a readiness check that never passes ends as failed:ready-check" {
  : >"$BATS_TEST_TMPDIR/check_fail"
  run_driver
  [ "$status" -eq 1 ]
  [ "$(cat "$STATUS_FILE")" = failed:ready-check ]
  [ "$(grep -c '^ready_check' "$CALLS")" -ge 2 ]
}

@test "a readiness check that passes on a later attempt still ends as ready" {
  run_driver EXTRA='app_ready_check() { echo ready_check >>"'"$CALLS"'"; [ "$(grep -c ^ready_check "'"$CALLS"'")" -ge 3 ]; }'
  [ "$status" -eq 0 ]
  [ "$(cat "$STATUS_FILE")" = ready ]
}

@test "ready is refused while the site mode is not app" {
  run_driver EXTRA='app_expose() { echo app_expose >>"'"$CALLS"'"; printf installing >"$VPS_APPS_ROOT/var/lib/vps-apps/site-mode"; }'
  [ "$status" -eq 1 ]
  [ "$(cat "$STATUS_FILE")" = failed:ready-check ]
}

@test "a failing step stops the install and names the step" {
  run_driver EXTRA='base_firewall() { echo firewall >>"'"$CALLS"'"; return 1; }'
  [ "$status" -eq 1 ]
  [ "$(cat "$STATUS_FILE")" = failed:firewall ]
  refute_grep -qx 'proxy' "$CALLS"
  refute_grep -qx 'app_expose' "$CALLS"
}

@test "a failing app_create_admin is reported under its own step name" {
  run_driver EXTRA='app_create_admin() { return 1; }'
  [ "$status" -eq 1 ]
  [ "$(cat "$STATUS_FILE")" = failed:app_create_admin ]
}

@test "install.sh exports VA_HOST and VA_IP before the steps run" {
  run_driver EXTRA='base_proxy() { echo "proxy $VA_HOST $VA_IP" >>"'"$CALLS"'"; }'
  [ "$status" -eq 0 ]
  grep -qxF 'proxy a.example.com 1.2.3.4' "$CALLS"
}

# --- the real docker app hooks ---

load_app() {
  # shellcheck source=../lib/common.sh
  . "$ROOT_DIR/lib/common.sh"
  # shellcheck source=../lib/images.sh
  . "$ROOT_DIR/lib/images.sh"
  # shellcheck source=../base/60-proxy.sh
  . "$ROOT_DIR/base/60-proxy.sh"
  # shellcheck source=../apps/docker/app.sh
  . "$ROOT_DIR/apps/docker/app.sh"
  VA_HOST=a.example.com
  export VA_HOST
  DATA="$(p /opt/vps-apps-data/docker)"
}

@test "the landing page carries the promised copy" {
  page="$ROOT_DIR/apps/docker/www/index.html"
  grep -q '<title>Your Docker server is ready</title>' "$page"
  grep -qF 'caddy: app.example.com' "$page"
  grep -qF 'caddy.reverse_proxy: "{{upstreams 3000}}"' "$page"
  grep -qF -- '- web' "$page"
  grep -qF 'rc port open' "$page"
  grep -qF 'rc status' "$page"
  grep -qF 'rc logs' "$page"
  grep -qF 'rc domain add' "$page"
}

@test "app_prepare writes the page and an .env with a digest and its ref" {
  load_app
  app_prepare
  grep -q 'Your Docker server is ready' "$DATA/www/index.html"
  grep -Eq '^LANDING_IMAGE=caddy@sha256:[0-9a-f]{64}$' "$DATA/.env"
  grep -qxF 'LANDING_IMAGE_REF=caddy:2-alpine' "$DATA/.env"
  grep -qxF 'VA_SITE_ADDRS="a.example.com"' "$DATA/.env"
}

@test "app_compose_files names the expose file only once the marker exists" {
  load_app
  app_prepare
  run app_compose_files
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "$ROOT_DIR/apps/docker/compose.yml" ]
  : >"$DATA/exposed"
  run app_compose_files
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "$ROOT_DIR/apps/docker/compose.expose.yml" ]
}

@test "app_expose writes the marker, puts the site in app mode and starts both compose files" {
  load_app
  app_prepare
  app_expose
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
  # In app mode the base Caddyfile has no block for the host: the labels own it.
  refute_grep -q 'a.example.com' "$(p /etc/vps-apps/caddy/Caddyfile)"
  grep -q "compose -f $ROOT_DIR/apps/docker/compose.yml -f $ROOT_DIR/apps/docker/compose.expose.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
}

@test "a failed start in app_expose puts the failed page back and fails" {
  load_app
  app_prepare
  docker() { return 1; }
  run app_expose
  [ "$status" -ne 0 ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
}

@test "app_domain_added writes only valid, new domains into the label list" {
  load_app
  app_prepare
  mkdir -p "$(p /etc/vps-apps)"
  printf 'www.example.org\nbad domain\nevil.com, x.com\nA.Example.COM\nwww.example.org\n\nsecond.example.net\n' >"$(p /etc/vps-apps/domains)"
  app_domain_added second.example.net
  grep -qxF 'VA_SITE_ADDRS="a.example.com www.example.org second.example.net"' "$DATA/.env"
  grep -Eq '^LANDING_IMAGE=caddy@sha256:' "$DATA/.env"
  grep -qxF 'LANDING_IMAGE_REF=caddy:2-alpine' "$DATA/.env"
  grep -q 'up -d' "$STUB_TMP/docker.log"
}

@test "app_ready_check needs the landing page over HTTPS on the server own name" {
  load_app
  curl() { printf '%s\n' "$*" >"$BATS_TEST_TMPDIR/curl_args"; printf 'Your Docker server is ready'; }
  app_ready_check
  grep -qF -- '--resolve a.example.com:443:127.0.0.1 https://a.example.com/' "$BATS_TEST_TMPDIR/curl_args"
  curl() { printf 'something else'; }
  run app_ready_check
  [ "$status" -ne 0 ]
}

@test "app_up_setup and app_create_admin do nothing" {
  load_app
  app_up_setup
  app_create_admin "$BATS_TEST_TMPDIR/password"
  [ ! -e "$STUB_TMP/docker.log" ]
}
