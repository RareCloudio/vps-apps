#!/usr/bin/env bats
load test_helper

setup() {
  # shellcheck source=../lib/common.sh
  . "$BATS_TEST_DIRNAME/../lib/common.sh"
  # shellcheck source=../lib/steps.sh
  . "$BATS_TEST_DIRNAME/../lib/steps.sh"
  # shellcheck source=../lib/images.sh
  . "$BATS_TEST_DIRNAME/../lib/images.sh"
  # shellcheck source=../base/60-proxy.sh
  . "$BATS_TEST_DIRNAME/../base/60-proxy.sh"
  VA_HOST="app.example.com"
  VA_IP="203.0.113.7"
  COMPOSE="$BATS_TEST_DIRNAME/../base/proxy/compose.yml"
  CADDYFILE="$(p /etc/vps-apps/caddy/Caddyfile)"
}


@test "the base Caddyfile has the ACME email and the status block on :80" {
  set_site_mode http-only
  grep -qxF $'\temail abuse@rarecloud.io' "$CADDYFILE"
  grep -qxF ':80 {' "$CADDYFILE"
  grep -qF 'handle /.well-known/rarecloud-app-status' "$CADDYFILE"
  grep -qF 'root * /srv/public' "$CADDYFILE"
  grep -qF 'header Content-Type text/plain' "$CADDYFILE"
  refute_grep -qi 'redir' "$CADDYFILE"
}

@test "http-only has no HTTPS site for the host but serves the installing page on plain HTTP" {
  set_site_mode http-only
  refute_grep -qF 'https://' "$CADDYFILE"
  refute_grep -qxF "$VA_HOST {" "$CADDYFILE"
  grep -qxF "http://$VA_HOST {" "$CADDYFILE"
  grep -qF 'rewrite * /installing.html' "$CADDYFILE"
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = "http-only" ]
}

@test "installing and failed add the HTTPS site, app leaves it to the labels" {
  set_site_mode installing
  grep -qxF "$VA_HOST {" "$CADDYFILE"
  grep -qF 'rewrite * /installing.html' "$CADDYFILE"
  set_site_mode failed
  grep -qxF "$VA_HOST {" "$CADDYFILE"
  grep -qF 'rewrite * /failed.html' "$CADDYFILE"
  refute_grep -qF 'installing.html' "$CADDYFILE"
  set_site_mode app
  refute_grep -qF "$VA_HOST" "$CADDYFILE"
  grep -qxF ':80 {' "$CADDYFILE"
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = "app" ]
}

@test "an unknown mode is refused and leaves the Caddyfile alone" {
  set_site_mode installing
  cp "$CADDYFILE" "$BATS_TEST_TMPDIR/before"
  run set_site_mode bogus
  [ "$status" -ne 0 ]
  cmp "$CADDYFILE" "$BATS_TEST_TMPDIR/before"
}

@test "writing the Caddyfile leaves no temp file and never reloads caddy" {
  set_site_mode installing
  set_site_mode failed
  [ "$(find "$(p /etc/vps-apps/caddy)" -type f | wc -l)" -eq 1 ]
  [ ! -e "$STUB_TMP/docker.log" ]
}

@test "mounts are directories and no volume source is a single file" {
  grep -qF '/var/lib/vps-apps/public:/srv/public:ro' "$COMPOSE"
  grep -qF '/etc/vps-apps/caddy:/etc/caddy:ro' "$COMPOSE"
  local sources
  sources="$(sed -n 's/^ *- \(\/[^:]*\):.*/\1/p' "$COMPOSE" | sort | tr '\n' ' ')"
  [ "$sources" = "/etc/vps-apps/caddy /var/lib/vps-apps/public /var/run/docker.sock " ]
}

@test "the socket proxy is read-only and on the internal network only" {
  local block
  block="$(sed -n '/^  socket-proxy:/,/^  caddy:/p' "$COMPOSE")"
  grep -qF 'CONTAINERS: "1"' <<<"$block"
  grep -qF 'NETWORKS: "1"' <<<"$block"
  grep -qF 'POST: "0"' <<<"$block"
  grep -qF 'INFO: "1"' <<<"$block"
  grep -qF '/var/run/docker.sock:/var/run/docker.sock:ro' <<<"$block"
  grep -qx '      - socket' <<<"$block"
  refute_grep -qx '      - web' <<<"$block"
  sed -n '/^networks:/,$p' "$COMPOSE" | grep -qxF '    internal: true'
}

@test "caddy has no docker.sock mount and is configured for the web network" {
  local block
  block="$(sed -n '/^  caddy:/,/^volumes:/p' "$COMPOSE")"
  refute_grep -qF 'docker.sock' <<<"$block"
  grep -qF 'CADDY_INGRESS_NETWORKS: web' <<<"$block"
  refute_grep -qF '443/udp' "$COMPOSE"
  grep -qF 'CADDY_DOCKER_CADDYFILE_PATH: /etc/caddy/Caddyfile' <<<"$block"
  grep -qF 'CADDY_DOCKER_POLLING_INTERVAL: 5s' <<<"$block"
  grep -qF 'caddy_data:/data' <<<"$block"
  sed -n '/^networks:/,$p' "$COMPOSE" | grep -qxF '    external: true'
}

@test "the images are pinned by digest in the rendered .env" {
  printf '%s\n' "$VA_IP" >"$STUB_TMP/dig_answer"
  base_proxy
  local env
  env="$(p /opt/vps-apps-data/proxy/.env)"
  grep -qE '^CADDY_IMAGE=lucaslorentz/caddy-docker-proxy@sha256:[0-9a-f]{64}$' "$env"
  grep -qE '^SOCKET_PROXY_IMAGE=tecnativa/docker-socket-proxy@sha256:[0-9a-f]{64}$' "$env"
  grep -qxF "CADDY_IMAGE_REF=$VA_CADDY_IMAGE_REF" "$env"
  grep -qxF "SOCKET_PROXY_IMAGE_REF=$VA_SOCKET_PROXY_IMAGE_REF" "$env"
  [ -f "$(p /opt/vps-apps-data/proxy/compose.yml)" ]
  grep -qF "compose -f $(p /opt/vps-apps-data/proxy)/compose.yml --env-file $env up -d" "$STUB_TMP/docker.log"
}

@test "a digest that cannot be resolved fails" {
  docker() { echo '{"digest":"nonsense"}'; }
  run resolve_image_digest repo/x:1
  [ "$status" -ne 0 ]
}

@test "wait_for_name returns 0 once the public resolver answers with the IP" {
  printf '%s\n' "$VA_IP" >"$STUB_TMP/dig_answer"
  wait_for_name "$VA_HOST" "$VA_IP" 2
  grep -qxF "+short +time=2 +tries=1 @1.1.1.1 A $VA_HOST" "$STUB_TMP/dig.log"
}

@test "wait_for_name returns 1 after the budget when the name never resolves to the IP" {
  printf '%s\n' "198.51.100.9" >"$STUB_TMP/dig_answer"
  run wait_for_name "$VA_HOST" "$VA_IP" 2
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$STUB_TMP/dig.log")" -ge 2 ]
}

@test "the web network is created only when missing" {
  printf '%s\n' "$VA_IP" >"$STUB_TMP/dig_answer"
  base_proxy
  refute_grep -qxF "network create web" "$STUB_TMP/docker.log"
  : >"$STUB_TMP/no_web_network"
  base_proxy
  grep -qxF 'network create web' "$STUB_TMP/docker.log"
}

@test "the step order: http-only, then the DNS wait, then installing" {
  local order="$BATS_TEST_TMPDIR/order"
  : >"$order"
  set_site_mode() { echo "mode:$1" >>"$order"; }
  wait_for_name() { echo "wait:$1:$2:$3" >>"$order"; return 1; }
  base_proxy
  [ "$(cat "$order")" = "$(printf 'mode:http-only\nwait:%s:%s:300\nmode:installing' "$VA_HOST" "$VA_IP")" ]
}

@test "the landing pages are installed into the public directory" {
  printf '%s\n' "$VA_IP" >"$STUB_TMP/dig_answer"
  base_proxy
  cmp "$(p /var/lib/vps-apps/public/installing.html)" "$BATS_TEST_DIRNAME/../base/www/installing.html"
  cmp "$(p /var/lib/vps-apps/public/failed.html)" "$BATS_TEST_DIRNAME/../base/www/failed.html"
}

# status_block: the :80 block of the rendered Caddyfile.
status_block() {
  sed -n '/^:80 {$/,/^}$/p' "$CADDYFILE"
}

@test "the :80 block serves the status as text/plain in every mode" {
  local mode block
  for mode in http-only installing failed app; do
    set_site_mode "$mode"
    block="$(status_block)"
    grep -qF 'handle /.well-known/rarecloud-app-status' <<<"$block"
    grep -qF 'root * /srv/public' <<<"$block"
    grep -qF 'header Content-Type text/plain' <<<"$block"
    grep -qF 'file_server' <<<"$block"
    refute_grep -qi 'redir' <<<"$block"
  done
}

@test "wait_for_name stops at the wall-clock deadline even when every dig call is slow" {
  echo 3 >"$STUB_TMP/dig_sleep"
  local start=$SECONDS
  run wait_for_name "$VA_HOST" "$VA_IP" 2
  [ "$status" -eq 1 ]
  [ $((SECONDS - start)) -le 5 ]
  [ "$(wc -l <"$STUB_TMP/dig.log")" -le 2 ]
}

@test "an unreadable Caddyfile template is refused and leaves the Caddyfile and the site mode alone" {
  set_site_mode installing
  cp "$CADDYFILE" "$BATS_TEST_TMPDIR/before"
  VA_BASE_DIR="$BATS_TEST_TMPDIR/no-such-dir"
  run set_site_mode failed
  [ "$status" -ne 0 ]
  cmp "$CADDYFILE" "$BATS_TEST_TMPDIR/before"
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = installing ]
}

@test "a non-app mode refuses an empty host and leaves the Caddyfile alone" {
  set_site_mode installing
  cp "$CADDYFILE" "$BATS_TEST_TMPDIR/before"
  VA_HOST=""
  run set_site_mode failed
  [ "$status" -ne 0 ]
  cmp "$CADDYFILE" "$BATS_TEST_TMPDIR/before"
  run set_site_mode app
  [ "$status" -eq 0 ]
}

@test "base_proxy checks that the proxy serves the status on port 80 before it succeeds" {
  printf '%s\n' "$VA_IP" >"$STUB_TMP/dig_answer"
  base_proxy
  grep -qxF -- '-fsS -o /dev/null --max-time 5 http://127.0.0.1/.well-known/rarecloud-app-status' "$STUB_TMP/curl.log"
}

@test "base_proxy fails when the proxy never serves, after a bounded number of tries" {
  printf '%s\n' "$VA_IP" >"$STUB_TMP/dig_answer"
  echo 7 >"$STUB_TMP/curl_rc"
  VA_PROXY_TRIES=4 VA_PROXY_INTERVAL=0 run base_proxy
  [ "$status" -ne 0 ]
  [ "$(grep -c 'rarecloud-app-status' "$STUB_TMP/curl.log")" -eq 4 ]
  grep -q 'proxy: nothing answers on port 80' "$(p /var/log/vps-apps-install.log)"
}

# Live on both dev VPS: docker-proxy accepts the connection before Caddy has its config, and curl
# exits 52 (empty reply), which curl's own --retry does not retry.
@test "base_proxy retries an empty reply (curl exit 52) until the proxy serves" {
  printf '%s\n' "$VA_IP" >"$STUB_TMP/dig_answer"
  echo 3 >"$BATS_TEST_TMPDIR/empty_replies"
  curl() {
    local n
    printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/curl_calls"
    n="$(cat "$BATS_TEST_TMPDIR/empty_replies")"
    if [ "$n" -gt 0 ]; then
      echo $((n - 1)) >"$BATS_TEST_TMPDIR/empty_replies"
      return 52
    fi
  }
  VA_PROXY_INTERVAL=0 run base_proxy
  [ "$status" -eq 0 ]
  [ "$(grep -c 'rarecloud-app-status' "$BATS_TEST_TMPDIR/curl_calls")" -eq 4 ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = installing ]
}
