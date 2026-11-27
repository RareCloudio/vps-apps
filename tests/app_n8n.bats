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
  refute_grep -q 'n8n:latest' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl" "$APP_DIR/app.sh"
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
