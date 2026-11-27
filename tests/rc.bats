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

@test "rc update lets the app write its own .env through app_update_env when it has one" {
  printf 'N8N_IMAGE=a@%s\nN8N_IMAGE_REF=app/a:1\n' "$ZEROS" >"$DATA/.env"
  chmod 600 "$DATA/.env"
  printf 'CADDY_IMAGE=c@%s\nCADDY_IMAGE_REF=c/c:1\n' "$ZEROS" >"$PROXY/.env"
  cat >>"$APPDIR/app.sh" <<'APP'
app_update_env() {
  printf '%s|%s\n' "$1" "$2" >>"$STUB_TMP/hook.log"
  resolve_env_images "$1" "$2" && echo ADDED_BY_APP=1 >>"$2"
}
APP
  run "$RC" update
  [ "$status" -eq 0 ]
  grep -qxF ADDED_BY_APP=1 "$DATA/.env"
  grep -qE '^N8N_IMAGE=app/a@sha256:[0-9a-f]{64}$' "$DATA/.env"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  grep -qF "$DATA/.env|" "$STUB_TMP/hook.log"
  refute_grep -qF "$ZEROS" "$PROXY/.env"
  grep -qE "^compose -f .*/n8n/compose\.yml .* up -d$" "$STUB_TMP/docker.log"
}

@test "rc update changes nothing and pulls nothing when the app's app_update_env fails" {
  printf 'N8N_IMAGE=a@%s\nN8N_IMAGE_REF=app/a:1\n' "$ZEROS" >"$DATA/.env"
  printf 'CADDY_IMAGE=c@%s\nCADDY_IMAGE_REF=c/c:1\n' "$ZEROS" >"$PROXY/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/app.env"
  cp "$PROXY/.env" "$BATS_TEST_TMPDIR/proxy.env"
  cat >>"$APPDIR/app.sh" <<'APP'
app_update_env() { echo half >"$2"; return 1; }
APP
  run "$RC" update
  [ "$status" -ne 0 ]
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/app.env"
  cmp "$PROXY/.env" "$BATS_TEST_TMPDIR/proxy.env"
  refute_grep -q ' pull$' "$STUB_TMP/docker.log"
}

# real_n8n_app: the installed code is the repo's own n8n app instead of the stub hooks.
real_n8n_app() {
  cp "$BATS_TEST_DIRNAME/../apps/n8n/"* "$APPDIR/"
  printf '%s' pro >"$DATA/mode"
  : >"$DATA/exposed"
}

@test "rc update on an n8n server from the previous release adds the new keys and keeps the secrets" {
  real_n8n_app
  pg="$(printf 'a%.0s' $(seq 48))"
  key="$(printf 'b%.0s' $(seq 64))"
  n8n_ref=docker.n8n.io/n8nio/n8n:2.49.8
  n8n_hex="$(printf '%s' "$n8n_ref" | sha256sum | cut -d' ' -f1)"
  printf '%s\n' "N8N_IMAGE=docker.n8n.io/n8nio/n8n@sha256:$n8n_hex" "N8N_IMAGE_REF=$n8n_ref" \
    "POSTGRES_IMAGE=postgres@$ZEROS" POSTGRES_IMAGE_REF=postgres:16-alpine \
    "VALKEY_IMAGE=valkey/valkey@$ZEROS" VALKEY_IMAGE_REF=valkey/valkey:8-alpine POSTGRES_USER=n8n POSTGRES_DB=n8n \
    "POSTGRES_PASSWORD=$pg" "N8N_ENCRYPTION_KEY=$key" 'VA_SITE_ADDRS="app.example.com"' N8N_HOST=app.example.com \
    WEBHOOK_URL=https://app.example.com/ N8N_EDITOR_BASE_URL=https://app.example.com >"$DATA/.env"
  chmod 600 "$DATA/.env"
  printf 'CADDY_IMAGE=c@%s\nCADDY_IMAGE_REF=c/c:1\n' "$ZEROS" >"$PROXY/.env"
  run "$RC" update
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  grep -qxF "POSTGRES_PASSWORD=$pg" "$DATA/.env"
  grep -qxF "N8N_ENCRYPTION_KEY=$key" "$DATA/.env"
  grep -qxF TZ=UTC "$DATA/.env"
  grep -qxF N8N_BLOCK_ENV_ACCESS_IN_NODE=true "$DATA/.env"
  grep -Eq '^VALKEY_PASSWORD=[0-9a-f]{64}$' "$DATA/.env"
  refute_grep -qF "$ZEROS" "$DATA/.env"
  grep -qE "^compose -f .*/n8n/compose\.yml -f .*/n8n/compose\.pro\.yml -f .*/n8n/compose\.expose\.yml .* up -d$" "$STUB_TMP/docker.log"
}

@test "rc update keeps n8n on its installed major when stable moves to a new one, and says so" {
  real_n8n_app
  repo=docker.n8n.io/n8nio/n8n
  hex() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
  printf '%s\n' "N8N_IMAGE=$repo@sha256:$(hex installed)" "N8N_IMAGE_REF=$repo:stable" \
    "POSTGRES_IMAGE=postgres@$ZEROS" POSTGRES_IMAGE_REF=postgres:16-alpine \
    "VALKEY_IMAGE=valkey/valkey@$ZEROS" VALKEY_IMAGE_REF=valkey/valkey:8-alpine >"$DATA/.env"
  chmod 600 "$DATA/.env"
  printf 'CADDY_IMAGE=c@%s\nCADDY_IMAGE_REF=c/c:1\n' "$ZEROS" >"$PROXY/.env"
  printf '%s 2.49.8\n%s 3.0.0\n%s 2.50.2\n' "$(hex installed)" "$(hex "$repo:stable")" "$(hex "$repo:2.50.2")" \
    >"$STUB_TMP/registry_versions"
  hex installed >"$STUB_TMP/local_images"
  printf '[{"tag_name":"n8n@3.0.0","prerelease":false,"draft":false},{"tag_name":"n8n@2.50.2","prerelease":false,"draft":false}]' \
    >"$STUB_TMP/curl_body"
  run "$RC" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"n8n 3.0.0 is out, a new major version"* ]]
  [[ "$output" == *"n8n moves to 2.50.2, the newest 2.x release"* ]]
  [[ "$output" == *updated ]]
  grep -qxF "N8N_IMAGE=$repo@sha256:$(hex "$repo:2.50.2")" "$DATA/.env"
  grep -qxF "N8N_IMAGE_REF=$repo:stable" "$DATA/.env"
  grep -qE "^compose -f .*/n8n/compose\.yml .* up -d$" "$STUB_TMP/docker.log"
}

@test "rc update writes the app's app_fill_env first, on its own, and keeps it when an image cannot be resolved" {
  printf 'N8N_IMAGE=a@%s\nN8N_IMAGE_REF=app/a:1\n' "$ZEROS" >"$DATA/.env"
  printf 'CADDY_IMAGE=c@%s\nCADDY_IMAGE_REF=c/c:1\n' "$ZEROS" >"$PROXY/.env"
  cat >>"$APPDIR/app.sh" <<'APP'
app_fill_env() { echo fill >>"$STUB_TMP/order.log"; echo FILLED=1 >>"$1"; }
app_update_env() { echo update >>"$STUB_TMP/order.log"; resolve_env_images "$1" "$2"; }
APP
  : >"$STUB_TMP/inspect_fail"
  run "$RC" update
  [ "$status" -ne 0 ]
  [ "$(cat "$STUB_TMP/order.log")" = "$(printf 'fill\nupdate')" ]
  grep -qxF FILLED=1 "$DATA/.env"
  grep -qxF "N8N_IMAGE=a@$ZEROS" "$DATA/.env"
  refute_grep -q ' pull$' "$STUB_TMP/docker.log"
}

@test "rc update stops before any image is resolved when the app's app_fill_env fails" {
  printf 'N8N_IMAGE=a@%s\nN8N_IMAGE_REF=app/a:1\n' "$ZEROS" >"$DATA/.env"
  printf 'CADDY_IMAGE=c@%s\nCADDY_IMAGE_REF=c/c:1\n' "$ZEROS" >"$PROXY/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/app.env"
  cat >>"$APPDIR/app.sh" <<'APP'
app_fill_env() { return 1; }
APP
  run "$RC" update
  [ "$status" -eq 1 ]
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/app.env"
  refute_grep -q 'imagetools' "$STUB_TMP/docker.log"
}

@test "a pro n8n server from the previous release keeps the Valkey password rc update added, even when an image cannot be resolved" {
  real_n8n_app
  printf '%s\n' "N8N_IMAGE=docker.n8n.io/n8nio/n8n@$ZEROS" N8N_IMAGE_REF=docker.n8n.io/n8nio/n8n:latest \
    "POSTGRES_IMAGE=postgres@$ZEROS" POSTGRES_IMAGE_REF=postgres:16-alpine \
    "VALKEY_IMAGE=valkey/valkey@$ZEROS" VALKEY_IMAGE_REF=valkey/valkey:8-alpine \
    "POSTGRES_PASSWORD=$(printf 'a%.0s' $(seq 48))" "N8N_ENCRYPTION_KEY=$(printf 'b%.0s' $(seq 64))" >"$DATA/.env"
  chmod 600 "$DATA/.env"
  printf 'CADDY_IMAGE=c@%s\nCADDY_IMAGE_REF=c/c:1\n' "$ZEROS" >"$PROXY/.env"
  : >"$STUB_TMP/inspect_fail"
  run "$RC" update
  [ "$status" -eq 1 ]
  grep -Eq '^VALKEY_PASSWORD=[0-9a-f]{64}$' "$DATA/.env"
  grep -qxF TZ=UTC "$DATA/.env"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  grep -qxF "POSTGRES_PASSWORD=$(printf 'a%.0s' $(seq 48))" "$DATA/.env"
  # No image moved.
  grep -qxF "N8N_IMAGE=docker.n8n.io/n8nio/n8n@$ZEROS" "$DATA/.env"
  grep -qxF "POSTGRES_IMAGE=postgres@$ZEROS" "$DATA/.env"
  refute_grep -q ' pull$' "$STUB_TMP/docker.log"
}

@test "rc update prints what the app's app_update_env says only once every image resolved" {
  printf 'N8N_IMAGE=a@%s\nN8N_IMAGE_REF=app/a:1\n' "$ZEROS" >"$DATA/.env"
  printf 'CADDY_IMAGE=c@%s\nCADDY_IMAGE_REF=lucaslorentz/caddy-docker-proxy:2.13.1-alpine\n' "$ZEROS" >"$PROXY/.env"
  cat >>"$APPDIR/app.sh" <<'APP'
app_update_env() { echo "the app moves to 9.9.9"; resolve_env_images "$1" "$2"; }
APP
  printf 'lucaslorentz' >"$STUB_TMP/inspect_fail_match"
  run "$RC" update
  [ "$status" -eq 1 ]
  refute_grep -qF 'moves to' <<<"$output"
  rm "$STUB_TMP/inspect_fail_match"
  run "$RC" update
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "the app moves to 9.9.9" ]
  [ "${lines[${#lines[@]} - 1]}" = updated ]
}

@test "rc update on n8n says nothing about a move when the proxy image cannot be resolved" {
  real_n8n_app
  repo=docker.n8n.io/n8nio/n8n
  hex() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
  printf '%s\n' "N8N_IMAGE=$repo@sha256:$(hex installed)" "N8N_IMAGE_REF=$repo:stable" \
    "POSTGRES_IMAGE=postgres@$ZEROS" POSTGRES_IMAGE_REF=postgres:16-alpine >"$DATA/.env"
  chmod 600 "$DATA/.env"
  printf 'CADDY_IMAGE=c@%s\nCADDY_IMAGE_REF=lucaslorentz/caddy-docker-proxy:2.13.1-alpine\n' "$ZEROS" >"$PROXY/.env"
  printf '%s 2.49.8\n%s 3.0.0\n%s 2.50.2\n' "$(hex installed)" "$(hex "$repo:stable")" "$(hex "$repo:2.50.2")" \
    >"$STUB_TMP/registry_versions"
  hex installed >"$STUB_TMP/local_images"
  printf '[{"tag_name":"n8n@2.50.2","prerelease":false,"draft":false}]' >"$STUB_TMP/curl_body"
  printf 'lucaslorentz' >"$STUB_TMP/inspect_fail_match"
  run "$RC" update
  [ "$status" -eq 1 ]
  refute_grep -qF 'moves to' <<<"$output"
  [[ "$output" == *"no image changed"* ]]
  grep -qxF "N8N_IMAGE=$repo@sha256:$(hex installed)" "$DATA/.env"
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

@test "rc reads app.env before the bootstrap's env file, so an empty VA_IP there does no harm" {
  printf 'APP=n8n\nMODE=pro\nVERSION=%s\nVA_IP=\nVA_HOST=app.example.com\n' \
    0123456789abcdef0123456789abcdef01234567 >"$ETC/env"
  printf 'APP=n8n\nMODE=pro\nVA_HOST=app.example.com\nVA_IP=203.0.113.7\n' >"$ETC/app.env"
  run "$RC" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Host:   https://app.example.com"* ]]
  run "$RC" domain add shop.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"Point an A record for shop.example.com to 203.0.113.7"* ]]
}

@test "rc reads app.env as data and never runs it" {
  printf 'APP=n8n\nVA_HOST=app.example.com\nVA_IP=203.0.113.7\n$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" >"$ETC/app.env"
  run "$RC" status
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "the motd reads the host from app.env, and from the bootstrap's env file without it" {
  rm "$ETC/env"
  printf 'APP=n8n\nMODE=\nVA_HOST=other.example.com\nVA_IP=203.0.113.7\n' >"$ETC/app.env"
  run "$MOTD_SRC"
  [[ "$output" == *"Open: https://other.example.com"* ]]
  rm "$ETC/app.env"
  printf 'APP=n8n\nVA_HOST=app.example.com\n' >"$ETC/env"
  run "$MOTD_SRC"
  [[ "$output" == *"Open: https://app.example.com"* ]]
}

@test "the motd names the n8n owner email in the login hint, and only a plain address" {
  printf 'APP=n8n\nMODE=\nVA_HOST=app.example.com\nVA_IP=203.0.113.7\nADMIN_EMAIL=owner@example.org\n' >"$ETC/app.env"
  run "$MOTD_SRC"
  [[ "$output" == *"Login: owner@example.org, with the password you set when you ordered this server"* ]]
  printf 'APP=n8n\nMODE=\nVA_HOST=app.example.com\nVA_IP=203.0.113.7\nADMIN_EMAIL=%s\n' $'a\e[31m@example.org' >"$ETC/app.env"
  run "$MOTD_SRC"
  refute_grep -q $'\e' <<<"$output"
  [[ "$output" == *"Login: use the password you set when you ordered"* ]]
  printf 'APP=docker\nMODE=\nVA_HOST=app.example.com\nVA_IP=203.0.113.7\nADMIN_EMAIL=owner@example.org\n' >"$ETC/app.env"
  run "$MOTD_SRC"
  refute_grep -qF 'owner@example.org' <<<"$output"
}
