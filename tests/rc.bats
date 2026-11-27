#!/usr/bin/env bats
load test_helper

setup() {
  # shellcheck source=../lib/common.sh
  . "$BATS_TEST_DIRNAME/../lib/common.sh"
  # shellcheck source=../lib/images.sh
  . "$BATS_TEST_DIRNAME/../lib/images.sh"
  RC="$BATS_TEST_DIRNAME/../bin/rc"
  ETC="$(p /etc/vps-apps)"
  STATE="$(p /var/lib/vps-apps)"
  APPDIR="$(p /opt/vps-apps/current/apps/n8n)"
  DATA="$(p /opt/vps-apps-data/n8n)"
  PROXY="$(p /opt/vps-apps-data/proxy)"
  mkdir -p "$ETC" "$STATE/public/.well-known" "$APPDIR" "$DATA" "$PROXY"
  printf 'APP=n8n\nMODE=pro\nVERSION=%s\nVA_IP=203.0.113.7\nVA_HOST=app.example.com\n' \
    0123456789abcdef0123456789abcdef01234567 >"$ETC/env"
  printf '%s' ready >"$STATE/public/.well-known/rarecloud-app-status"
  printf '%s' app >"$STATE/site-mode"
  # A stub app: the hooks Tasks 8 and 9 provide.
  cat >"$APPDIR/app.sh" <<'APP'
app_compose_files() {
  printf '%s\n' "$VPS_APPS_ROOT/opt/vps-apps/current/apps/n8n/compose.yml"
  printf '%s\n' "$VPS_APPS_ROOT/opt/vps-apps/current/apps/n8n/compose.expose.yml"
}
app_domain_added() { printf '%s\n' "$1" >>"$STUB_TMP/hook.log"; }
APP
  printf '203.0.113.7\n' >"$STUB_TMP/dig_answer"
  MOTD_SRC="$BATS_TEST_DIRNAME/../base/files/99-vps-apps-motd"
  ZEROS="sha256:$(printf '0%.0s' $(seq 64))"
}

@test "rc domain add refuses an invalid domain" {
  for bad in "" "nodots" "-bad.example.com" "bad_name.example.com" "a..b.com" "x.example.com/path" "a b.com" "bad.example.com;id"; do
    run "$RC" domain add "$bad"
    [ "$status" -eq 2 ]
  done
  run "$RC" domain add
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_TMP/hook.log" ]
  [ ! -e "$ETC/domains" ]
}

@test "rc domain add calls app_domain_added once for a valid domain and records it" {
  run "$RC" domain add Shop.Example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"Point an A record for shop.example.com to 203.0.113.7"* ]]
  [ "$(cat "$STUB_TMP/hook.log")" = "shop.example.com" ]
  [ "$(cat "$ETC/domains")" = "shop.example.com" ]
  grep -qE '@1\.1\.1\.1 A shop\.example\.com' "$STUB_TMP/dig.log"
}

@test "rc domain add keeps earlier domains and does not list one twice" {
  "$RC" domain add one.example.com
  "$RC" domain add two.example.com
  "$RC" domain add one.example.com
  [ "$(cat "$ETC/domains")" = "$(printf 'one.example.com\ntwo.example.com')" ]
}

@test "rc domain add carries on when DNS does not point here yet" {
  : >"$STUB_TMP/dig_answer"
  RC_DNS_WAIT=1 run "$RC" domain add late.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not point"* ]]
  [ "$(cat "$STUB_TMP/hook.log")" = "late.example.com" ]
}

@test "rc domain add and rc update refuse while the app is not serving yet" {
  printf '%s' installing >"$STATE/site-mode"
  run "$RC" domain add shop.example.com
  [ "$status" -eq 1 ]
  run "$RC" update
  [ "$status" -eq 1 ]
  [ ! -e "$STUB_TMP/hook.log" ]
}

@test "rc reads the env file as data and never runs it" {
  printf 'APP=n8n\nVA_HOST=app.example.com\nVA_IP=203.0.113.7\n$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" >"$ETC/env"
  run "$RC" status
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "rc status prints the status and docker compose ps for the app" {
  : >"$DATA/.env"
  run "$RC" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"ready"* ]]
  grep -qE "^compose -f .*/n8n/compose\.yml -f .*/n8n/compose\.expose\.yml --env-file .*/opt/vps-apps-data/n8n/\.env ps$" "$STUB_TMP/docker.log"
}

@test "rc logs follows the app logs, optionally for one service" {
  run "$RC" logs
  [ "$status" -eq 0 ]
  grep -qE -- ' --env-file .*\.env logs --tail 200 -f$' "$STUB_TMP/docker.log"
  run "$RC" logs n8n
  [ "$status" -eq 0 ]
  grep -qE -- ' logs --tail 200 -f n8n$' "$STUB_TMP/docker.log"
}

@test "rc logs refuses a service name that could be an option" {
  run "$RC" logs --since=1s
  [ "$status" -eq 2 ]
  run "$RC" logs 'a;b'
  [ "$status" -eq 2 ]
}

@test "rc update re-resolves the digests of the app and the proxy, then pulls and brings both up" {
  printf 'N8N_IMAGE=docker.n8n.io/n8nio/n8n@%s\nN8N_IMAGE_REF=docker.n8n.io/n8nio/n8n:1.2.3\nOTHER=keep me\n' "$ZEROS" >"$DATA/.env"
  chmod 600 "$DATA/.env"
  printf 'CADDY_IMAGE=x@%s\nCADDY_IMAGE_REF=lucaslorentz/caddy-docker-proxy:2.13.1-alpine\n' "$ZEROS" >"$PROXY/.env"
  run "$RC" update
  [ "$status" -eq 0 ]
  want="$(printf '%s' docker.n8n.io/n8nio/n8n:1.2.3 | sha256sum | cut -d' ' -f1)"
  grep -qxF "N8N_IMAGE=docker.n8n.io/n8nio/n8n@sha256:$want" "$DATA/.env"
  grep -qxF 'N8N_IMAGE_REF=docker.n8n.io/n8nio/n8n:1.2.3' "$DATA/.env"
  grep -qxF 'OTHER=keep me' "$DATA/.env"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  refute_grep -qF "$ZEROS" "$PROXY/.env"
  grep -qF 'buildx imagetools inspect docker.n8n.io/n8nio/n8n:1.2.3' "$STUB_TMP/docker.log"
  grep -qF 'buildx imagetools inspect lucaslorentz/caddy-docker-proxy:2.13.1-alpine' "$STUB_TMP/docker.log"
  grep -qE "^compose -f .*/n8n/compose\.yml .* pull$" "$STUB_TMP/docker.log"
  grep -qE "^compose -f .*/n8n/compose\.yml .* up -d$" "$STUB_TMP/docker.log"
  grep -qE "^compose -f .*/proxy/compose\.yml --env-file .*/proxy/\.env pull$" "$STUB_TMP/docker.log"
  grep -qE "^compose -f .*/proxy/compose\.yml --env-file .*/proxy/\.env up -d$" "$STUB_TMP/docker.log"
}

@test "rc update that cannot resolve a digest changes nothing and pulls nothing" {
  printf 'N8N_IMAGE=a@%s\nN8N_IMAGE_REF=a:1\n' "$ZEROS" >"$DATA/.env"
  printf 'CADDY_IMAGE=a@%s\nCADDY_IMAGE_REF=a:1\n' "$ZEROS" >"$PROXY/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/app.env"
  cp "$PROXY/.env" "$BATS_TEST_TMPDIR/proxy.env"
  : >"$STUB_TMP/inspect_fail"
  run "$RC" update
  [ "$status" -ne 0 ]
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/app.env"
  cmp "$PROXY/.env" "$BATS_TEST_TMPDIR/proxy.env"
  refute_grep -q ' pull$' "$STUB_TMP/docker.log"
}

@test "refresh_image_digests appends a missing image line and leaves other lines alone" {
  printf 'A=1\nB_IMAGE_REF=repo/b:2\n' >"$BATS_TEST_TMPDIR/e.env"
  refresh_image_digests "$BATS_TEST_TMPDIR/e.env"
  grep -qxF 'A=1' "$BATS_TEST_TMPDIR/e.env"
  grep -qE '^B_IMAGE=repo/b@sha256:[0-9a-f]{64}$' "$BATS_TEST_TMPDIR/e.env"
}

@test "the motd reads the status at login: link, status line and login hint" {
  mkdir -p "$(p /etc/update-motd.d)"
  printf 'keep' >"$(p /etc/update-motd.d/50-landscape-sysinfo)"
  # shellcheck source=../lib/steps.sh
  . "$BATS_TEST_DIRNAME/../lib/steps.sh"
  # shellcheck source=../base/80-motd.sh
  . "$BATS_TEST_DIRNAME/../base/80-motd.sh"
  base_motd
  script="$(p /etc/update-motd.d/99-vps-apps)"
  [ -x "$script" ]
  [ "$(cat "$(p /etc/update-motd.d/50-landscape-sysinfo)")" = keep ]
  run "$script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://app.example.com"* ]]
  [[ "$output" == *"Status: ready"* ]]
  [[ "$output" == *"password you set when you ordered"* ]]
  set_status installing
  run "$script"
  [[ "$output" == *"Status: installing"* ]]
  set_status failed:docker
  run "$script"
  [[ "$output" == *"Status: failed:docker"* ]]
}

@test "the motd never reads or prints the password file" {
  printf '%s' 'S3cretMarker-PW!9' >"$ETC/password"
  chmod 600 "$ETC/password"
  run "$MOTD_SRC"
  [ "$status" -eq 0 ]
  refute_grep -qF 'S3cretMarker' <<<"$output"
  refute_grep -q 'password' <(grep -v '^#' "$MOTD_SRC" | grep -v 'password you set')
}

@test "the motd prints nothing odd for a missing or hostile status file" {
  rm "$STATE/public/.well-known/rarecloud-app-status"
  run "$MOTD_SRC"
  [[ "$output" == *"Status: unknown"* ]]
  printf '%s' $'ready\e[31m$(id)' >"$STATE/public/.well-known/rarecloud-app-status"
  run "$MOTD_SRC"
  [[ "$output" == *"Status: unknown"* ]]
  refute_grep -q $'\e' <<<"$output"
}

@test "valid_hostname enforces labels, 63 characters per label and 253 in total" {
  valid_hostname app.example.com
  valid_hostname a-b.c1.example.com
  label63="$(printf 'a%.0s' $(seq 63))"
  label64="$(printf 'a%.0s' $(seq 64))"
  valid_hostname "$label63.example.com"
  run valid_hostname "$label64.example.com"
  [ "$status" -ne 0 ]
  long="$(printf '%s.' $(seq 1 60 | sed 's/.*/abcd/'))com"
  [ "${#long}" -gt 253 ]
  run valid_hostname "$long"
  [ "$status" -ne 0 ]
  ok="$label63.$label63.$label63.example.com"
  [ "${#ok}" -le 253 ]
  valid_hostname "$ok"
  for bad in "" nodots -a.example.com a-.example.com A.example.com a..b.com "a b.example.com"; do
    run valid_hostname "$bad"
    [ "$status" -ne 0 ]
  done
}

@test "valid_ipv4 accepts dotted quads only" {
  valid_ipv4 203.0.113.7
  valid_ipv4 0.0.0.0
  for bad in "" 1.2.3 1.2.3.4.5 256.1.1.1 1.2.3.04x a.b.c.d "1.2.3.4 "; do
    run valid_ipv4 "$bad"
    [ "$status" -ne 0 ]
  done
}

@test "rc domain add refuses a label over 63 characters and a name over 253" {
  run "$RC" domain add "$(printf 'a%.0s' $(seq 64)).example.com"
  [ "$status" -eq 2 ]
  run "$RC" domain add "$(printf 'abcd.%.0s' $(seq 1 60))com"
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_TMP/hook.log" ]
}

@test "rc domain add refuses the server's own host name" {
  run "$RC" domain add App.Example.com
  [ "$status" -eq 2 ]
  [[ "$output" == *"already"* ]]
  [ ! -e "$STUB_TMP/hook.log" ]
}

@test "RC_DNS_WAIT must be a number of seconds" {
  RC_DNS_WAIT=abc run "$RC" domain add late.example.com
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_TMP/hook.log" ]
}

@test "rc status during the install prints the status and exits 0 without compose" {
  printf '%s' installing >"$STATE/public/.well-known/rarecloud-app-status"
  rm -f "$DATA/.env"
  run "$RC" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status: installing"* ]]
  [ ! -e "$STUB_TMP/docker.log" ]
}

@test "rc status without docker installed yet still exits 0" {
  : >"$DATA/.env"
  printf '%s' installing >"$STATE/public/.well-known/rarecloud-app-status"
  # A PATH with the basic tools only: the runner may have a real docker in /usr/bin.
  mkdir -p "$BATS_TEST_TMPDIR/nobin"
  for t in bash env dirname readlink cat id sed grep mktemp date mkdir basename rm; do
    ln -sf "$(command -v "$t")" "$BATS_TEST_TMPDIR/nobin/$t"
  done
  run env PATH="$BATS_TEST_TMPDIR/nobin" "$RC" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Status: installing"* ]]
}

@test "rc update writes neither .env when the proxy digest cannot be resolved" {
  printf 'N8N_IMAGE=a@%s\nN8N_IMAGE_REF=app/a:1\n' "$ZEROS" >"$DATA/.env"
  printf 'CADDY_IMAGE=c@%s\nCADDY_IMAGE_REF=lucaslorentz/caddy-docker-proxy:2.13.1-alpine\n' "$ZEROS" >"$PROXY/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/app.env"
  cp "$PROXY/.env" "$BATS_TEST_TMPDIR/proxy.env"
  printf 'lucaslorentz' >"$STUB_TMP/inspect_fail_match"
  run "$RC" update
  [ "$status" -ne 0 ]
  grep -qF 'buildx imagetools inspect app/a:1' "$STUB_TMP/docker.log"
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/app.env"
  cmp "$PROXY/.env" "$BATS_TEST_TMPDIR/proxy.env"
  refute_grep -q ' pull$' "$STUB_TMP/docker.log"
}

@test "rc domain add stops before any DNS wait or record when the app refuses the domain" {
  cat >>"$APPDIR/app.sh" <<'APP'
app_domain_check() { echo "this app takes no extra domain" >&2; return 1; }
APP
  run "$RC" domain add www.example.org
  [ "$status" -ne 0 ]
  [[ "$output" == *"this app takes no extra domain"* ]]
  [ ! -e "$ETC/domains" ]
  [ ! -e "$STUB_TMP/hook.log" ]
}
