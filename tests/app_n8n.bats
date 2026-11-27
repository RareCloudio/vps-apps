#!/usr/bin/env bats
load test_helper

setup() {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  APP_DIR="$ROOT_DIR/apps/n8n"
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
  # shellcheck source=../apps/n8n/app.sh
  . "$APP_DIR/app.sh"
  VA_HOST=n.example.com
  VA_MODE=starter
  export VA_HOST VA_MODE
  DATA="$(p /opt/vps-apps-data/n8n)"
  PWF="$BATS_TEST_TMPDIR/password"
  printf '%s' 'Secret123' >"$PWF"
  export VA_N8N_WAIT=2 VA_N8N_INTERVAL=0
  CURL_ARGV="$BATS_TEST_TMPDIR/curl_argv"
  CURL_STDIN="$BATS_TEST_TMPDIR/curl_stdin"
  : >"$CURL_ARGV"
}

# A curl that records every argv entry on its own line and the stdin of the owner call. The
# readiness probe fails as many times as the number in $BATS_TEST_TMPDIR/ready_fail (then succeeds),
# the settings call prints SETTINGS_BODY, the owner call answers OWNER_CODE and OWNER_BODY.
stub_curl() {
  curl() {
    local out="" a prev="" n
    printf '%s\n' "$@" >>"$CURL_ARGV"
    for a in "$@"; do
      [ "$prev" = -o ] && out="$a"
      prev="$a"
    done
    if [[ " $* " == *" @- "* ]]; then
      cat >"$CURL_STDIN"
      if [ -e "$BATS_TEST_TMPDIR/owner_first_400" ]; then
        rm -f "$BATS_TEST_TMPDIR/owner_first_400"
        printf '%s' '{"code":400,"message":"Password must be 8 to 64 characters long and contain at least 1 number and 1 uppercase letter"}' >"$out"
        printf 400
        return 0
      fi
      printf '%s' "${OWNER_BODY-$OWNER_OK}" >"$out"
      printf '%s' "${OWNER_CODE:-200}"
    elif [[ "$*" == *"/healthz/readiness" ]]; then
      n="$(cat "$BATS_TEST_TMPDIR/ready_fail" 2>/dev/null || echo 0)"
      if [ "$n" -gt 0 ]; then
        echo $((n - 1)) >"$BATS_TEST_TMPDIR/ready_fail"
        return 22
      fi
    elif [[ "$*" == *"/rest/settings" ]]; then
      printf '%s' "${SETTINGS_BODY-$SETTINGS_NO_SETUP}"
    fi
    return 0
  }
}

OWNER_OK='{"data":{"email":"admin@n.example.com","firstName":"Admin"}}'
SETTINGS_NO_SETUP='{"data":{"userManagement":{"showSetupOnFirstLoad":false}}}'
SETTINGS_SETUP='{"data":{"userManagement":{"showSetupOnFirstLoad":true}}}'

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

@test "secrets are generated once and a second run keeps them byte-identical" {
  app_prepare
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  grep -Eq '^N8N_ENCRYPTION_KEY=[0-9a-f]{64}$' "$DATA/.env"
  grep -Eq '^POSTGRES_PASSWORD=[0-9a-f]{48}$' "$DATA/.env"
  grep -Eq '^VALKEY_PASSWORD=[0-9a-f]{64}$' "$DATA/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  app_prepare
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
}

@test "the .env carries a digest and a ref for n8n, postgres and valkey" {
  app_prepare
  grep -Eq '^N8N_IMAGE=docker.n8n.io/n8nio/n8n@sha256:[0-9a-f]{64}$' "$DATA/.env"
  grep -Eq '^POSTGRES_IMAGE=postgres@sha256:[0-9a-f]{64}$' "$DATA/.env"
  grep -Eq '^VALKEY_IMAGE=valkey/valkey@sha256:[0-9a-f]{64}$' "$DATA/.env"
  grep -qxF 'N8N_IMAGE_REF=docker.n8n.io/n8nio/n8n:stable' "$DATA/.env"
  grep -qxF 'POSTGRES_IMAGE_REF=postgres:16-alpine' "$DATA/.env"
  grep -qxF 'VALKEY_IMAGE_REF=valkey/valkey:8-alpine' "$DATA/.env"
}

@test "n8n is installed from its stable tag, resolved and pinned by digest, never from latest" {
  app_prepare
  grep -qxF 'buildx imagetools inspect docker.n8n.io/n8nio/n8n:stable --format {{json .Manifest}}' "$STUB_TMP/docker.log"
  want="$(printf '%s' docker.n8n.io/n8nio/n8n:stable | sha256sum | cut -d' ' -f1)"
  grep -qxF "N8N_IMAGE=docker.n8n.io/n8nio/n8n@sha256:$want" "$DATA/.env"
  grep -qF 'image: ${N8N_IMAGE:-docker.n8n.io/n8nio/n8n:stable}' "$APP_DIR/compose.yml"
  [ "$VA_N8N_IMAGE_REF" = docker.n8n.io/n8nio/n8n:stable ]
  refute_grep -q 'n8n:latest' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl"
}

@test "the URL variables use the host" {
  app_prepare
  grep -qxF 'WEBHOOK_URL=https://n.example.com/' "$DATA/.env"
  grep -qxF 'N8N_EDITOR_BASE_URL=https://n.example.com' "$DATA/.env"
  grep -qxF 'N8N_HOST=n.example.com' "$DATA/.env"
  grep -qxF 'VA_SITE_ADDRS="n.example.com"' "$DATA/.env"
}

@test "valid extra domains from /etc/vps-apps/domains follow the host in VA_SITE_ADDRS, invalid ones are dropped" {
  mkdir -p "$(p /etc/vps-apps)"
  printf 'www.example.org\nnot a domain\n$(id).example.net\n' >"$(p /etc/vps-apps/domains)"
  app_prepare
  grep -qxF 'VA_SITE_ADDRS="n.example.com www.example.org"' "$DATA/.env"
}

@test "an image that cannot be resolved fails app_prepare and leaves no .env" {
  : >"$BATS_TEST_TMPDIR/inspect_fail"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
}

@test "the mode is persisted: app_compose_files works later without VA_MODE" {
  VA_MODE=pro app_prepare
  unset VA_MODE
  run app_compose_files
  [ "${lines[0]}" = "$APP_DIR/compose.yml" ]
  [ "${lines[1]}" = "$APP_DIR/compose.pro.yml" ]
  [ "${lines[2]}" = "$APP_DIR/compose.setup.yml" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "starter lists base and setup, then base and expose once the marker exists" {
  app_prepare
  run app_compose_files
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "$APP_DIR/compose.setup.yml" ]
  : >"$DATA/exposed"
  run app_compose_files
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "$APP_DIR/compose.expose.yml" ]
}

@test "pro mode config has n8n, two workers, postgres and valkey in queue mode" {
  VA_MODE=pro app_prepare
  cfg="$(merged_config compose.yml compose.pro.yml compose.setup.yml)"
  [ "$(jq -r '.services | keys | join(",")' <<<"$cfg")" = "n8n,n8n-worker,postgres,valkey" ]
  [ "$(jq -r '.services["n8n-worker"].deploy.replicas' <<<"$cfg")" = 2 ]
  [ "$(jq -r '.services.n8n.environment.EXECUTIONS_MODE' <<<"$cfg")" = queue ]
  [ "$(jq -r '.services["n8n-worker"].environment.EXECUTIONS_MODE' <<<"$cfg")" = queue ]
  [ "$(jq -r '.services["n8n-worker"].command | join(" ")' <<<"$cfg")" = worker ]
  # The worker needs the same key and database as n8n, and no published port.
  [ "$(jq -r '.services["n8n-worker"].environment.N8N_ENCRYPTION_KEY' <<<"$cfg")" = "$(jq -r '.services.n8n.environment.N8N_ENCRYPTION_KEY' <<<"$cfg")" ]
  [ "$(jq -r '.services["n8n-worker"].ports // [] | length' <<<"$cfg")" = 0 ]
}

@test "n8n and its workers run on UTC, from GENERIC_TIMEZONE and TZ in the .env" {
  # The shell's own values would win over the .env in compose; keep the test about the .env.
  unset TZ GENERIC_TIMEZONE
  VA_MODE=pro app_prepare
  grep -qxF GENERIC_TIMEZONE=UTC "$DATA/.env"
  grep -qxF TZ=UTC "$DATA/.env"
  cfg="$(merged_config compose.yml compose.pro.yml compose.expose.yml)"
  for s in n8n n8n-worker; do
    [ "$(jq -r --arg s "$s" '.services[$s].environment.GENERIC_TIMEZONE' <<<"$cfg")" = UTC ]
    [ "$(jq -r --arg s "$s" '.services[$s].environment.TZ' <<<"$cfg")" = UTC ]
  done
  # A zone set in the .env is the one n8n gets.
  sed -i 's#^GENERIC_TIMEZONE=UTC$#GENERIC_TIMEZONE=Europe/Bucharest#' "$DATA/.env"
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services.n8n.environment.GENERIC_TIMEZONE' <<<"$cfg")" = Europe/Bucharest ]
  # An .env written before these keys existed still runs n8n on UTC.
  sed -i -E '/^(GENERIC_TIMEZONE|TZ)=/d' "$DATA/.env"
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services.n8n.environment.GENERIC_TIMEZONE' <<<"$cfg")" = UTC ]
  [ "$(jq -r '.services.n8n.environment.TZ' <<<"$cfg")" = UTC ]
}

N8N_SECURITY_SETTINGS=(N8N_BLOCK_ENV_ACCESS_IN_NODE=true N8N_GIT_NODE_DISABLE_BARE_REPOS=true
  N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true N8N_SKIP_AUTH_ON_OAUTH_CALLBACK=false)

@test "n8n and its workers get the 2.x security settings explicitly, from the .env" {
  VA_MODE=pro app_prepare
  cfg="$(merged_config compose.yml compose.pro.yml compose.expose.yml)"
  for kv in "${N8N_SECURITY_SETTINGS[@]}"; do
    grep -qxF "$kv" "$DATA/.env"
    for s in n8n n8n-worker; do
      [ "$(jq -r --arg s "$s" --arg k "${kv%%=*}" '.services[$s].environment[$k]' <<<"$cfg")" = "${kv#*=}" ]
    done
  done
  # The same values when an .env written before these keys existed is used.
  sed -i -E '/^N8N_(BLOCK_ENV_ACCESS_IN_NODE|GIT_NODE_DISABLE_BARE_REPOS|ENFORCE_SETTINGS_FILE_PERMISSIONS|SKIP_AUTH_ON_OAUTH_CALLBACK)=/d' "$DATA/.env"
  cfg="$(merged_config compose.yml compose.setup.yml)"
  for kv in "${N8N_SECURITY_SETTINGS[@]}"; do
    [ "$(jq -r --arg k "${kv%%=*}" '.services.n8n.environment[$k]' <<<"$cfg")" = "${kv#*=}" ]
  done
  # NODES_EXCLUDE stays n8n's own default.
  refute_grep -q NODES_EXCLUDE "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl"
}

@test "starter mode config has neither valkey nor EXECUTIONS_MODE" {
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services | keys | join(",")' <<<"$cfg")" = "n8n,postgres" ]
  [ "$(jq -r '.services.n8n.environment.EXECUTIONS_MODE // "none"' <<<"$cfg")" = none ]
  [ "$(jq -r '.services.n8n.environment.QUEUE_BULL_REDIS_PASSWORD // "none"' <<<"$cfg")" = none ]
}

@test "the setup override publishes loopback 5678 and has no caddy labels" {
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services.n8n.ports[0] | "\(.host_ip):\(.published):\(.target)"' <<<"$cfg")" = "127.0.0.1:5678:5678" ]
  [ "$(jq -r '.services.n8n.labels // {} | length' <<<"$cfg")" = 0 ]
  grep -qF '127.0.0.1:5678:5678' "$APP_DIR/compose.setup.yml"
  refute_grep -q 'caddy' "$APP_DIR/compose.setup.yml"
}

@test "the expose override keeps the default network, joins web, labels the host and publishes no port" {
  app_prepare
  cfg="$(merged_config compose.yml compose.expose.yml)"
  [ "$(jq -r '.services.n8n.networks | keys | join(",")' <<<"$cfg")" = "default,web" ]
  [ "$(jq -r '.services.n8n.labels.caddy' <<<"$cfg")" = n.example.com ]
  [ "$(jq -r '.services.n8n.labels["caddy.reverse_proxy"]' <<<"$cfg")" = "{{upstreams 5678}}" ]
  [ "$(jq -r '.services.n8n.ports // [] | length' <<<"$cfg")" = 0 ]
  [ "$(jq -r '.services.postgres.networks | keys | join(",")' <<<"$cfg")" = default ]
}

@test "the expose label is exactly the hostnames, with no scheme or port" {
  grep -qF 'caddy: ${VA_SITE_ADDRS:?VA_SITE_ADDRS is not set}' "$APP_DIR/compose.expose.yml"
  refute_grep -qE 'https?://|:443' "$APP_DIR/compose.expose.yml"
}

@test "the owner is not managed by env and no compose file carries a password" {
  refute_grep -q 'N8N_INSTANCE_OWNER' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl" "$APP_DIR/app.sh"
  refute_grep -qi 'bcrypt' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl"
  # The only passwords in the compose files are the database and Valkey ones, taken from the .env
  # (by compose, or by the container's shell from its own environment).
  run grep -hiE 'password' "$APP_DIR"/compose.yml "$APP_DIR"/compose.pro.yml "$APP_DIR"/compose.setup.yml "$APP_DIR"/compose.expose.yml
  [ -n "$output" ]
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *'${POSTGRES_PASSWORD:?'* || "$line" == *'${VALKEY_PASSWORD:?'* || "$line" == *'$${VALKEY_PASSWORD'* ]]
  done <<<"$output"
}

@test "pro mode: Valkey requires the generated password, and n8n and the workers send it" {
  VA_MODE=pro app_prepare
  pw="$(sed -n 's/^VALKEY_PASSWORD=//p' "$DATA/.env")"
  [[ "$pw" =~ ^[0-9a-f]{64}$ ]]
  [ "$pw" != "$(sed -n 's/^N8N_ENCRYPTION_KEY=//p' "$DATA/.env")" ]
  cfg="$(merged_config compose.yml compose.pro.yml compose.expose.yml)"
  [ "$(jq -r '.services.valkey.environment.VALKEY_PASSWORD' <<<"$cfg")" = "$pw" ]
  for s in n8n n8n-worker; do
    [ "$(jq -r --arg s "$s" '.services[$s].environment.QUEUE_BULL_REDIS_PASSWORD' <<<"$cfg")" = "$pw" ]
  done
  # The value is in no command line: Valkey reads it from its own environment.
  refute_grep -qF "$pw" <<<"$(jq -c '.services.valkey | [.command, .entrypoint, .healthcheck]' <<<"$cfg")"
  # Without the key in the .env, compose refuses to start Valkey or n8n at all.
  sed -i '/^VALKEY_PASSWORD=/d' "$DATA/.env"
  run merged_config compose.yml compose.pro.yml compose.expose.yml
  [ "$status" -ne 0 ]
  [[ "$output" == *VALKEY_PASSWORD* ]]
}

# valkey_cmd <cfg> <jq path>: a command string from the merged config as the container's shell
# gets it (compose turns $$ into $).
valkey_cmd() {
  jq -r "$2 | gsub(\"\\\\$\\\\$\"; \"\$\")" <<<"$1"
}

@test "Valkey gets requirepass on stdin through its own entrypoint, never as an argument" {
  VA_MODE=pro app_prepare
  cfg="$(merged_config compose.yml compose.pro.yml compose.setup.yml)"
  [ "$(jq -r '.services.valkey.command | length' <<<"$cfg")" = 3 ]
  [ "$(jq -r '.services.valkey.command[0:2] | join(" ")' <<<"$cfg")" = "sh -c" ]
  [ "$(jq -r '.services.valkey.entrypoint // "image default"' <<<"$cfg")" = "image default" ]
  script="$(valkey_cmd "$cfg" '.services.valkey.command[2]')"$'\n'
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >"$STUB_TMP/valkey_argv"\ncat >"$STUB_TMP/valkey_stdin"\n' >"$bin/docker-entrypoint.sh"
  chmod +x "$bin/docker-entrypoint.sh"
  VALKEY_PASSWORD=s3cr3t PATH="$bin:$PATH" sh -c "$script"
  [ "$(cat "$STUB_TMP/valkey_argv")" = "valkey-server -" ]
  [ "$(cat "$STUB_TMP/valkey_stdin")" = "requirepass s3cr3t" ]
  # Without a password in its environment Valkey does not start.
  rm -f "$STUB_TMP/valkey_argv"
  run env -u VALKEY_PASSWORD PATH="$bin:$PATH" sh -c "$script"
  [ "$status" -ne 0 ]
  [ ! -e "$STUB_TMP/valkey_argv" ]
}

@test "the Valkey healthcheck authenticates through REDISCLI_AUTH and needs PONG" {
  VA_MODE=pro app_prepare
  cfg="$(merged_config compose.yml compose.pro.yml compose.setup.yml)"
  [ "$(jq -r '.services.valkey.healthcheck.test[0]' <<<"$cfg")" = CMD-SHELL ]
  hc="$(valkey_cmd "$cfg" '.services.valkey.healthcheck.test[1]')"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\nif [ "$REDISCLI_AUTH" = s3cr3t ] && [ "$*" = ping ]; then echo PONG; else echo "NOAUTH Authentication required."; fi\n' >"$bin/valkey-cli"
  chmod +x "$bin/valkey-cli"
  VALKEY_PASSWORD=s3cr3t PATH="$bin:$PATH" sh -c "$hc"
  run env VALKEY_PASSWORD=wrong PATH="$bin:$PATH" sh -c "$hc"
  [ "$status" -ne 0 ]
}

@test "the owner is created with the exact password bytes, through stdin" {
  app_prepare
  stub_curl
  printf '%s' 'P@ss"w\0rd $x`y;1A' >"$PWF"
  app_create_admin "$PWF"
  grep -qxF -- '--data-binary' "$CURL_ARGV"
  grep -qxF -- '@-' "$CURL_ARGV"
  grep -qxF 'http://127.0.0.1:5678/rest/owner/setup' "$CURL_ARGV"
  refute_grep -qF 'P@ss' "$CURL_ARGV"
  jq -j .password "$CURL_STDIN" >"$BATS_TEST_TMPDIR/sent"
  cmp "$BATS_TEST_TMPDIR/sent" "$PWF"
  [ "$(jq -r .email "$CURL_STDIN")" = admin@n.example.com ]
  [ "$(jq -r .firstName "$CURL_STDIN")" = Admin ]
  [ "$(jq -r .lastName "$CURL_STDIN")" = RareCloud ]
  [ ! -e "$(p /root/vps-apps-credentials.txt)" ]
}

@test "the password never lands in the .env or a docker call" {
  app_prepare
  stub_curl
  app_create_admin "$PWF"
  refute_grep -qF 'Secret123' "$DATA/.env"
  refute_grep -qF 'Secret123' "$STUB_TMP/docker.log"
}

@test "an owner that already exists (HTTP 400, already setup) counts as success" {
  app_prepare
  stub_curl
  OWNER_CODE=400 OWNER_BODY='{"code":400,"message":"Instance owner already setup"}' app_create_admin "$PWF"
}

@test "any other owner setup failure fails the step" {
  app_prepare
  stub_curl
  OWNER_CODE=500 OWNER_BODY='boom' run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  OWNER_CODE=400 OWNER_BODY='{"message":"Invalid password"}' run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
}

@test "app_create_admin waits for n8n, bounded, and fails when it never answers" {
  app_prepare
  curl() { printf '%s\n' "$*" >>"$CURL_ARGV"; return 7; }
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  grep -qF 'http://127.0.0.1:5678/healthz/readiness' "$CURL_ARGV"
  grep -qF -- '--max-time 30' "$CURL_ARGV"
  refute_grep -qxF 'http://127.0.0.1:5678/healthz' "$CURL_ARGV"
  refute_grep -qF '/rest/owner/setup' "$CURL_ARGV"
}

@test "a password that breaks the n8n rule falls back to a generated one in the credentials file" {
  app_prepare
  stub_curl
  for bad in short alllowercase1 NoDigitsHere ALLUPPER "$(printf 'Aa1%.0s' $(seq 22))"; do
    : >"$CURL_ARGV"
    rm -f "$(p /root/vps-apps-credentials.txt)"
    printf '%s' "$bad" >"$PWF"
    app_create_admin "$PWF"
    cred="$(p /root/vps-apps-credentials.txt)"
    [ "$(stat -c %a "$cred")" = 600 ]
    sent="$(jq -r .password "$CURL_STDIN")"
    [ "$sent" != "$bad" ]
    [[ "${#sent}" -ge 8 && "${#sent}" -le 64 && "$sent" =~ [A-Z] && "$sent" =~ [0-9] ]]
    grep -qF "$sent" "$cred"
    grep -qF 'admin@n.example.com' "$cred"
  done
}

@test "passwords that satisfy the rule are sent as they are, at 8 and 64 characters" {
  app_prepare
  stub_curl
  for good in Abcdefg1 alllowercase1A "A1$(printf 'x%.0s' $(seq 62))"; do
    printf '%s' "$good" >"$PWF"
    app_create_admin "$PWF"
    [ "$(jq -j .password "$CURL_STDIN")" = "$good" ]
    [ ! -e "$(p /root/vps-apps-credentials.txt)" ]
  done
  [ "${#good}" -eq 64 ]
}

@test "a retry after a fallback keeps the credentials file and the password in it" {
  app_prepare
  stub_curl
  printf '%s' short >"$PWF"
  app_create_admin "$PWF"
  cp "$(p /root/vps-apps-credentials.txt)" "$BATS_TEST_TMPDIR/cred1"
  first="$(jq -r .password "$CURL_STDIN")"
  app_create_admin "$PWF"
  cmp "$(p /root/vps-apps-credentials.txt)" "$BATS_TEST_TMPDIR/cred1"
  [ "$(jq -r .password "$CURL_STDIN")" = "$first" ]
}

@test "the MOTD points at the credentials file only when it exists and never prints its content" {
  motd="$ROOT_DIR/base/files/99-vps-apps-motd"
  run "$motd"
  refute_grep -qF 'vps-apps-credentials.txt' <<<"$output"
  mkdir -p "$(p /root)"
  printf 'Password: TopSecret123\n' >"$(p /root/vps-apps-credentials.txt)"
  run "$motd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/root/vps-apps-credentials.txt"* ]]
  refute_grep -qF 'TopSecret' <<<"$output"
}

@test "app_up_setup starts the stack with the setup file" {
  app_prepare
  app_up_setup
  grep -q "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.setup.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
}

@test "app_expose writes the marker, puts the site in app mode and starts the expose file" {
  app_prepare
  stub_curl
  app_expose
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
  grep -q "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.expose.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
}

@test "a failed start in app_expose takes the stack down, drops the marker and shows the failed page" {
  app_prepare
  stub_curl
  docker() { printf '%s\n' "$*" >>"$STUB_TMP/docker_calls"; [[ "$*" != *compose.expose.yml*" up"* ]]; }
  run app_expose
  [ "$status" -ne 0 ]
  grep -q ' down' "$STUB_TMP/docker_calls"
  [ ! -e "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
}

@test "app_ready_check needs n8n healthy over HTTPS on the server own name" {
  curl() { printf '%s\n' "$*" >"$BATS_TEST_TMPDIR/curl_args"; printf '{"status":"ok"}'; }
  app_ready_check
  grep -qF -- '--resolve n.example.com:443:127.0.0.1 https://n.example.com/healthz/readiness' "$BATS_TEST_TMPDIR/curl_args"
  curl() { printf 'something else'; }
  run app_ready_check
  [ "$status" -ne 0 ]
  curl() { printf '{"status":"ok"}'; return 23; }
  run app_ready_check
  [ "$status" -ne 0 ]
}

# urls_are <host>: the three n8n URL variables in the .env name this host.
urls_are() {
  grep -qxF "WEBHOOK_URL=https://$1/" "$DATA/.env"
  grep -qxF "N8N_EDITOR_BASE_URL=https://$1" "$DATA/.env"
  grep -qxF "N8N_HOST=$1" "$DATA/.env"
}

@test "app_domain_added serves both names and moves the three URL variables to the new domain" {
  app_prepare
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  mkdir -p "$(p /etc/vps-apps)"
  printf 'www.example.org\n' >"$(p /etc/vps-apps/domains)"
  : >"$STUB_TMP/docker.log"
  app_domain_added www.example.org
  grep -qxF 'VA_SITE_ADDRS="n.example.com www.example.org"' "$DATA/.env"
  urls_are www.example.org
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  # Every secret and image line is untouched.
  diff <(grep -vE '^(VA_SITE_ADDRS|WEBHOOK_URL|N8N_EDITOR_BASE_URL|N8N_HOST)=' "$BATS_TEST_TMPDIR/before") \
    <(grep -vE '^(VA_SITE_ADDRS|WEBHOOK_URL|N8N_EDITOR_BASE_URL|N8N_HOST)=' "$DATA/.env")
  grep -q 'compose .* up -d' "$STUB_TMP/docker.log"
}

@test "each domain added later takes the URL variables over; the server's own name stays served" {
  app_prepare
  mkdir -p "$(p /etc/vps-apps)"
  printf 'one.example.org\n' >"$(p /etc/vps-apps/domains)"
  app_domain_added one.example.org
  printf 'one.example.org\ntwo.example.org\n' >"$(p /etc/vps-apps/domains)"
  app_domain_added two.example.org
  grep -qxF 'VA_SITE_ADDRS="n.example.com one.example.org two.example.org"' "$DATA/.env"
  urls_are two.example.org
  # Adding one again (rc keeps the list as it is) makes it the main address again.
  app_domain_added one.example.org
  urls_are one.example.org
  grep -qxF 'VA_SITE_ADDRS="n.example.com one.example.org two.example.org"' "$DATA/.env"
}

@test "an invalid domain given to app_domain_added leaves the URL variables on the host" {
  app_prepare
  app_domain_added 'bad domain;id'
  urls_are n.example.com
}

@test "n8n defines no app_domain_check, so rc domain add accepts extra domains" {
  run declare -F app_domain_check
  [ "$status" -ne 0 ]
}

@test "a 200 'starting up' answer to the owner call does not count: the step fails" {
  app_prepare
  stub_curl
  OWNER_BODY='n8n is starting up. Please wait' run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  OWNER_BODY='{"data":{"email":"someone@else.com"}}' run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  OWNER_BODY='' run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
}

@test "a 200 that carries the owner counts" {
  app_prepare
  stub_curl
  app_create_admin "$PWF"
}

@test "the readiness probe failing twice is waited out before the owner call" {
  app_prepare
  stub_curl
  echo 2 >"$BATS_TEST_TMPDIR/ready_fail"
  app_create_admin "$PWF"
  [ "$(grep -c 'healthz/readiness' "$CURL_ARGV")" -eq 3 ]
  [ -s "$CURL_STDIN" ]
}

@test "the readiness probe and the owner call have a 30 second cap" {
  app_prepare
  stub_curl
  app_create_admin "$PWF"
  [ "$(grep -cxF -- '--max-time' "$CURL_ARGV")" -eq 2 ]
  [ "$(grep -cxF 30 "$CURL_ARGV")" -eq 2 ]
}

@test "app_expose refuses while n8n still offers the owner setup, and changes nothing" {
  app_prepare
  stub_curl
  : >"$STUB_TMP/docker.log"
  SETTINGS_BODY="$SETTINGS_SETUP" run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ ! -e "$(p /var/lib/vps-apps/site-mode)" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
}

@test "app_expose refuses when the settings answer cannot be read" {
  app_prepare
  stub_curl
  SETTINGS_BODY='n8n is starting up. Please wait' run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  SETTINGS_BODY='' run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
}

@test "app_expose reads the setup flag from the loopback settings endpoint" {
  app_prepare
  stub_curl
  app_expose
  grep -qxF 'http://127.0.0.1:5678/rest/settings' "$CURL_ARGV"
}

@test "a non-ASCII or non-printable password uses the generated fallback" {
  app_prepare
  stub_curl
  for bad in 'Pässword1x' $'Tab\tPass1word' $'Pass\nword1X' 'Пароль1Abcdef'; do
    rm -f "$(p /root/vps-apps-credentials.txt)"
    printf '%s' "$bad" >"$PWF"
    app_create_admin "$PWF"
    sent="$(jq -r .password "$CURL_STDIN")"
    [ "$sent" != "$bad" ]
    [ -f "$(p /root/vps-apps-credentials.txt)" ]
  done
}

@test "a 400 'Password must ...' from n8n triggers the fallback and a second call" {
  app_prepare
  stub_curl
  : >"$BATS_TEST_TMPDIR/owner_first_400"
  app_create_admin "$PWF"
  cred="$(p /root/vps-apps-credentials.txt)"
  [ -f "$cred" ]
  [ "$(stat -c %a "$cred")" = 600 ]
  [ "$(jq -r .password "$CURL_STDIN")" != Secret123 ]
  grep -qF "$(jq -r .password "$CURL_STDIN")" "$cred"
  [ "$(grep -c 'rest/owner/setup' "$CURL_ARGV")" -eq 2 ]
}

@test "the MOTD shows only the fallback hint, not 'use the password you set', when the credentials file exists" {
  motd="$ROOT_DIR/base/files/99-vps-apps-motd"
  run "$motd"
  [[ "$output" == *"use the password you set"* ]]
  mkdir -p "$(p /root)"
  printf 'Password: TopSecret123\n' >"$(p /root/vps-apps-credentials.txt)"
  run "$motd"
  [[ "$output" == *"/root/vps-apps-credentials.txt"* ]]
  refute_grep -qF 'use the password you set' <<<"$output"
}

@test "check-compose.sh fails when a compose file is in no checked combination" {
  copy="$BATS_TEST_TMPDIR/copy"
  mkdir -p "$copy"
  cp -r "$ROOT_DIR/scripts" "$ROOT_DIR/apps" "$ROOT_DIR/base" "$copy/"
  printf 'services: {}\n' >"$copy/apps/n8n/compose.extra.yml"
  docker() { return 0; }
  export -f docker
  run bash "$copy/scripts/check-compose.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"compose.extra.yml"* ]]
}

@test "the template substitution is literal for a value with an ampersand and a backslash" {
  resolve_image_digest() { printf '%s\n' 'x/y&z\w@sha256:abc'; }
  app_prepare
  grep -qxF 'N8N_IMAGE=x/y&z\w@sha256:abc' "$DATA/.env"
  grep -qxF 'POSTGRES_IMAGE=x/y&z\w@sha256:abc' "$DATA/.env"
}

@test "app_expose brings the setup stack up and waits for n8n before it checks the settings" {
  app_prepare
  stub_curl
  : >"$DATA/exposed"
  : >"$STUB_TMP/docker.log"
  app_expose
  setup_line="$(grep -n "compose.setup.yml.* up -d" "$STUB_TMP/docker.log" | head -n1 | cut -d: -f1)"
  expose_line="$(grep -n "compose.expose.yml.* up -d" "$STUB_TMP/docker.log" | head -n1 | cut -d: -f1)"
  [ -n "$setup_line" ] && [ -n "$expose_line" ] && [ "$setup_line" -lt "$expose_line" ]
  # readiness was probed before the settings were read
  [ "$(grep -n 'healthz/readiness' "$CURL_ARGV" | head -n1 | cut -d: -f1)" -lt "$(grep -n 'rest/settings' "$CURL_ARGV" | head -n1 | cut -d: -f1)" ]
}

@test "a failed expose followed by a retry recovers, and the retry still refuses while setup is offered" {
  app_prepare
  stub_curl
  docker() {
    printf '%s\n' "$*" >>"$STUB_TMP/docker.log"
    if [[ "$*" == *compose.expose.yml*" up"* ]] && [ ! -e "$BATS_TEST_TMPDIR/expose_failed_once" ]; then
      : >"$BATS_TEST_TMPDIR/expose_failed_once"
      return 1
    fi
    return 0
  }
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
  : >"$STUB_TMP/docker.log"
  SETTINGS_BODY="$SETTINGS_SETUP" run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  grep -q "compose.setup.yml.* up -d" "$STUB_TMP/docker.log"
  run app_expose
  [ "$status" -eq 0 ]
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
}

@test "app_expose fails without exposing when n8n never becomes ready after the setup stack is up" {
  app_prepare
  stub_curl
  echo 999 >"$BATS_TEST_TMPDIR/ready_fail"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
}

@test "check-compose.sh also catches an uncombined .yaml file under base/" {
  copy="$BATS_TEST_TMPDIR/copy2"
  mkdir -p "$copy/base/other"
  cp -r "$ROOT_DIR/scripts" "$ROOT_DIR/apps" "$ROOT_DIR/base" "$copy/"
  printf 'services: {}\n' >"$copy/base/other/compose.yaml"
  docker() { return 0; }
  export -f docker
  run bash "$copy/scripts/check-compose.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"base/other/compose.yaml"* ]]
}

@test "the owner gets the email install.sh settled on (VA_ADMIN_EMAIL)" {
  app_prepare
  stub_curl
  VA_ADMIN_EMAIL=owner@example.org OWNER_BODY='{"data":{"email":"owner@example.org"}}' app_create_admin "$PWF"
  [ "$(jq -r .email "$CURL_STDIN")" = owner@example.org ]
}

@test "an owner answer for another email than VA_ADMIN_EMAIL does not count" {
  app_prepare
  stub_curl
  VA_ADMIN_EMAIL=owner@example.org run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
}

@test "the generated fallback login names the owner email" {
  app_prepare
  stub_curl
  printf '%s' short >"$PWF"
  VA_ADMIN_EMAIL=owner@example.org OWNER_BODY='{"data":{"email":"owner@example.org"}}' app_create_admin "$PWF"
  grep -qxF 'Email: owner@example.org' "$(p /root/vps-apps-credentials.txt)"
}

# old_env: the .env the previous release wrote (env.tmpl before the time zone, security and Valkey
# keys), on a server with one extra domain.
old_env() {
  mkdir -p "$DATA"
  cat >"$DATA/.env" <<ENV
N8N_IMAGE=docker.n8n.io/n8nio/n8n@sha256:$(printf '1%.0s' $(seq 64))
N8N_IMAGE_REF=docker.n8n.io/n8nio/n8n:latest
POSTGRES_IMAGE=postgres@sha256:$(printf '2%.0s' $(seq 64))
POSTGRES_IMAGE_REF=postgres:16-alpine
VALKEY_IMAGE=valkey/valkey@sha256:$(printf '3%.0s' $(seq 64))
VALKEY_IMAGE_REF=valkey/valkey:8-alpine
POSTGRES_USER=n8n
POSTGRES_DB=n8n
POSTGRES_PASSWORD=$(printf 'a%.0s' $(seq 48))
N8N_ENCRYPTION_KEY=$(printf 'b%.0s' $(seq 64))
VA_SITE_ADDRS="n.example.com www.example.org"
N8N_HOST=www.example.org
WEBHOOK_URL=https://www.example.org/
N8N_EDITOR_BASE_URL=https://www.example.org
ENV
  chmod 600 "$DATA/.env"
}

# env_keys <file>: the keys of a .env file, sorted.
env_keys() {
  sed -n 's/^\([A-Za-z0-9_]*\)=.*/\1/p' "$1" | sort
}

@test "the update fill adds every key env.tmpl gained since the previous release and keeps every line" {
  old_env
  n8n_fill_env "$DATA/.env" >"$BATS_TEST_TMPDIR/out"
  # Every line the server had comes first, byte for byte (the image tag has its own test).
  diff <(head -n 14 "$BATS_TEST_TMPDIR/out" | grep -v '^N8N_IMAGE_REF=') <(grep -v '^N8N_IMAGE_REF=' "$DATA/.env")
  for kv in GENERIC_TIMEZONE=UTC TZ=UTC "${N8N_SECURITY_SETTINGS[@]}"; do
    grep -qxF "$kv" "$BATS_TEST_TMPDIR/out"
  done
  grep -Eq '^VALKEY_PASSWORD=[0-9a-f]{64}$' "$BATS_TEST_TMPDIR/out"
  # The keys are then exactly the template's, each once.
  diff <(env_keys "$BATS_TEST_TMPDIR/out") <(env_keys "$APP_DIR/env.tmpl")
}

@test "the update fill keeps a value the server already has and never adds a key twice" {
  old_env
  printf 'GENERIC_TIMEZONE=Europe/Bucharest\nN8N_BLOCK_ENV_ACCESS_IN_NODE=false\nVALKEY_PASSWORD=keep-me\n' >>"$DATA/.env"
  n8n_fill_env "$DATA/.env" >"$BATS_TEST_TMPDIR/out"
  diff <(head -n 17 "$BATS_TEST_TMPDIR/out" | grep -v '^N8N_IMAGE_REF=') <(grep -v '^N8N_IMAGE_REF=' "$DATA/.env")
  for k in GENERIC_TIMEZONE N8N_BLOCK_ENV_ACCESS_IN_NODE VALKEY_PASSWORD; do
    [ "$(grep -c "^$k=" "$BATS_TEST_TMPDIR/out")" -eq 1 ]
  done
  grep -qxF VALKEY_PASSWORD=keep-me "$BATS_TEST_TMPDIR/out"
  diff <(env_keys "$BATS_TEST_TMPDIR/out") <(env_keys "$APP_DIR/env.tmpl")
}

@test "the update fill never makes up the database password, the encryption key, a URL or an image" {
  old_env
  sed -i -E '/^(POSTGRES_PASSWORD|N8N_ENCRYPTION_KEY|N8N_HOST|WEBHOOK_URL|VA_SITE_ADDRS|N8N_IMAGE)=/d' "$DATA/.env"
  n8n_fill_env "$DATA/.env" >"$BATS_TEST_TMPDIR/out"
  refute_grep -qE '^(POSTGRES_PASSWORD|N8N_ENCRYPTION_KEY|N8N_HOST|WEBHOOK_URL|VA_SITE_ADDRS|N8N_IMAGE)=' "$BATS_TEST_TMPDIR/out"
  refute_grep -qE '@[A-Z0-9_]+@' "$BATS_TEST_TMPDIR/out"
  grep -qxF TZ=UTC "$BATS_TEST_TMPDIR/out"
}

@test "a second update fill adds nothing and keeps the Valkey password it made" {
  old_env
  n8n_fill_env "$DATA/.env" >"$BATS_TEST_TMPDIR/once"
  cp "$BATS_TEST_TMPDIR/once" "$DATA/.env"
  n8n_fill_env "$DATA/.env" >"$BATS_TEST_TMPDIR/twice"
  cmp "$BATS_TEST_TMPDIR/once" "$BATS_TEST_TMPDIR/twice"
}

@test "an .env without a final newline gets the new keys on lines of their own" {
  old_env
  sed -i '$d' "$DATA/.env"
  printf 'N8N_EDITOR_BASE_URL=https://www.example.org' >>"$DATA/.env"
  n8n_fill_env "$DATA/.env" >"$BATS_TEST_TMPDIR/out"
  grep -qxF 'N8N_EDITOR_BASE_URL=https://www.example.org' "$BATS_TEST_TMPDIR/out"
  grep -qxF TZ=UTC "$BATS_TEST_TMPDIR/out"
}

@test "app_fill_env writes the missing keys into the .env itself, keeps its mode and resolves no image" {
  old_env
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  app_fill_env "$DATA/.env"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  grep -qxF TZ=UTC "$DATA/.env"
  grep -Eq '^VALKEY_PASSWORD=[0-9a-f]{64}$' "$DATA/.env"
  diff <(head -n 14 "$DATA/.env" | grep -v '^N8N_IMAGE_REF=') <(grep -v '^N8N_IMAGE_REF=' "$BATS_TEST_TMPDIR/before")
  refute_grep -q imagetools "$STUB_TMP/docker.log"
  # Nothing left behind next to it.
  [ "$(find "$DATA" -name '.*' -type f ! -name .env | wc -l)" -eq 0 ]
}

@test "app_fill_env leaves a complete .env as it is, not even rewritten" {
  app_prepare
  before="$(stat -c %i "$DATA/.env")"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  app_fill_env "$DATA/.env"
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  [ "$(stat -c %i "$DATA/.env")" = "$before" ]
}

@test "app_fill_env fails and leaves the .env as it is when it cannot make the keys" {
  old_env
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  openssl() { return 1; }
  run app_fill_env "$DATA/.env"
  [ "$status" -eq 1 ]
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
}

@test "app_update_env re-resolves the images into the out file and never writes the .env" {
  old_env
  app_fill_env "$DATA/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  want="$(printf '%s' postgres:16-alpine | sha256sum | cut -d' ' -f1)"
  grep -qxF "POSTGRES_IMAGE=postgres@sha256:$want" "$BATS_TEST_TMPDIR/out"
  grep -qxF "POSTGRES_PASSWORD=$(printf 'a%.0s' $(seq 48))" "$BATS_TEST_TMPDIR/out"
  grep -qxF "N8N_ENCRYPTION_KEY=$(printf 'b%.0s' $(seq 64))" "$BATS_TEST_TMPDIR/out"
}

@test "app_update_env fails with nothing in the out file when an image cannot be resolved" {
  old_env
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  : >"$STUB_TMP/inspect_fail"
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 1 ]
  [ ! -s "$BATS_TEST_TMPDIR/out" ]
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
}

N8N_REPO=docker.n8n.io/n8nio/n8n

# hex_of <ref>: the digest the docker stub answers for a tag.
hex_of() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# registry_has <hex> <label>: the registry serves that image, with that version label.
registry_has() {
  printf '%s %s\n' "$1" "$2" >>"$STUB_TMP/registry_versions"
}

# installed <version> [ref]: a freshly prepared server whose n8n image (on the server) is labelled
# <version>; with a ref, it is the image that ref points to. INSTALLED is that image.
installed() {
  local h
  app_prepare
  h="$(hex_of "${2:-installed-$1}")"
  INSTALLED="$N8N_REPO@sha256:$h"
  sed -i "s#^N8N_IMAGE=.*#N8N_IMAGE=$INSTALLED#" "$DATA/.env"
  registry_has "$h" "$1"
  printf '%s\n' "$h" >>"$STUB_TMP/local_images"
}

# stable_is <label>: the stable tag points to an image with that version label.
stable_is() {
  registry_has "$(hex_of "$N8N_REPO:stable")" "$1"
}

# tag_has <version> [label]: the registry has the n8n:<version> tag, labelled <version> (or <label>).
tag_has() {
  registry_has "$(hex_of "$N8N_REPO:$1")" "${2:-$1}"
}

# releases <tag:prerelease>...: what the GitHub releases API answers.
releases() {
  local a sep=""
  {
    printf '['
    for a in "$@"; do
      printf '%s{"tag_name":"%s","name":"%s","prerelease":%s,"draft":false}' "$sep" "${a%:*}" "${a%:*}" "${a##*:}"
      sep=,
    done
    printf ']'
  } >"$STUB_TMP/curl_body"
}

# update: run the hook as rc update does; OUT is the resolved .env.
update() {
  OUT="$BATS_TEST_TMPDIR/out"
  run app_update_env "$DATA/.env" "$OUT"
}

n8n_image_in() {
  sed -n 's/^N8N_IMAGE=//p' "$1"
}

@test "update: a newer stable of the installed major is taken as before, with no GitHub lookup" {
  installed 2.49.8
  stable_is 2.50.1
  update
  [ "$status" -eq 0 ]
  [ "$(n8n_image_in "$OUT")" = "$N8N_REPO@sha256:$(hex_of "$N8N_REPO:stable")" ]
  [ ! -e "$STUB_TMP/curl.log" ]
  # The installed version is read from the image on the server: no pull for it.
  grep -qxF "image inspect --format {{index .Config.Labels \"org.opencontainers.image.version\"}} $INSTALLED" "$STUB_TMP/docker.log"
  refute_grep -qxF "pull -q $INSTALLED" "$STUB_TMP/docker.log"
}

@test "update: a new major on stable is not taken; n8n moves to the newest full release of its major" {
  installed 2.49.8
  stable_is 3.0.1
  releases stable:false beta:true n8n@3.0.1:false n8n@3.1.0:true n8n@2.52.0:true n8n@2.51.9:false \
    n8n@2.51.10:false n8n@1.123.102:false n8n@2.49.8:false
  tag_has 2.51.10
  update
  [ "$status" -eq 0 ]
  [ "$(n8n_image_in "$OUT")" = "$N8N_REPO@sha256:$(hex_of "$N8N_REPO:2.51.10")" ]
  [[ "$output" == *"n8n 3.0.1 is out, a new major version"* ]]
  [[ "$output" == *"stays on n8n 2.x"* ]]
  [[ "$output" == *"n8n moves to 2.51.10, the newest 2.x release"* ]]
  grep -qF 'https://api.github.com/repos/n8n-io/n8n/releases' "$STUB_TMP/curl.log"
  # Every other image is updated as usual, and the stable tag stays the one followed.
  grep -qxF "POSTGRES_IMAGE=postgres@sha256:$(hex_of postgres:16-alpine)" "$OUT"
  grep -qxF "N8N_IMAGE_REF=$N8N_REPO:stable" "$OUT"
}

@test "update: a new major and GitHub does not answer: n8n keeps its image and says so" {
  installed 2.49.8
  stable_is 3.0.1
  echo 22 >"$STUB_TMP/curl_rc"
  update
  [ "$status" -eq 0 ]
  [ "$(n8n_image_in "$OUT")" = "$INSTALLED" ]
  [[ "$output" == *"cannot find a newer n8n 2.x release, so n8n stays on 2.49.8"* ]]
  grep -qxF "VALKEY_IMAGE=valkey/valkey@sha256:$(hex_of valkey/valkey:8-alpine)" "$OUT"
}

@test "update: a new major and an unusable GitHub answer: n8n keeps its image" {
  installed 2.49.8
  stable_is 3.0.1
  for body in '{"message":"API rate limit exceeded"}' 'not json' '[]' \
    '[{"tag_name":"n8n@2.52.0","prerelease":true,"draft":false}]' \
    '[{"tag_name":"n8n@2.52.0","prerelease":false,"draft":true}]' \
    '[{"tag_name":"n8n@3.0.1","prerelease":false,"draft":false},{"tag_name":"stable","prerelease":false,"draft":false}]'; do
    printf '%s' "$body" >"$STUB_TMP/curl_body"
    update
    [ "$status" -eq 0 ]
    [ "$(n8n_image_in "$OUT")" = "$INSTALLED" ]
  done
}

@test "update: the release found must carry its own version in its label, else n8n keeps its image" {
  installed 2.49.8
  stable_is 3.0.1
  releases n8n@2.51.10:false
  tag_has 2.51.10 3.0.0
  update
  [ "$status" -eq 0 ]
  [ "$(n8n_image_in "$OUT")" = "$INSTALLED" ]
}

@test "update: the newest release of the major being older than the installed one keeps the image" {
  installed 2.55.0
  stable_is 3.0.1
  releases n8n@2.54.0:false
  tag_has 2.54.0
  update
  [ "$status" -eq 0 ]
  [ "$(n8n_image_in "$OUT")" = "$INSTALLED" ]
}

@test "update: the installed version being the newest of its major keeps n8n where it is" {
  installed 2.51.10 "$N8N_REPO:2.51.10"
  stable_is 3.0.1
  releases n8n@2.51.10:false n8n@2.51.9:false
  update
  [ "$status" -eq 0 ]
  [ "$(n8n_image_in "$OUT")" = "$INSTALLED" ]
  [[ "$output" == *"n8n stays on 2.51.10, the newest 2.x release"* ]]
  refute_grep -q 'moves to' <<<"$output"
}

@test "update: n8n never moves back to an older version of its major" {
  installed 2.49.8
  stable_is 2.48.0
  update
  [ "$status" -eq 0 ]
  [ "$(n8n_image_in "$OUT")" = "$INSTALLED" ]
  [[ "$output" == *"older than 2.49.8"* ]]
}

@test "update: an installed version that cannot be read keeps n8n on its image" {
  installed 2.49.8
  stable_is 2.50.1
  # Neither on the server nor in the registry any more.
  : >"$STUB_TMP/local_images"
  sed -i "/^$(hex_of installed-2.49.8) /d" "$STUB_TMP/registry_versions"
  update
  [ "$status" -eq 0 ]
  [ "$(n8n_image_in "$OUT")" = "$INSTALLED" ]
  [[ "$output" == *"cannot read the version of the n8n image this server runs"* ]]
}

@test "update: an installed image no longer on the server is pulled by its digest to read its version" {
  installed 2.49.8
  stable_is 2.50.1
  : >"$STUB_TMP/local_images"
  update
  [ "$status" -eq 0 ]
  grep -qxF "pull -q $INSTALLED" "$STUB_TMP/docker.log"
  [ "$(n8n_image_in "$OUT")" = "$N8N_REPO@sha256:$(hex_of "$N8N_REPO:stable")" ]
}

@test "update: a stable image without a plain version label keeps n8n on its image" {
  installed 2.49.8
  stable_is nightly
  update
  [ "$status" -eq 0 ]
  [ "$(n8n_image_in "$OUT")" = "$INSTALLED" ]
  [[ "$output" == *"cannot read the version of the n8n image the stable tag points to"* ]]
}

@test "update: when the tag still points to the image the server runs, nothing is inspected or pulled" {
  app_prepare
  update
  [ "$status" -eq 0 ]
  [ "$(n8n_image_in "$OUT")" = "$(n8n_image_in "$DATA/.env")" ]
  refute_grep -qE '^(image inspect|pull) ' "$STUB_TMP/docker.log"
  [ -z "$output" ]
}

@test "update: a failed write of the held image fails the hook, so rc update changes nothing" {
  n8n_env_set() { return 1; }
  installed 2.49.8
  stable_is 2.48.0
  update
  [ "$status" -eq 1 ]
  : >"$STUB_TMP/registry_versions"
  installed 2.49.8
  stable_is 3.0.1
  echo 22 >"$STUB_TMP/curl_rc"
  update
  [ "$status" -eq 1 ]
}

@test "the update fill moves an .env on the previous release's latest tag to stable, and no other tag" {
  old_env
  n8n_fill_env "$DATA/.env" >"$BATS_TEST_TMPDIR/out"
  [ "$(grep -c '^N8N_IMAGE_REF=' "$BATS_TEST_TMPDIR/out")" -eq 1 ]
  grep -qxF "N8N_IMAGE_REF=$N8N_REPO:stable" "$BATS_TEST_TMPDIR/out"
  # A tag the owner set by hand is left as it is.
  for ref in "$N8N_REPO:2.49.8" "$N8N_REPO:latest-debian" "n8nio/n8n:latest"; do
    sed -i "s#^N8N_IMAGE_REF=.*#N8N_IMAGE_REF=$ref#" "$DATA/.env"
    n8n_fill_env "$DATA/.env" >"$BATS_TEST_TMPDIR/out"
    grep -qxF "N8N_IMAGE_REF=$ref" "$BATS_TEST_TMPDIR/out"
  done
}

@test "an empty VALKEY_PASSWORD counts as missing: the fill puts a new secret on that line" {
  for empty in 'VALKEY_PASSWORD=' 'VALKEY_PASSWORD=""' "VALKEY_PASSWORD=''"; do
    old_env
    printf '%s\nTZ=UTC\n' "$empty" >>"$DATA/.env"
    n8n_fill_env "$DATA/.env" >"$BATS_TEST_TMPDIR/out"
    [ "$(grep -c '^VALKEY_PASSWORD=' "$BATS_TEST_TMPDIR/out")" -eq 1 ]
    [[ "$(sed -n 15p "$BATS_TEST_TMPDIR/out")" =~ ^VALKEY_PASSWORD=[0-9a-f]{64}$ ]]
    [ "$(sed -n 16p "$BATS_TEST_TMPDIR/out")" = TZ=UTC ]
  done
  # A value that is set stays as it is, whatever it looks like.
  old_env
  printf 'VALKEY_PASSWORD=x\n' >>"$DATA/.env"
  n8n_fill_env "$DATA/.env" >"$BATS_TEST_TMPDIR/out"
  grep -qxF VALKEY_PASSWORD=x "$BATS_TEST_TMPDIR/out"
  [ "$(grep -c '^VALKEY_PASSWORD=' "$BATS_TEST_TMPDIR/out")" -eq 1 ]
}
