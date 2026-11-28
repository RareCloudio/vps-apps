#!/usr/bin/env bats
load test_helper

setup() {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  APP_DIR="$ROOT_DIR/apps/grafana"
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
  # shellcheck source=../apps/grafana/app.sh
  . "$APP_DIR/app.sh"
  VA_HOST=g.example.com
  export VA_HOST
  DATA="$(p /opt/vps-apps-data/grafana)"
  CRED="$(p /root/vps-apps-credentials.txt)"
  PWF="$BATS_TEST_TMPDIR/password"
  printf '%s' 'Secret123' >"$PWF"
  export VA_GRAFANA_WAIT=2 VA_GRAFANA_INTERVAL=0
  # The registry serves every tag the stub is asked for, except those that contain this text: by
  # default 13.3 is the newest Grafana 13 release line.
  printf '%s' 'grafana/grafana:13.4' >"$STUB_TMP/inspect_fail_match"
  # The fake Grafana's state: G/pw (the admin password it holds, "admin" after its first start),
  # G/events (every call, in order). Failure injection through files in G.
  G="$BATS_TEST_TMPDIR/grafana"
  mkdir -p "$G"
  printf '%s' admin >"$G/pw"
  : >"$G/events"
  CURL_ARGV="$BATS_TEST_TMPDIR/curl_argv"
  : >"$CURL_ARGV"
  fake_grafana
}

GRAFANA_REPO=grafana/grafana

# digest_of <ref>: the digest the docker stub answers for a tag.
digest_of() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# fake_grafana: docker and curl as functions that behave like the stack does (per the sources of
# Grafana 13.3.2 and Caddy 2.10.2):
#   - "docker compose ... exec -T grafana grafana cli ... admin reset-admin-password
#     --password-from-stdin": reads one line from stdin; under 4 bytes it fails with the password
#     policy message, else it sets the admin password and prints "Admin password changed
#     successfully"; with G/no_admin it prints "Admin user cannot be found" and exits 0, and for the
#     password the admin already has it prints nothing more and exits 0, as the real command does
#     (pkg/cmd/grafana-cli/commands/reset_password_command.go returns nil on every other error);
#   - "docker compose ... exec -T caddy caddy hash-password": reads up to a newline (EOF before one
#     is an error) and prints a bcrypt-shaped hash derived from the input;
#   - curl against Grafana (127.0.0.1:3000: /api/health, /api/user with basic auth, the signup call,
#     /api/org/), Loki's /ready, Prometheus's /-/ready, and the HTTPS ready check.
# Every other docker call goes to the stub on PATH.
fake_grafana() {
  docker() {
    local n
    case "$*" in
      *" exec -T grafana grafana cli "*)
        printf '%s\n' "$*" >>"$STUB_TMP/docker.log"
        printf 'docker reset\n' >>"$G/events"
        n="$(grep -c '^docker reset$' "$G/events")"
        cat >"$G/reset_stdin.$n"
        fake_reset "$G/reset_stdin.$n"
        ;;
      *" exec -T caddy caddy hash-password "*)
        printf '%s\n' "$*" >>"$STUB_TMP/docker.log"
        printf 'docker hash\n' >>"$G/events"
        cat >"$G/hash_stdin"
        fake_hash "$G/hash_stdin"
        ;;
      *)
        printf 'docker %s\n' "$*" >>"$G/events"
        command docker "$@"
        ;;
    esac
  }
  curl() {
    local a prev="" out="" method=GET hdr="" fail=0 wfmt="" body_in=0 url code="" body=""
    printf '%s\n' "$@" >>"$CURL_ARGV"
    for a in "$@"; do
      case "$prev" in
        -o) out="$a" ;;
        -X) method="$a" ;;
        -w) wfmt="$a" ;;
        -H) [[ "$a" != @* ]] || hdr="$(cat "${a#@}")" ;;
      esac
      case "$a" in -f*) fail=1 ;; @-) body_in=1 ;; esac
      prev="$a"
    done
    url="${*: -1}"
    printf 'curl %s %s\n' "$method" "$url" >>"$G/events"
    if [ "$body_in" = 1 ]; then
      cat >"$G/curl_stdin"
    fi
    fake_http "$method" "$url" "$hdr" || return "$?"
    code="$(cat "$G/code")"
    body="$(cat "$G/body")"
    if [ "$fail" = 1 ] && [ "$code" -ge 400 ]; then
      return 22
    fi
    if [ -n "$out" ]; then
      [ "$out" = /dev/null ] || printf '%s' "$body" >"$out"
    else
      printf '%s' "$body"
    fi
    if [ -n "$wfmt" ]; then
      printf '%s' "$code"
    fi
    return 0
  }
}

# fake_reset <stdin-file>: the Grafana CLI's reset-admin-password.
fake_reset() {
  local pw
  if [ -e "$G/reset_fail" ]; then
    echo "Error: ✗ failed to initialize runner: database is locked"
    return 1
  fi
  if [ -e "$G/no_admin" ]; then
    printf 'New Password: \nAdmin user cannot be found ✘. \n'
    return 0
  fi
  # bufio.Scanner: the first line, without its newline.
  pw="$(head -n 1 "$1"; printf x)"
  pw="${pw%x}"
  pw="${pw%$'\n'}"
  if [ "${#pw}" -lt 4 ] || [ -e "$G/reset_reject" ]; then
    echo "Error: ✗ the new password doesn't meet the password policy criteria"
    return 1
  fi
  # The same password again: Grafana's user service refuses it (ErrNewPasswordSameAsOld) and the
  # command swallows that error, so it prints nothing more and exits 0.
  if [ "$pw" = "$(cat "$G/pw")" ]; then
    printf 'New Password: \n\n\n'
    return 0
  fi
  [ -e "$G/reset_ignored" ] || printf '%s' "$pw" >"$G/pw"
  printf 'New Password: \nAdmin password changed successfully ✔\n'
}

# fake_hash <stdin-file>: caddy hash-password reading stdin (bufio ReadBytes up to a newline).
fake_hash() {
  local in
  [ ! -e "$G/hash_fail" ] || return 1
  if [ -e "$G/hash_garbage" ]; then
    echo "not a hash"
    return 0
  fi
  in="$(cat "$1"; printf x)"
  in="${in%x}"
  if [[ "$in" != *$'\n'* ]]; then
    echo "Error: EOF" >&2
    return 1
  fi
  in="${in%%$'\n'*}"
  printf '$2a$10$%s\n' "$(printf '%s' "$in" | sha256sum | cut -c1-53)"
}

# fake_hash_of <password>: the hash fake_hash prints for a password.
fake_hash_of() {
  printf '$2a$10$%s' "$(printf '%s' "$1" | sha256sum | cut -c1-53)"
}

# fake_http <method> <url> <header>: writes the status to G/code and the body to G/body; a return
# code other than 0 is a transport error.
fake_http() {
  local method="$1" url="$2" hdr="$3" user="" pw n
  printf '200' >"$G/code"
  : >"$G/body"
  if [[ "$hdr" =~ ^Authorization:\ Basic\ (.+)$ ]]; then
    user="$(printf '%s' "${BASH_REMATCH[1]}" | base64 -d)"
  fi
  pw="$(cat "$G/pw"; printf x)"
  pw="${pw%x}"
  case "$method $url" in
    "GET http://127.0.0.1:3000/api/health")
      n="$(cat "$G/ready_fail" 2>/dev/null || echo 0)"
      if [ "$n" -gt 0 ]; then
        echo $((n - 1)) >"$G/ready_fail"
        return 7
      fi
      if [ -e "$G/db_failing" ]; then
        printf 503 >"$G/code"
        printf '{"database":"failing","version":"13.3.2"}' >"$G/body"
      else
        printf '%s' "${HEALTH_BODY-{\"database\":\"ok\",\"version\":\"13.3.2\",\"commit\":\"abc\"}}" >"$G/body"
      fi
      ;;
    "GET http://127.0.0.1:3000/api/user")
      if [ -n "$user" ] && [ "$user" = "admin:$pw" ] && [ ! -e "$G/login_broken" ]; then
        printf '{"id":1,"login":"admin","email":"admin@localhost","isGrafanaAdmin":true}' >"$G/body"
      else
        printf 401 >"$G/code"
        printf '{"message":"Invalid username or password"}' >"$G/body"
      fi
      ;;
    "POST http://127.0.0.1:3000/api/user/signup")
      if [ -n "${SIGNUP_CODE:-}" ]; then
        printf '%s' "$SIGNUP_CODE" >"$G/code"
        printf '%s' "${SIGNUP_BODY:-}" >"$G/body"
      else
        printf 401 >"$G/code"
        printf '{"message":"User signup is disabled"}' >"$G/body"
      fi
      ;;
    "GET http://127.0.0.1:3000/api/org/")
      if [ -e "$G/anonymous_on" ]; then
        printf '{"id":1,"name":"Main Org."}' >"$G/body"
      else
        printf 401 >"$G/code"
        printf '{"message":"Unauthorized"}' >"$G/body"
      fi
      ;;
    "GET http://127.0.0.1:3100/ready")
      [ ! -e "$G/loki_down" ] || return 7
      printf 'ready' >"$G/body"
      ;;
    "GET http://127.0.0.1:9090/-/ready")
      [ ! -e "$G/prometheus_down" ] || return 7
      printf 'Prometheus Server is Ready.' >"$G/body"
      ;;
    "GET https://g.example.com/api/health")
      printf '{"database":"ok","version":"13.3.2"}' >"$G/body"
      ;;
    "POST https://g.example.com/loki/api/v1/push")
      printf '%s' "${PUSH_CODE:-401}" >"$G/code"
      ;;
    *)
      printf 404 >"$G/code"
      ;;
  esac
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

# A compose file without its comment lines, which cite docs and name things the YAML must not hold.
yaml_of() {
  grep -v '^\s*#' "$APP_DIR/$1"
}

env_get() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

# --- app_prepare: images, secrets, the ingest credential and the config files ------------------

@test "the .env is mode 600 with every image pinned and its ref, and a second run keeps it byte-identical" {
  app_prepare
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  grep -qxF "GRAFANA_IMAGE=$GRAFANA_REPO@sha256:$(digest_of "$GRAFANA_REPO:13.3")" "$DATA/.env"
  grep -qxF "GRAFANA_IMAGE_REF=$GRAFANA_REPO:13.3" "$DATA/.env"
  grep -qxF "LOKI_IMAGE=grafana/loki@sha256:$(digest_of grafana/loki:3)" "$DATA/.env"
  grep -qxF "LOKI_IMAGE_REF=grafana/loki:3" "$DATA/.env"
  grep -qxF "PROMETHEUS_IMAGE=prom/prometheus@sha256:$(digest_of prom/prometheus:v3)" "$DATA/.env"
  grep -qxF "PROMETHEUS_IMAGE_REF=prom/prometheus:v3" "$DATA/.env"
  grep -qxF "NODE_EXPORTER_IMAGE=prom/node-exporter@sha256:$(digest_of prom/node-exporter:v1)" "$DATA/.env"
  grep -qxF "NODE_EXPORTER_IMAGE_REF=prom/node-exporter:v1" "$DATA/.env"
  grep -qxF "GRAFANA_ROOT_URL=https://g.example.com/" "$DATA/.env"
  grep -qxF 'VA_SITE_ADDRS="g.example.com"' "$DATA/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  cp "$CRED" "$BATS_TEST_TMPDIR/cred1"
  : >"$STUB_TMP/docker.log"
  : >"$G/events"
  app_prepare
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  cmp "$CRED" "$BATS_TEST_TMPDIR/cred1"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  # A re-run resolves nothing and hashes nothing: the pinned digests and the credential stay.
  refute_grep -q imagetools "$STUB_TMP/docker.log"
  refute_grep -qx 'docker hash' "$G/events"
}

@test "the images are the official ones on their major tags, and Grafana on its newest 13.x line, never latest" {
  app_prepare
  [ "$VA_GRAFANA_IMAGE_REF" = "$GRAFANA_REPO:13.3" ]
  [ "$VA_GRAFANA_LOKI_IMAGE_REF" = grafana/loki:3 ]
  [ "$VA_GRAFANA_PROMETHEUS_IMAGE_REF" = prom/prometheus:v3 ]
  [ "$VA_GRAFANA_NODE_EXPORTER_IMAGE_REF" = prom/node-exporter:v1 ]
  grep -qxF "buildx imagetools inspect $GRAFANA_REPO:13.3 --format {{json .Manifest}}" "$STUB_TMP/docker.log"
  grep -qF 'image: ${GRAFANA_IMAGE:-grafana/grafana:13.3}' "$APP_DIR/compose.yml"
  grep -qF 'image: ${LOKI_IMAGE:-grafana/loki:3}' "$APP_DIR/compose.yml"
  grep -qF 'image: ${PROMETHEUS_IMAGE:-prom/prometheus:v3}' "$APP_DIR/compose.yml"
  grep -qF 'image: ${NODE_EXPORTER_IMAGE:-prom/node-exporter:v1}' "$APP_DIR/compose.yml"
  refute_grep -qE ':(latest|main|nightly|next)|-rc\.|grafana-enterprise' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl" "$APP_DIR/app.sh"
}

@test "at install Grafana takes the newest 13.x release line the registry has, and never another major" {
  printf '%s' 'grafana/grafana:13.6' >"$STUB_TMP/inspect_fail_match"
  app_prepare
  grep -qxF "GRAFANA_IMAGE_REF=$GRAFANA_REPO:13.5" "$DATA/.env"
  grep -qxF "GRAFANA_IMAGE=$GRAFANA_REPO@sha256:$(digest_of "$GRAFANA_REPO:13.5")" "$DATA/.env"
  grep -qxF "buildx imagetools inspect $GRAFANA_REPO:13.4 --format {{json .Manifest}}" "$STUB_TMP/docker.log"
  refute_grep -qE "$GRAFANA_REPO:(14|12)" "$STUB_TMP/docker.log"
}

@test "the newer release line lookup is bounded when the registry answers every tag" {
  printf '%s' 'nothing-matches-this' >"$STUB_TMP/inspect_fail_match"
  VA_GRAFANA_MINOR_PROBES=3 app_prepare
  grep -qxF "GRAFANA_IMAGE_REF=$GRAFANA_REPO:13.6" "$DATA/.env"
  [ "$(grep -c "imagetools inspect $GRAFANA_REPO:" "$STUB_TMP/docker.log")" -eq 4 ]
}

@test "an image that cannot be resolved fails app_prepare and leaves no .env and no credentials" {
  : >"$STUB_TMP/inspect_fail"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
  [ ! -e "$CRED" ]
  rm -f "$STUB_TMP/inspect_fail"
  printf '%s' 'prom/node-exporter' >"$STUB_TMP/inspect_fail_match"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
  refute_grep -qx 'docker hash' "$G/events"
}

@test "the Grafana secret key is 64 hex characters made on this server, different on every install" {
  app_prepare
  first="$(env_get "$DATA/.env" GRAFANA_SECRET_KEY)"
  [[ "$first" =~ ^[0-9a-f]{64}$ ]]
  rm -rf "$VPS_APPS_ROOT"
  mkdir -p "$VPS_APPS_ROOT"
  app_prepare
  [ "$(env_get "$DATA/.env" GRAFANA_SECRET_KEY)" != "$first" ]
}

@test "the Loki push credential: generated here, hashed by the proxy's caddy from stdin, plain only in the 0600 credentials file" {
  app_prepare
  [ "$(stat -c %a "$CRED")" = 600 ]
  pw="$(sed -n 's/^Loki push password: //p' "$CRED")"
  [[ "$pw" =~ ^[0-9a-f]{48}$ ]]
  grep -qxF 'Loki push URL: https://g.example.com/loki/api/v1/push' "$CRED"
  grep -qxF 'Loki push username: loki' "$CRED"
  # No "Password: " line: that one is only for a generated Grafana admin password.
  refute_grep -q '^Password: ' "$CRED"
  # The hash, single-quoted so compose takes its dollar signs literally.
  grep -qxF "LOKI_PUSH_HASH='$(fake_hash_of "$pw")'" "$DATA/.env"
  # caddy hash-password in the running proxy container, the password on stdin with the newline it
  # reads up to, at a bcrypt cost that keeps a flood of wrong passwords cheap.
  proxy="$(p /opt/vps-apps-data/proxy)"
  grep -qxF "compose -f $proxy/compose.yml --env-file $proxy/.env exec -T caddy caddy hash-password --bcrypt-cost 10" "$STUB_TMP/docker.log"
  [ "$(cat "$G/hash_stdin")" = "$pw" ]
  [ "$(tail -c 1 "$G/hash_stdin" | od -An -tx1 | tr -d ' ')" = 0a ]
  refute_grep -qF "$pw" "$STUB_TMP/docker.log" "$CURL_ARGV" "$DATA/.env" "$APP_DIR"/compose*.yml
  refute_grep -rqF "$pw" "$DATA" "$(p /var/log/vps-apps-install.log)"
}

@test "a hash that fails or does not look like bcrypt fails app_prepare and writes no .env" {
  : >"$G/hash_fail"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
  rm -f "$G/hash_fail"
  : >"$G/hash_garbage"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
}

@test "a re-run without .env reuses the Loki password already in the credentials file and keeps the admin section" {
  mkdir -p "$(dirname "$CRED")"
  {
    printf 'Loki push password: %s\n' "$(printf 'a%.0s' $(seq 48))"
    printf '\nGrafana admin login, generated because the password you chose does not meet Grafana rules\n'
    printf 'Username: admin\nPassword: Rc9%s\n' "$(printf 'b%.0s' $(seq 32))"
  } >"$CRED"
  app_prepare
  [ "$(cat "$G/hash_stdin")" = "$(printf 'a%.0s' $(seq 48))" ]
  grep -qxF "Loki push password: $(printf 'a%.0s' $(seq 48))" "$CRED"
  grep -qxF "Password: Rc9$(printf 'b%.0s' $(seq 32))" "$CRED"
  grep -qxF 'Username: admin' "$CRED"
  [ "$(stat -c %a "$CRED")" = 600 ]
}

@test "VA_SITE_ADDRS has the host, then the valid extra domains; invalid ones are dropped" {
  mkdir -p "$(p /etc/vps-apps)"
  printf 'logs.example.org\nnot a domain\n$(id).example.net\ng.example.com\n' >"$(p /etc/vps-apps/domains)"
  app_prepare
  grep -qxF 'VA_SITE_ADDRS="g.example.com logs.example.org"' "$DATA/.env"
}

@test "the template substitution is literal for a value with an ampersand and a backslash" {
  resolve_image_digest() { printf '%s\n' 'x/y&z\w@sha256:abc'; }
  app_prepare
  grep -qxF 'LOKI_IMAGE=x/y&z\w@sha256:abc' "$DATA/.env"
}

@test "the config files are copied to the data dir on every run, readable by the containers' users" {
  app_prepare
  c="$DATA/config"
  cmp "$c/loki/loki.yaml" "$APP_DIR/loki.yaml"
  cmp "$c/prometheus/prometheus.yml" "$APP_DIR/prometheus.yml"
  cmp "$c/prometheus/prometheus-agent.yml" "$APP_DIR/prometheus-agent.yml"
  cmp "$c/grafana/datasources/vps-apps.yaml" "$APP_DIR/provisioning/datasources.yaml"
  cmp "$c/grafana/providers/vps-apps.yaml" "$APP_DIR/provisioning/dashboards.yaml"
  cmp "$c/grafana/dashboards/server.json" "$APP_DIR/dashboards/server.json"
  for f in loki/loki.yaml prometheus/prometheus.yml prometheus/prometheus-agent.yml \
    grafana/datasources/vps-apps.yaml grafana/providers/vps-apps.yaml grafana/dashboards/server.json; do
    [ "$(stat -c %a "$c/$f")" = 644 ]
  done
  # A later run puts back what the code holds, while the .env stays.
  printf 'changed' >"$c/loki/loki.yaml"
  app_prepare
  cmp "$c/loki/loki.yaml" "$APP_DIR/loki.yaml"
}

# --- the compose files --------------------------------------------------------------------------

@test "the compose files are the base and setup ones, then the base and expose ones once the marker exists" {
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

@test "every published port is on loopback, and nothing joins the proxy network or carries a label before exposure" {
  refute_grep -qi 'caddy' <(yaml_of compose.setup.yml) <(yaml_of compose.yml)
  refute_grep -qE '^\s+- web$|external: true' "$APP_DIR/compose.setup.yml" "$APP_DIR/compose.yml"
  # Every port mapping in every file names 127.0.0.1.
  n=0
  while IFS= read -r line; do
    [[ "$line" =~ ^\ +-\ \"127\.0\.0\.1:[0-9]+:[0-9]+\"$ ]]
    n=$((n + 1))
  done < <(grep -hE '^\s+- "?[0-9.:\[]*:?[0-9]+"?$' "$APP_DIR"/compose*.yml)
  [ "$n" -eq 3 ]
  refute_grep -qE '^\s+ports:' "$APP_DIR/compose.expose.yml"
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '[.services[] | (.ports // [])[] | .host_ip] | unique | join(",")' <<<"$cfg")" = 127.0.0.1 ]
  [ "$(jq -r '.services.grafana.ports[0] | "\(.host_ip):\(.published):\(.target)"' <<<"$cfg")" = "127.0.0.1:3000:3000" ]
  [ "$(jq -r '.services.loki.ports[0] | "\(.host_ip):\(.published):\(.target)"' <<<"$cfg")" = "127.0.0.1:3100:3100" ]
  [ "$(jq -r '.services.prometheus.ports[0] | "\(.host_ip):\(.published):\(.target)"' <<<"$cfg")" = "127.0.0.1:9090:9090" ]
  [ "$(jq -r '[.services[] | (.labels // {}) | length] | add' <<<"$cfg")" = 0 ]
  [ "$(jq -r '.services.grafana.networks | keys | join(",")' <<<"$cfg")" = default ]
  [ "$(jq -r '.services.loki.networks | keys | join(",")' <<<"$cfg")" = default ]
  # Before exposure Grafana may make its first admin (with its default password, replaced next).
  [ "$(jq -r '.services.grafana.environment.GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION // "unset"' <<<"$cfg")" = unset ]
}

@test "the expose override joins Grafana and Loki to web with the labels, and publishes only Prometheus on loopback" {
  mkdir -p "$(p /etc/vps-apps)"
  printf 'logs.example.org\n' >"$(p /etc/vps-apps/domains)"
  app_prepare
  cfg="$(merged_config compose.yml compose.expose.yml)"
  [ "$(jq -r '.services.grafana.networks | keys | join(",")' <<<"$cfg")" = "default,web" ]
  [ "$(jq -r '.services.loki.networks | keys | join(",")' <<<"$cfg")" = "default,web" ]
  [ "$(jq -r '.services.prometheus.networks | keys | join(",")' <<<"$cfg")" = default ]
  [ "$(jq -r '.networks.web.external' <<<"$cfg")" = true ]
  [ "$(jq -r '.services.grafana.labels.caddy' <<<"$cfg")" = "g.example.com logs.example.org" ]
  [ "$(jq -r '.services.grafana.labels["caddy.reverse_proxy"]' <<<"$cfg")" = "{{upstreams 3000}}" ]
  [ "$(jq -r '.services.grafana.labels["caddy.reverse_proxy.header_up"]' <<<"$cfg")" = "X-Real-IP {remote_host}" ]
  [ "$(jq -r '.services.loki.labels.caddy' <<<"$cfg")" = "g.example.com logs.example.org" ]
  [ "$(jq -r '.services.loki.labels["caddy.handle"]' <<<"$cfg")" = /loki/api/v1/push ]
  [ "$(jq -r '.services.loki.labels["caddy.handle.reverse_proxy"]' <<<"$cfg")" = "{{upstreams 3100}}" ]
  # docker compose config writes a literal dollar sign as $$.
  hash="$(sed -n "s/^LOKI_PUSH_HASH='\(.*\)'$/\1/p" "$DATA/.env")"
  [ "$(jq -r '.services.loki.labels["caddy.handle.basic_auth.loki"] | gsub("\\$\\$"; "$")' <<<"$cfg")" = "$hash" ]
  # Exactly those label keys, nothing that would route another Loki path.
  [ "$(jq -r '.services.loki.labels | keys | join(" ")' <<<"$cfg")" = "caddy caddy.handle caddy.handle.basic_auth.loki caddy.handle.reverse_proxy" ]
  [ "$(jq -r '[.services[] | (.ports // [])[] | "\(.host_ip):\(.published)"] | join(",")' <<<"$cfg")" = "127.0.0.1:9090" ]
  [ "$(jq -r '.services.grafana.environment.GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION' <<<"$cfg")" = true ]
}

@test "the push route is the exact Loki push path behind basic auth, and the labels carry no scheme or port" {
  grep -qxF '      caddy.handle: /loki/api/v1/push' "$APP_DIR/compose.expose.yml"
  grep -qxF '      caddy.handle.basic_auth.loki: ${LOKI_PUSH_HASH:?LOKI_PUSH_HASH is not set}' "$APP_DIR/compose.expose.yml"
  grep -qxF '      caddy.handle.reverse_proxy: "{{upstreams 3100}}"' "$APP_DIR/compose.expose.yml"
  [ "$(grep -c '^      caddy: ${VA_SITE_ADDRS:?VA_SITE_ADDRS is not set}$' "$APP_DIR/compose.expose.yml")" -eq 2 ]
  # No wildcard and no other Loki path anywhere in the labels.
  refute_grep -qE 'loki/api/v1/(push\*|push/|query|tail|label|series|index|delete)|/loki/\*|/loki\*' <(yaml_of compose.expose.yml)
  refute_grep -qE 'https?://|:443' <(yaml_of compose.expose.yml)
  # Loki's own config keeps the tenant API off; the proxy is the only gate.
  grep -qxF 'auth_enabled: false' "$APP_DIR/loki.yaml"
}

@test "node-exporter and the agent run in the host's network namespace, listening on loopback only" {
  app_prepare
  grep -qF -- '- --web.listen-address=127.0.0.1:9100' "$APP_DIR/compose.yml"
  grep -qF -- '- --web.listen-address=127.0.0.1:9091' "$APP_DIR/compose.yml"
  grep -qF -- '- --path.rootfs=/host' "$APP_DIR/compose.yml"
  grep -qF -- '- /:/host:ro,rslave' "$APP_DIR/compose.yml"
  cfg="$(merged_config compose.yml compose.expose.yml)"
  [ "$(jq -r '.services["node-exporter"].network_mode' <<<"$cfg")" = host ]
  [ "$(jq -r '.services["node-exporter"].pid' <<<"$cfg")" = host ]
  [ "$(jq -r '.services["node-exporter"].volumes[0] | "\(.target) \(.read_only)"' <<<"$cfg")" = "/host true" ]
  [ "$(jq -r '.services["prometheus-agent"].network_mode' <<<"$cfg")" = host ]
  [ "$(jq -r '[.services["node-exporter"], .services["prometheus-agent"]] | map(.ports // [] | length) | add' <<<"$cfg")" = 0 ]
  # The main Prometheus takes the agent's writes; its admin API stays off.
  grep -qF -- '- --web.enable-remote-write-receiver' "$APP_DIR/compose.yml"
  refute_grep -qE 'enable-admin-api|enable-lifecycle' "$APP_DIR/compose.yml"
}

@test "Grafana's settings: the root URL, the secret key, no signup, no anonymous access, secure cookies, no public metrics" {
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  env='.services.grafana.environment'
  [ "$(jq -r "$env.GF_SERVER_ROOT_URL" <<<"$cfg")" = https://g.example.com/ ]
  [ "$(jq -r "$env.GF_SECURITY_SECRET_KEY" <<<"$cfg")" = "$(env_get "$DATA/.env" GRAFANA_SECRET_KEY)" ]
  [ "$(jq -r "$env.GF_SECURITY_ADMIN_USER" <<<"$cfg")" = admin ]
  [ "$(jq -r "$env.GF_USERS_ALLOW_SIGN_UP" <<<"$cfg")" = false ]
  [ "$(jq -r "$env.GF_USERS_ALLOW_ORG_CREATE" <<<"$cfg")" = false ]
  [ "$(jq -r "$env.GF_AUTH_ANONYMOUS_ENABLED" <<<"$cfg")" = false ]
  [ "$(jq -r "$env.GF_SECURITY_COOKIE_SECURE" <<<"$cfg")" = true ]
  [ "$(jq -r "$env.GF_METRICS_ENABLED" <<<"$cfg")" = false ]
  [ "$(jq -r "$env.GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH" <<<"$cfg")" = /etc/grafana/vps-apps-dashboards/server.json ]
  [ "$(jq -r '.services.grafana.volumes[] | select(.type == "volume") | "\(.source):\(.target)"' <<<"$cfg")" = grafana_data:/var/lib/grafana ]
  [ "$(jq -r '[.services.grafana.volumes[] | select(.type == "bind") | "\(.target):\(.read_only)"] | join(" ")' <<<"$cfg")" = \
    "/etc/grafana/provisioning/datasources:true /etc/grafana/provisioning/dashboards:true /etc/grafana/vps-apps-dashboards:true" ]
}

@test "no compose or env file carries an admin password, and nothing turns signup or anonymous access on" {
  refute_grep -qiE 'ADMIN_PASSWORD|__FILE|PASSWORD' <(yaml_of compose.yml) <(yaml_of compose.setup.yml) <(yaml_of compose.expose.yml) "$APP_DIR/env.tmpl"
  refute_grep -qE 'ALLOW_SIGN_UP: "true"|ANONYMOUS_ENABLED: "true"|password_policy|DISABLE_LOGIN_FORM|AUTH_PROXY' "$APP_DIR"/compose*.yml
  refute_grep -qE 'BRUTE_FORCE' "$APP_DIR"/compose*.yml
}

@test "the memory limits keep the stack inside the 2 GB plan" {
  total=0
  for m in $(sed -n 's/^    mem_limit: \([0-9]*\)m$/\1/p' "$APP_DIR/compose.yml"); do
    total=$((total + m))
  done
  [ "$(grep -c '^    mem_limit: ' "$APP_DIR/compose.yml")" -eq 5 ]
  [ "$total" -le 1750 ]
}

# --- the config files ---------------------------------------------------------------------------

@test "Loki keeps 15 days of logs on the filesystem, in single binary mode" {
  grep -qxF '  retention_enabled: true' "$APP_DIR/loki.yaml"
  grep -qxF '  delete_request_store: filesystem' "$APP_DIR/loki.yaml"
  grep -qxF '  retention_period: 360h' "$APP_DIR/loki.yaml"
  grep -qxF '      schema: v13' "$APP_DIR/loki.yaml"
  grep -qxF '      store: tsdb' "$APP_DIR/loki.yaml"
  grep -qxF '        period: 24h' "$APP_DIR/loki.yaml"
  grep -qxF '  path_prefix: /loki' "$APP_DIR/loki.yaml"
  grep -qxF '  http_listen_port: 3100' "$APP_DIR/loki.yaml"
  grep -qF '"-config.file=/etc/loki/vps-apps/loki.yaml"' "$APP_DIR/compose.yml"
}

@test "Loki's ingestion limits keep one customer's servers from filling a small disk" {
  # Each key once, in limits_config, with the value sized for a small VPS.
  limits="$(sed -n '/^limits_config:$/,/^[^ ]/p' "$APP_DIR/loki.yaml")"
  for want in '  ingestion_rate_mb: 4' '  ingestion_burst_size_mb: 8' '  per_stream_rate_limit: 3MB' \
    '  per_stream_rate_limit_burst: 6MB' '  max_global_streams_per_user: 5000' '  retention_period: 360h'; do
    [ "$(grep -cxF "$want" <<<"$limits")" -eq 1 ]
    key="${want#  }"
    [ "$(grep -c "^  ${key%%:*}:" "$APP_DIR/loki.yaml")" -eq 1 ]
  done
}

@test "Prometheus keeps 15 days and at most 4 GB, scrapes itself, and the agent sends node-exporter's metrics to it" {
  grep -qxF '      time: 15d' "$APP_DIR/prometheus.yml"
  grep -qxF '      size: 4GB' "$APP_DIR/prometheus.yml"
  grep -qxF '      - targets: ["localhost:9090"]' "$APP_DIR/prometheus.yml"
  grep -qxF '  - job_name: node' "$APP_DIR/prometheus-agent.yml"
  grep -qxF '      - targets: ["127.0.0.1:9100"]' "$APP_DIR/prometheus-agent.yml"
  grep -qxF '  - url: http://127.0.0.1:9090/api/v1/write' "$APP_DIR/prometheus-agent.yml"
  grep -qF -- '- --config.file=/etc/prometheus/vps-apps/prometheus.yml' "$APP_DIR/compose.yml"
  grep -qF -- '- --config.file=/etc/prometheus/vps-apps/prometheus-agent.yml' "$APP_DIR/compose.yml"
  grep -qF -- '- --agent' "$APP_DIR/compose.yml"
}

@test "the data sources and the starter dashboard are provisioned from files, with fixed UIDs" {
  f="$APP_DIR/provisioning/datasources.yaml"
  grep -qxF '    uid: vps-apps-prometheus' "$f"
  grep -qxF '    url: http://prometheus:9090' "$f"
  grep -qxF '    uid: vps-apps-loki' "$f"
  grep -qxF '    url: http://loki:3100' "$f"
  [ "$(grep -c '^    access: proxy$' "$f")" -eq 2 ]
  [ "$(grep -c '^    editable: false$' "$f")" -eq 2 ]
  grep -qxF '      path: /etc/grafana/vps-apps-dashboards' "$APP_DIR/provisioning/dashboards.yaml"
  d="$APP_DIR/dashboards/server.json"
  jq -e '.uid == "vps-apps-server" and (.panels | length) >= 8' "$d" >/dev/null
  # Every panel and query reads the provisioned Prometheus.
  [ "$(jq -r '[.panels[] | .datasource.uid, (.targets[] | .datasource.uid)] | unique | join(",")' "$d")" = vps-apps-prometheus ]
  jq -e '[.panels[].targets[].expr] | all(test("job=\\\"node\\\""))' "$d" >/dev/null
}

# --- app_up_setup and app_create_admin ------------------------------------------------------------

@test "app_up_setup starts the stack with the setup file and exposes nothing" {
  app_prepare
  app_up_setup
  grep -qxF "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.setup.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
  [ ! -e "$DATA/exposed" ]
  [ ! -e "$(p /var/lib/vps-apps/site-mode)" ]
}

@test "the admin password is set by Grafana's own CLI with the password on stdin, then proven by a loopback login" {
  app_prepare
  printf '%s' 'P@ss"w\0rd $x`y;1A' >"$PWF"
  app_create_admin "$PWF"
  grep -qxF "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.setup.yml --env-file $DATA/.env exec -T grafana grafana cli --homepath /usr/share/grafana admin reset-admin-password --password-from-stdin" "$STUB_TMP/docker.log"
  cmp "$G/reset_stdin.1" "$PWF"
  [ "$(cat "$G/pw")" = "$(cat "$PWF")" ]
  # The order: health, the CLI, then the login with the new password.
  [ "$(grep -E '^(curl GET http://127.0.0.1:3000/api/(health|user)|docker reset)$' "$G/events" | uniq | tr '\n' ' ')" = \
    "curl GET http://127.0.0.1:3000/api/health docker reset curl GET http://127.0.0.1:3000/api/user " ]
  # The password and its basic credential are on no command line and in no file of ours.
  b64="$(printf 'admin:%s' "$(cat "$PWF")" | base64 -w0)"
  refute_grep -qF 'P@ss' "$STUB_TMP/docker.log" "$CURL_ARGV" "$DATA/.env"
  refute_grep -qF "$b64" "$CURL_ARGV"
  refute_grep -qxE -- '-u|--user' "$CURL_ARGV"
  refute_grep -q '^Password: ' "$CRED"
  # No work file is left behind.
  [ "$(find "$DATA" -maxdepth 1 -name '.admin.*' | wc -l)" -eq 0 ]
}

@test "the password never lands in the .env, a compose file, the install log or a docker argument" {
  app_prepare
  app_create_admin "$PWF"
  refute_grep -qF 'Secret123' "$DATA/.env" "$STUB_TMP/docker.log" "$CURL_ARGV" "$APP_DIR"/compose*.yml "$CRED"
  refute_grep -qF 'Secret123' "$(p /var/log/vps-apps-install.log)"
  [ "$(cat "$G/reset_stdin.1")" = Secret123 ]
}

@test "app_create_admin waits for Grafana's health on loopback before the CLI" {
  app_prepare
  echo 2 >"$G/ready_fail"
  app_create_admin "$PWF"
  [ "$(grep -cxF 'curl GET http://127.0.0.1:3000/api/health' "$G/events")" -eq 3 ]
  [ "$(grep -cx 'docker reset' "$G/events")" -eq 1 ]
}

@test "app_create_admin fails, bounded, when Grafana never answers or its database fails, and runs no CLI" {
  app_prepare
  echo 999 >"$G/ready_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  # Each attempt is bounded too (curl records one argument per line).
  grep -A1 -xF -- '--max-time' "$CURL_ARGV" | grep -qx 30
  rm -f "$G/ready_fail"
  : >"$G/db_failing"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  for body in '' 'Not found' '{"database":"failing"}' '{"status":"ok"}'; do
    rm -f "$G/db_failing"
    HEALTH_BODY="$body" run app_create_admin "$PWF"
    [ "$status" -ne 0 ]
  done
  refute_grep -qx 'docker reset' "$G/events"
}

@test "a CLI that fails, or exits 0 without the password in place, fails the step" {
  app_prepare
  : >"$G/reset_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  rm -f "$G/reset_fail"
  # The real command exits 0 when user 1 is not an admin it can find: the login check stops it.
  : >"$G/no_admin"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  [ "$(cat "$G/pw")" = admin ]
}

@test "the CLI's silent exit 0 for a password the admin already has counts once the login proves it" {
  app_prepare
  printf '%s' Secret123 >"$G/pw"
  app_create_admin "$PWF"
  [ "$(grep -cx 'docker reset' "$G/events")" -eq 1 ]
  [ "$(grep -cxF 'curl GET http://127.0.0.1:3000/api/user' "$G/events")" -eq 1 ]
}

@test "the login check stops a password that did not take" {
  app_prepare
  : >"$G/reset_ignored"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  rm -f "$G/reset_ignored"
  : >"$G/login_broken"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
}

@test "a retry after a failed CLI call sends the same password again and succeeds" {
  app_prepare
  : >"$G/reset_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  rm -f "$G/reset_fail"
  app_create_admin "$PWF"
  app_create_admin "$PWF"
  [ "$(grep -cx 'docker reset' "$G/events")" -eq 3 ]
  [ "$(cat "$G/pw")" = Secret123 ]
  [ "$(cat "$G/reset_stdin.3")" = Secret123 ]
}

@test "a password Grafana cannot take falls back to a generated one, next to the Loki credential" {
  app_prepare
  loki="$(sed -n 's/^Loki push password: //p' "$CRED")"
  for bad in abc admin 'Pässword1x' $'Tab\tPass1word' $'two\nlines1A' ''; do
    app_prepare
    sed -i '/^$/,$d' "$CRED"
    printf '%s' "$bad" >"$PWF"
    app_create_admin "$PWF"
    [ "$(stat -c %a "$CRED")" = 600 ]
    sent="$(cat "$G/pw")"
    [ "$sent" != "$bad" ]
    [[ "${#sent}" -ge 12 && "$sent" =~ [A-Z] && "$sent" =~ [a-z] && "$sent" =~ [0-9] ]]
    grep -qxF "Password: $sent" "$CRED"
    grep -qxF 'Username: admin' "$CRED"
    # The Loki credential is still there, unchanged.
    grep -qxF "Loki push password: $loki" "$CRED"
  done
}

@test "passwords Grafana takes are sent as they are, including every order-form password" {
  app_prepare
  # The e2e password (tests/e2e/README.md) is among them.
  for good in abcd 'Abcdefg1' $'Ab1$"\x60\x27\\ x' "A1$(printf 'x%.0s' $(seq 62))" '!"#$%&()*+,-./:;<=>?@[\]^_`{|}~1A' ' sp ace 1A '; do
    printf '%s' "$good" >"$PWF"
    app_create_admin "$PWF"
    [ "$(cat "$G/pw")" = "$good" ]
    refute_grep -q '^Password: ' "$CRED"
  done
}

@test "Grafana refusing the password triggers the fallback and a second CLI call; a second refusal fails" {
  app_prepare
  : >"$G/reset_reject"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  [ "$(grep -cx 'docker reset' "$G/events")" -eq 2 ]
  rm -f "$G/reset_reject"
  sed -i '/^$/,$d' "$CRED"
  : >"$G/events"
  # Refused once, then the generated password is taken.
  real_reset="$(declare -f fake_reset)"
  eval "${real_reset/fake_reset ()/fake_reset_real ()}"
  fake_reset() {
    if [ ! -e "$G/rejected_once" ]; then
      : >"$G/rejected_once"
      echo "Error: ✗ the new password doesn't meet the password policy criteria"
      return 1
    fi
    fake_reset_real "$@"
  }
  app_create_admin "$PWF"
  sent="$(cat "$G/pw")"
  [ "$sent" != Secret123 ]
  grep -qxF "Password: $sent" "$CRED"
  [ "$(grep -cx 'docker reset' "$G/events")" -eq 2 ]
}

@test "a retry after a fallback uses the generated password already in the credentials file" {
  app_prepare
  printf '%s' 'abc' >"$PWF"
  : >"$G/reset_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  cp "$CRED" "$BATS_TEST_TMPDIR/cred1"
  first="$(sed -n 's/^Password: //p' "$CRED")"
  [ -n "$first" ]
  rm -f "$G/reset_fail"
  # Even a password Grafana would take now: the file holds the login that works.
  printf '%s' 'Secret123' >"$PWF"
  app_create_admin "$PWF"
  cmp "$CRED" "$BATS_TEST_TMPDIR/cred1"
  [ "$(cat "$G/pw")" = "$first" ]
}

# --- app_expose ---------------------------------------------------------------------------------

@test "app_expose brings the setup stack up, checks the stack and its locks on loopback, then exposes" {
  app_prepare
  app_create_admin "$PWF"
  : >"$DATA/exposed"
  : >"$G/events"
  app_expose
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
  order="$(grep -nE 'compose.setup.yml --env-file .* up -d$|/api/health$|3100/ready$|9090/-/ready$|/api/user$|/api/user/signup$|/api/org/$|compose.expose.yml --env-file .* up -d$' "$G/events" | cut -d: -f2- |
    sed -E 's#^docker .*compose.setup.yml.*#setup#; s#^docker .*compose.expose.yml.*#expose#; s#^curl [A-Z]+ ##' | uniq | tr '\n' ' ')"
  [ "$order" = "setup http://127.0.0.1:3000/api/health http://127.0.0.1:3100/ready http://127.0.0.1:9090/-/ready http://127.0.0.1:3000/api/user http://127.0.0.1:3000/api/user/signup http://127.0.0.1:3000/api/org/ expose " ]
  # The default password was tried, once, and refused; the signup probe sends no real address.
  [ "$(grep -cxF 'curl GET http://127.0.0.1:3000/api/user' "$G/events")" -eq 1 ]
  jq -e '.email | test("@") | not' "$G/curl_stdin" >/dev/null
  [ "$(find "$DATA" -maxdepth 1 -name '.expose.*' | wc -l)" -eq 0 ]
}

@test "app_expose refuses while the default admin password still logs in, and changes nothing" {
  app_prepare
  : >"$STUB_TMP/docker.log"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ ! -e "$(p /var/lib/vps-apps/site-mode)" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
}

@test "app_expose refuses when signup is open or its answer cannot be read" {
  app_prepare
  app_create_admin "$PWF"
  for c in "400|{\"message\":\"Invalid email address\"}" "200|{\"message\":\"SignUpCreated\"}" "401|{\"message\":\"Unauthorized\"}" "401|" "500|boom"; do
    SIGNUP_CODE="${c%%|*}" SIGNUP_BODY="${c#*|}" run app_expose
    [ "$status" -ne 0 ]
    [ ! -e "$DATA/exposed" ]
  done
}

@test "app_expose refuses when anonymous access is on" {
  app_prepare
  app_create_admin "$PWF"
  : >"$G/anonymous_on"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
}

@test "app_expose fails without exposing when Grafana, Loki or Prometheus never answers" {
  app_prepare
  app_create_admin "$PWF"
  for f in loki_down prometheus_down; do
    : >"$G/$f"
    run app_expose
    [ "$status" -ne 0 ]
    [ ! -e "$DATA/exposed" ]
    rm -f "$G/$f"
  done
  echo 999 >"$G/ready_fail"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
}

@test "a failed start in app_expose takes the stack down, drops the marker and shows the failed page" {
  app_prepare
  app_create_admin "$PWF"
  real_docker_fn="$(declare -f docker)"
  eval "${real_docker_fn/docker ()/grafana_docker ()}"
  docker() {
    printf '%s\n' "$*" >>"$STUB_TMP/docker_calls"
    [[ "$*" != *compose.expose.yml*" up"* ]] || return 1
    grafana_docker "$@"
  }
  run app_expose
  [ "$status" -ne 0 ]
  grep -q ' down' "$STUB_TMP/docker_calls"
  [ ! -e "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
}

@test "a failed expose followed by a retry recovers, and the retry still refuses with the default password" {
  app_prepare
  app_create_admin "$PWF"
  real_docker_fn="$(declare -f docker)"
  eval "${real_docker_fn/docker ()/grafana_docker ()}"
  docker() {
    if [[ "$*" == *compose.expose.yml*" up"* ]] && [ ! -e "$BATS_TEST_TMPDIR/expose_failed_once" ]; then
      : >"$BATS_TEST_TMPDIR/expose_failed_once"
      return 1
    fi
    grafana_docker "$@"
  }
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
  # Grafana back on its default password: the retry brings the setup stack up and refuses.
  cp "$G/pw" "$BATS_TEST_TMPDIR/pw"
  printf '%s' admin >"$G/pw"
  : >"$STUB_TMP/docker.log"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  grep -q "compose.setup.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
  cp "$BATS_TEST_TMPDIR/pw" "$G/pw"
  : >"$STUB_TMP/docker.log"
  run app_expose
  [ "$status" -eq 0 ]
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
  grep -q "compose.setup.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
}

# --- app_ready_check, extra domains, rc update -------------------------------------------------

@test "app_ready_check needs Grafana healthy over HTTPS on the server's own name, and the push path asking for credentials" {
  app_ready_check
  grep -qF -- '-fsS' "$CURL_ARGV"
  grep -qxF -- '--resolve' "$CURL_ARGV"
  grep -qxF 'g.example.com:443:127.0.0.1' "$CURL_ARGV"
  grep -qxF 'https://g.example.com/api/health' "$CURL_ARGV"
  grep -qxF 'https://g.example.com/loki/api/v1/push' "$CURL_ARGV"
  # The push path answering anything but 401 (no route, or no auth) is not ready.
  for code in 404 200 204 502; do
    PUSH_CODE="$code" run app_ready_check
    [ "$status" -ne 0 ]
  done
  # A failing database, any other answer, and a curl failure (a bad certificate) are not ready.
  for body in '{"database":"failing"}' 'Your Docker server is ready' ''; do
    curl() { printf '%s' "$body"; }
    run app_ready_check
    [ "$status" -ne 0 ]
  done
  curl() { printf '%s' '{"database":"ok"}'; return 60; }
  run app_ready_check
  [ "$status" -ne 0 ]
}

@test "app_domain_added serves every name, moves the root URL to the newest, keeps every other line and recreates the stack" {
  app_prepare
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  mkdir -p "$(p /etc/vps-apps)"
  printf 'logs.example.org\n' >"$(p /etc/vps-apps/domains)"
  : >"$DATA/exposed"
  : >"$STUB_TMP/docker.log"
  app_domain_added logs.example.org
  grep -qxF 'VA_SITE_ADDRS="g.example.com logs.example.org"' "$DATA/.env"
  grep -qxF 'GRAFANA_ROOT_URL=https://logs.example.org/' "$DATA/.env"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  diff <(grep -vE '^(VA_SITE_ADDRS|GRAFANA_ROOT_URL)=' "$BATS_TEST_TMPDIR/before") <(grep -vE '^(VA_SITE_ADDRS|GRAFANA_ROOT_URL)=' "$DATA/.env")
  grep -qxF "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.expose.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
  printf 'logs.example.org\ntwo.example.org\n' >"$(p /etc/vps-apps/domains)"
  app_domain_added two.example.org
  grep -qxF 'VA_SITE_ADDRS="g.example.com logs.example.org two.example.org"' "$DATA/.env"
  grep -qxF 'GRAFANA_ROOT_URL=https://two.example.org/' "$DATA/.env"
  # An invalid name leaves the root URL on the server's own name.
  app_domain_added 'bad name'
  grep -qxF 'GRAFANA_ROOT_URL=https://g.example.com/' "$DATA/.env"
}

@test "Grafana defines no app_domain_check, so rc domain add accepts extra domains" {
  run declare -F app_domain_check
  [ "$status" -ne 0 ]
}

@test "rc update re-resolves every tag and moves Grafana to its newest 13.x release line, never to another major" {
  app_prepare
  printf '%s' 'grafana/grafana:13.6' >"$STUB_TMP/inspect_fail_match"
  : >"$STUB_TMP/docker.log"
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  out="$BATS_TEST_TMPDIR/out"
  grep -qxF "GRAFANA_IMAGE_REF=$GRAFANA_REPO:13.5" "$out"
  grep -qxF "GRAFANA_IMAGE=$GRAFANA_REPO@sha256:$(digest_of "$GRAFANA_REPO:13.5")" "$out"
  grep -qxF "LOKI_IMAGE_REF=grafana/loki:3" "$out"
  grep -qxF "PROMETHEUS_IMAGE_REF=prom/prometheus:v3" "$out"
  grep -qxF "NODE_EXPORTER_IMAGE_REF=prom/node-exporter:v1" "$out"
  [[ "$output" == *"Grafana moves to the 13.5 release line"* ]]
  refute_grep -qE "$GRAFANA_REPO:(14|12)" "$STUB_TMP/docker.log"
  # The .env itself is not written, and every other line is kept.
  grep -qxF "GRAFANA_IMAGE_REF=$GRAFANA_REPO:13.3" "$DATA/.env"
  diff <(grep -v '_IMAGE' "$DATA/.env") <(grep -v '_IMAGE' "$out")
}

@test "rc update stays on the installed release line when there is no newer one, and says nothing" {
  app_prepare
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qxF "GRAFANA_IMAGE_REF=$GRAFANA_REPO:13.3" "$BATS_TEST_TMPDIR/out"
}

@test "rc update leaves a Grafana tag set by hand as it resolved it, and fails when an image cannot be resolved" {
  app_prepare
  sed -i "s#^GRAFANA_IMAGE_REF=.*#GRAFANA_IMAGE_REF=$GRAFANA_REPO:13.3.1#" "$DATA/.env"
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  grep -qxF "GRAFANA_IMAGE_REF=$GRAFANA_REPO:13.3.1" "$BATS_TEST_TMPDIR/out"
  grep -qxF "GRAFANA_IMAGE=$GRAFANA_REPO@sha256:$(digest_of "$GRAFANA_REPO:13.3.1")" "$BATS_TEST_TMPDIR/out"
  printf '%s' 'grafana/loki' >"$STUB_TMP/inspect_fail_match"
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out2"
  [ "$status" -ne 0 ]
}
