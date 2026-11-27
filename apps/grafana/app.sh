#!/usr/bin/env bash
# The "grafana" app: Grafana with Loki for logs, Prometheus for metrics and node-exporter for this
# server's own metrics. Sourced by install.sh and by rc, never executed. It implements the hook
# contract described in apps/docker/app.sh.
#
# The order that matters: the stack starts with Grafana and Loki published on 127.0.0.1 only
# (compose.setup.yml). On its first start Grafana makes the admin account "admin" with its default
# password, "admin"; app_create_admin replaces it at once through Grafana's own CLI and proves the
# new one with a loopback login. Only then does app_expose swap in compose.expose.yml (the caddy
# labels, no published port), and it refuses while the default password still logs in, while
# signup is open or while anonymous access is on. Nobody else can reach Grafana before its admin
# has the order password.
#
# The password: Grafana applies its configured admin password only when it makes the first user,
# so the image's GF_SECURITY_ADMIN_PASSWORD__FILE would not fix a password on a retry, and the
# image's entrypoint copies that file into the process environment anyway (packaging/docker/run.sh).
# grafana cli admin reset-admin-password --password-from-stdin sets it on every run instead
# (pkg/cmd/grafana-cli/commands/reset_password_command.go in 13.3.2; https://grafana.com/docs/grafana/v13.3/cli/).
# The password is read from the password file and sent on stdin; the login check sends it as a
# basic credential from a 0600 header file (curl -H @file). It is in no command line, compose
# file, env file or container environment.
#
# Loki takes logs from the customer's other servers on https://<host>/loki/api/v1/push, behind
# Caddy's basic auth with a credential made on this server: its plain password is in
# /root/vps-apps-credentials.txt (0600) and only its bcrypt hash is in the .env. Loki's query API is
# never public; Grafana reads Loki and Prometheus on the stack's internal network.

VA_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Grafana OSS has no tag per major version: 13.3 follows the newest 13.3.x patch. 13 is the current
# major. The release line is the lowest one this code takes: app_prepare and rc update move to the
# newest 13.x line the registry has (grafana_newest_minor), and never to another major, since
# Grafana's database migrations only go forward.
VA_GRAFANA_IMAGE_REF="grafana/grafana:13.3"
# Loki, Prometheus and node-exporter have a tag per major version, which rc update re-resolves, so
# they stay on 3.x, 3.x and 1.x. Loki 4 is in release candidates; its 3 tag keeps the 3.x line.
VA_GRAFANA_LOKI_IMAGE_REF="grafana/loki:3"
VA_GRAFANA_PROMETHEUS_IMAGE_REF="prom/prometheus:v3"
VA_GRAFANA_NODE_EXPORTER_IMAGE_REF="prom/node-exporter:v1"
VA_GRAFANA_ADMIN="admin"
VA_GRAFANA_URL="http://127.0.0.1:3000"
VA_GRAFANA_LOKI_URL="http://127.0.0.1:3100"
VA_GRAFANA_PROMETHEUS_URL="http://127.0.0.1:9090"
VA_GRAFANA_PUSH_PATH=/loki/api/v1/push
VA_GRAFANA_PUSH_USER="loki"
# The bcrypt cost of the push credential's hash. The password is 192 random bits, so the cost
# protects nothing against guessing; it only sets what each check costs Caddy, and Caddy's default
# of 14 lets a flood of wrong passwords take a whole CPU.
VA_GRAFANA_BCRYPT_COST=10

app_data_dir() {
  p /opt/vps-apps-data/grafana
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
# /etc/vps-apps/domains (one per line), separated by spaces. Both caddy labels use it byte for byte.
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

# grafana_write_configs: the config files of this directory, copied under the data dir, where
# compose.yml mounts their directories read-only. Rewritten on every run, so they are what the code
# holds. They carry no secret and are 0644, since each container reads them as its own user.
grafana_write_configs() {
  local c
  c="$(app_data_dir)/config"
  mkdir -p "$c/loki" "$c/prometheus" "$c/grafana/datasources" "$c/grafana/providers" "$c/grafana/dashboards" &&
    write_atomic "$c/loki/loki.yaml" 0644 <"$VA_APP_DIR/loki.yaml" &&
    write_atomic "$c/prometheus/prometheus.yml" 0644 <"$VA_APP_DIR/prometheus.yml" &&
    write_atomic "$c/prometheus/prometheus-agent.yml" 0644 <"$VA_APP_DIR/prometheus-agent.yml" &&
    write_atomic "$c/grafana/datasources/vps-apps.yaml" 0644 <"$VA_APP_DIR/provisioning/datasources.yaml" &&
    write_atomic "$c/grafana/providers/vps-apps.yaml" 0644 <"$VA_APP_DIR/provisioning/dashboards.yaml" &&
    write_atomic "$c/grafana/dashboards/server.json" 0644 <"$VA_APP_DIR/dashboards/server.json"
}

# grafana_probe_digest <repo:tag>: like resolve_image_digest, but quiet: a tag that does not exist
# is an expected answer here, not an error for the install log.
grafana_probe_digest() {
  local digest
  digest="$(docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest' 2>/dev/null)" ||
    return 1
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  printf '%s@%s\n' "${1%:*}" "$digest"
}

# grafana_newest_minor <repo:X.Y> [<image>]: print "<repo:X.Z> <image>", the newest X.Z line the
# registry has, Z >= Y, and its digest-pinned image. Grafana publishes its release lines one after
# the other, so the lookup goes up from Y and stops at the first line that does not resolve, after
# VA_GRAFANA_MINOR_PROBES (20) lines at most. The major X never changes. The image of X.Y is resolved
# unless given; fails only when it cannot be.
grafana_newest_minor() {
  local ref="$1" image="${2:-}" repo major minor next found i
  [[ "$ref" =~ ^(.+):([0-9]+)\.([0-9]+)$ ]] || return 1
  repo="${BASH_REMATCH[1]}" major="${BASH_REMATCH[2]}" minor="${BASH_REMATCH[3]}"
  if [ -z "$image" ]; then
    image="$(resolve_image_digest "$ref")" || return 1
  fi
  for ((i = 0; i < ${VA_GRAFANA_MINOR_PROBES:-20}; i++)); do
    next="$repo:$major.$((minor + 1))"
    found="$(grafana_probe_digest "$next")" || break
    ref="$next" image="$found" minor=$((minor + 1))
  done
  printf '%s %s\n' "$ref" "$image"
}

# grafana_cred_file: the credentials file, shared with the other apps' generated logins.
grafana_cred_file() {
  p /root/vps-apps-credentials.txt
}

# grafana_cred_value <prefix>: the rest of the first line of the credentials file that starts with
# <prefix>, empty when there is none.
grafana_cred_value() {
  local f
  f="$(grafana_cred_file)"
  [ -f "$f" ] || return 0
  awk -v p="$1" 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }' "$f"
}

# grafana_write_credentials <loki-password> <admin-password>: the credentials file, mode 0600,
# replaced atomically: the Loki push login, then, when <admin-password> is not empty, the generated
# Grafana admin login. Its "Password: " line is the one rc users and the other apps know as the
# generated login; the Loki lines carry their own names. Either part is left out when its password
# is empty.
grafana_write_credentials() {
  local f
  f="$(grafana_cred_file)"
  (
    umask 077
    mkdir -p "$(dirname "$f")"
  ) || return 1
  {
    if [ -n "$1" ]; then
      printf 'Loki log push for this server, for Grafana Alloy, Promtail or any Loki client\n'
      printf 'Loki push URL: https://%s%s\nLoki push username: %s\nLoki push password: %s\n' \
        "$VA_HOST" "$VA_GRAFANA_PUSH_PATH" "$VA_GRAFANA_PUSH_USER" "$1"
    fi
    if [ -n "$2" ]; then
      [ -z "$1" ] || printf '\n'
      printf 'Grafana admin login, generated because the password you chose does not meet Grafana rules\n'
      printf 'Username: %s\nPassword: %s\n' "$VA_GRAFANA_ADMIN" "$2"
    fi
  } | write_atomic "$f" 0600
}

# grafana_push_password: the Loki push password: the one already in the credentials file (a retry
# after an interrupted install), or a new one of 24 random bytes in hex.
grafana_push_password() {
  local pw
  pw="$(grafana_cred_value 'Loki push password: ')"
  if [[ ! "$pw" =~ ^[0-9a-f]{48}$ ]]; then
    pw="$(openssl rand -hex 24)" || return 1
    [[ "$pw" =~ ^[0-9a-f]{48}$ ]] || return 1
  fi
  printf '%s\n' "$pw"
}

# grafana_hash_password: the bcrypt hash of the password on stdin (one line, newline included, which
# caddy reads up to), made by caddy hash-password in the running proxy container
# (https://caddyserver.com/docs/command-line#caddy-hash-password). Fails unless the answer is a
# bcrypt hash.
grafana_hash_password() {
  local proxy out
  proxy="$(p /opt/vps-apps-data/proxy)"
  if ! out="$(docker compose -f "$proxy/compose.yml" --env-file "$proxy/.env" exec -T caddy \
    caddy hash-password --bcrypt-cost "$VA_GRAFANA_BCRYPT_COST")"; then
    log "grafana: caddy hash-password failed in the proxy container"
    return 1
  fi
  if [[ ! "$out" =~ ^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$ ]]; then
    log "grafana: caddy hash-password did not answer a bcrypt hash"
    return 1
  fi
  printf '%s\n' "$out"
}

# app_prepare: the config files on every run, then the .env, created once. An existing .env is kept
# as it is, so the secret key and the push credential stay byte-identical on a re-run. Every image
# is resolved before any secret is made or anything written; the credentials file is written before
# the .env, so the hash in the .env always matches a password the file holds.
app_prepare() {
  local data grafana_ref grafana_image loki_image prom_image ne_image secret pw hash line out="" key found
  data="$(app_data_dir)"
  mkdir -p "$data"
  grafana_write_configs || return 1
  [ ! -f "$data/.env" ] || return 0

  found="$(grafana_newest_minor "$VA_GRAFANA_IMAGE_REF")" || return 1
  grafana_ref="${found%% *}" grafana_image="${found#* }"
  loki_image="$(resolve_image_digest "$VA_GRAFANA_LOKI_IMAGE_REF")" || return 1
  prom_image="$(resolve_image_digest "$VA_GRAFANA_PROMETHEUS_IMAGE_REF")" || return 1
  ne_image="$(resolve_image_digest "$VA_GRAFANA_NODE_EXPORTER_IMAGE_REF")" || return 1
  secret="$(openssl rand -hex 32)" || return 1
  [[ "$secret" =~ ^[0-9a-f]{64}$ ]] || return 1
  pw="$(grafana_push_password)" || return 1
  # printf is a builtin: the password reaches caddy through a pipe, on no command line.
  hash="$(printf '%s\n' "$pw" | grafana_hash_password)" || return 1
  grafana_write_credentials "$pw" "$(grafana_cred_value 'Password: ')" || return 1

  local -A vars=(
    [GRAFANA_IMAGE]="$grafana_image" [GRAFANA_IMAGE_REF]="$grafana_ref"
    [LOKI_IMAGE]="$loki_image" [LOKI_IMAGE_REF]="$VA_GRAFANA_LOKI_IMAGE_REF"
    [PROMETHEUS_IMAGE]="$prom_image" [PROMETHEUS_IMAGE_REF]="$VA_GRAFANA_PROMETHEUS_IMAGE_REF"
    [NODE_EXPORTER_IMAGE]="$ne_image" [NODE_EXPORTER_IMAGE_REF]="$VA_GRAFANA_NODE_EXPORTER_IMAGE_REF"
    [GRAFANA_SECRET_KEY]="$secret"
    [GRAFANA_ROOT_URL]="https://$VA_HOST/"
    [LOKI_PUSH_HASH]="$hash"
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

# grafana_health_ok: Grafana's /api/health on the loopback port says its database is ok. It answers
# only once the database is migrated and the admin made, and 503 while the database fails
# (pkg/api/http_server.go, apiHealthHandler).
grafana_health_ok() {
  local body
  body="$(curl -fsS --max-time 30 "$VA_GRAFANA_URL/api/health" 2>/dev/null)" || return 1
  [ "$(jq -r '.database // empty' <<<"$body" 2>/dev/null)" = ok ]
}

# grafana_wait_for_api: wait, bounded, until Grafana is healthy on the loopback port. Its first start
# runs every database migration, which takes a while on a small server.
grafana_wait_for_api() {
  local deadline
  deadline=$((SECONDS + ${VA_GRAFANA_WAIT:-300}))
  until grafana_health_ok; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "grafana: Grafana is not healthy on 127.0.0.1:3000"
      return 1
    fi
    sleep "${VA_GRAFANA_INTERVAL:-3}"
  done
}

# grafana_wait_ready <url> <name>: wait, bounded, until <url> answers 2xx: Loki's /ready and
# Prometheus's /-/ready, both on the host's loopback.
grafana_wait_ready() {
  local deadline
  deadline=$((SECONDS + ${VA_GRAFANA_WAIT:-300}))
  until curl -fsS -o /dev/null --max-time 30 "$1" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "grafana: $2 is not ready on $1"
      return 1
    fi
    sleep "${VA_GRAFANA_INTERVAL:-3}"
  done
}

# grafana_password_ok <file>: a password Grafana takes, judged on the exact bytes of the file:
# Grafana's own rule is at least 4 characters (password_policy stays off;
# pkg/services/user/password.go), and the CLI reads one line. Only printable ASCII is accepted, so
# the password is one the customer can type, and anything else deterministically takes the
# fallback. "admin", Grafana's default, is refused too: app_expose refuses while it logs in. Every
# order-form password passes.
grafana_password_ok() {
  local LC_ALL=C pw
  pw="$(
    cat "$1"
    printf x
  )"
  pw="${pw%x}"
  [[ "$pw" =~ ^[[:print:]]+$ ]] || return 1
  [ "${#pw}" -ge 4 ] && [ "${#pw}" -le 4096 ] && [ "$pw" != admin ]
}

# grafana_fallback_password_file <file>: write a generated password into <file>: the one already in
# the credentials file, or a new one, then kept there next to the Loki push login.
grafana_fallback_password_file() {
  local gen
  gen="$(grafana_cred_value 'Password: ')"
  if [ -z "$gen" ]; then
    gen="$(openssl rand -hex 16)" || return 1
    [[ "$gen" =~ ^[0-9a-f]{32}$ ]] || return 1
    gen="Rc9$gen"
    grafana_write_credentials "$(grafana_cred_value 'Loki push password: ')" "$gen" || return 1
  fi
  printf '%s' "$gen" >"$1"
}

# grafana_reset_password <work-dir> <password-file>: the admin's password through Grafana's CLI in
# the running container, from stdin. 2 when Grafana's password policy refuses it, 1 when the CLI
# fails otherwise, 0 when it exits 0. An exit 0 proves nothing by itself: the command returns 0 on
# every error but the policy one, the "new password cannot be the same as the current password" of
# a retry included, and prints its success line only when it changed the password. So only the
# login check that follows decides. The output holds no password; it goes to a work file and only
# its end to the log.
grafana_reset_password() {
  local rc=0
  app_compose exec -T grafana grafana cli --homepath /usr/share/grafana admin reset-admin-password \
    --password-from-stdin <"$2" >"$1/cli" 2>&1 || rc=$?
  if grep -q "doesn't meet the password policy" "$1/cli"; then
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    log "grafana: reset-admin-password failed (exit $rc): $(tail -n 3 "$1/cli" | tr '\n' ' ' | head -c 300)"
    return 1
  fi
  grep -q 'Admin password changed successfully' "$1/cli" ||
    log "grafana: reset-admin-password changed nothing (the password may be in place already), the login check decides"
}

# grafana_basic_header <user> <password-file> <header-file>: an HTTP basic credential as a header
# line. The password reaches base64 on stdin.
grafana_basic_header() {
  local b64
  b64="$({
    printf '%s:' "$1"
    cat "$2"
  } | base64 -w0)" || return 1
  printf 'Authorization: Basic %s\n' "$b64" >"$3"
}

# grafana_call <method> <path> <header-file> <body-out> [-]: one loopback API call, with the
# Authorization header read from <header-file> unless it is empty; with a fifth argument "-", a
# JSON body from stdin. Prints the HTTP status, 000 when nothing answered.
grafana_call() {
  local code
  local -a extra=()
  if [ -n "$3" ]; then
    extra+=(-H "@$3")
  fi
  if [ "${5:-}" = - ]; then
    extra+=(-H 'Content-Type: application/json' --data-binary @-)
  fi
  code="$(curl -sS --max-time 30 -o "$4" -w '%{http_code}' -X "$1" "${extra[@]}" "$VA_GRAFANA_URL$2")" || code=000
  printf '%s' "${code:-000}"
}

# grafana_login_ok <work-dir>: the admin logs in to the API with the credential in <work-dir>/basic
# and is the server admin.
grafana_login_ok() {
  local code
  code="$(grafana_call GET /api/user "$1/basic" "$1/body")"
  [ "$code" = 200 ] &&
    jq -e --arg u "$VA_GRAFANA_ADMIN" '.login == $u and .isGrafanaAdmin == true' "$1/body" >/dev/null 2>&1
}

# grafana_make_admin <work-dir> <password-file>: the admin step itself (see app_create_admin).
grafana_make_admin() {
  local work="$1" pwfile="$2" rc=0
  if [ -n "$(grafana_cred_value 'Password: ')" ]; then
    log "grafana: using the generated password from an earlier attempt"
    grafana_fallback_password_file "$work/pw" || return 1
    pwfile="$work/pw"
  elif ! grafana_password_ok "$pwfile"; then
    log "grafana: the chosen password does not meet Grafana's rule, using a generated one"
    grafana_fallback_password_file "$work/pw" || return 1
    pwfile="$work/pw"
  fi
  grafana_wait_for_api || return 1
  grafana_reset_password "$work" "$pwfile" || rc=$?
  if [ "$rc" -eq 2 ] && [ "$pwfile" != "$work/pw" ]; then
    log "grafana: Grafana refused the chosen password, using a generated one"
    grafana_fallback_password_file "$work/pw" || return 1
    pwfile="$work/pw"
    rc=0
    grafana_reset_password "$work" "$pwfile" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -ne 2 ] || log "grafana: Grafana refused the generated password too"
    return 1
  fi
  grafana_basic_header "$VA_GRAFANA_ADMIN" "$pwfile" "$work/basic" || return 1
  if ! grafana_login_ok "$work"; then
    log "grafana: the admin cannot log in with the password just set"
    return 1
  fi
}

# app_create_admin <password-file>: the admin's password set from the file and proven by a login,
# on every run, so a retry repairs whatever an earlier one left. A password that breaks Grafana's
# rule (by our check or by Grafana's own answer) is replaced by a generated one in
# /root/vps-apps-credentials.txt; once that file holds one, a retry uses it, so the file always
# holds the login that works. The work files (the CLI's output, the credential, answers) live in a
# 0700 directory removed at the end; one a killed run left is removed first.
app_create_admin() {
  local work rc=0
  rm -rf "$(app_data_dir)"/.admin.*
  work="$(mktemp -d "$(app_data_dir)/.admin.XXXXXX")" || return 1
  (
    umask 077
    grafana_make_admin "$work" "$1"
  ) || rc=$?
  rm -rf "$work"
  [ "$rc" -eq 0 ] || return 1
}

# grafana_default_login_refused <work-dir>: Grafana's default admin password does not log in: the
# answer is a plain 401. Anything else, a 200 above all, fails.
grafana_default_login_refused() {
  local code
  printf '%s' admin >"$1/default"
  grafana_basic_header "$VA_GRAFANA_ADMIN" "$1/default" "$1/default-basic" || return 1
  code="$(grafana_call GET /api/user "$1/default-basic" "$1/body")"
  if [ "$code" != 401 ]; then
    log "grafana: the default admin password answers HTTP $code, not 401"
    return 1
  fi
}

# grafana_signup_closed <work-dir>: Grafana's signup call says signup is disabled. With signup off
# it answers that before it reads the address; with signup on, the address sent is not one, so the
# call is refused and nothing is created (pkg/api/signup.go).
grafana_signup_closed() {
  local code
  code="$(printf '{"email":"vps-apps-signup-check"}' | grafana_call POST /api/user/signup "" "$1/body" -)"
  if [ "$code" != 401 ] || ! jq -e '.message == "User signup is disabled"' "$1/body" >/dev/null 2>&1; then
    log "grafana: the signup call answers HTTP $code, not that signup is disabled"
    return 1
  fi
}

# grafana_anonymous_off <work-dir>: without a login, the organization API answers 401; with
# anonymous access on it would answer as the anonymous viewer.
grafana_anonymous_off() {
  local code
  code="$(grafana_call GET /api/org/ "" "$1/body")"
  if [ "$code" != 401 ]; then
    log "grafana: the organization API answers HTTP $code without a login, not 401"
    return 1
  fi
}

# grafana_exposable: Grafana may face the internet: the default password is refused, signup is
# closed and anonymous access is off. The work files live in a 0700 directory removed at the end.
grafana_exposable() {
  local work rc=0
  rm -rf "$(app_data_dir)"/.expose.*
  work="$(mktemp -d "$(app_data_dir)/.expose.XXXXXX")" || return 1
  (
    umask 077
    grafana_default_login_refused "$work" && grafana_signup_closed "$work" && grafana_anonymous_off "$work"
  ) || rc=$?
  rm -rf "$work"
  [ "$rc" -eq 0 ]
}

# app_expose: first puts the stack back into setup state (marker removed, Grafana and Loki on the
# loopback ports only) and waits until Grafana, Loki and Prometheus answer. That makes a retry after
# a failed or interrupted expose recover on its own, and it is where the checks can be made. Then it
# refuses unless grafana_exposable holds, so a Grafana with its default password, an open signup or
# anonymous access is never put on the internet.
app_expose() {
  rm -f "$(app_data_dir)/exposed"
  if ! app_compose up -d; then
    log "grafana: cannot bring the setup stack up before exposing"
    return 1
  fi
  grafana_wait_for_api || return 1
  grafana_wait_ready "$VA_GRAFANA_LOKI_URL/ready" Loki || return 1
  grafana_wait_ready "$VA_GRAFANA_PROMETHEUS_URL/-/ready" Prometheus || return 1
  if ! grafana_exposable; then
    log "grafana: refusing to expose, the default password, signup or anonymous access is open or unreadable"
    return 1
  fi
  : >"$(app_data_dir)/exposed"
  set_site_mode app
  if ! app_compose up -d; then
    log "grafana: starting the exposed stack failed"
    # Stop whatever came up, drop the marker (so rc names the setup file again) and show the failed
    # page instead of leaving a half-exposed server.
    app_compose down || true
    rm -f "$(app_data_dir)/exposed"
    set_site_mode failed
    return 1
  fi
}

# Grafana must be healthy over HTTPS on the server's own name with a valid certificate, and the Loki
# push path there must ask for its credential (401), which says that the proxy serves both
# containers' labels. The body is captured first: a pipe into a reader can fail curl with error 23
# under pipefail.
app_ready_check() {
  local body code
  body="$(curl -fsS --max-time 10 --resolve "$VA_HOST:443:127.0.0.1" "https://$VA_HOST/api/health")" || return 1
  [ "$(jq -r '.database // empty' <<<"$body" 2>/dev/null)" = ok ] || return 1
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$VA_HOST:443:127.0.0.1" \
    -X POST "https://$VA_HOST$VA_GRAFANA_PUSH_PATH")" || return 1
  [ "$code" = 401 ]
}

# app_domain_added <domain>: rewrite the address list from the host and /etc/vps-apps/domains, so
# every name serves Grafana and the push path, and move Grafana's root URL (the links in alerts and
# shares) to the domain just added, the newest one. Then recreate the stack. An invalid name leaves
# the root URL on the server's own name.
app_domain_added() {
  local env_file line key out="" site_addrs url_host="$VA_HOST"
  env_file="$(app_data_dir)/.env"
  site_addrs="$(app_site_addrs)"
  if valid_hostname "${1:-}"; then
    url_host="$1"
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    case "$key" in
      VA_SITE_ADDRS) line="VA_SITE_ADDRS=\"$site_addrs\"" ;;
      GRAFANA_ROOT_URL) line="GRAFANA_ROOT_URL=https://$url_host/" ;;
    esac
    out+="$line"$'\n'
  done <"$env_file"
  printf '%s' "$out" | write_atomic "$env_file" 0600
  app_compose up -d
}

# grafana_env_set <file> <key> <value>: every line of the key set to the value, the others kept.
grafana_env_set() {
  local line out=""
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" != "$2="* ]] || line="$2=$3"
    out+="$line"$'\n'
  done <"$1"
  printf '%s' "$out" >"$1"
}

# app_update_env <env-file> <out-file>: rc update's hook. Writes to <out-file> what the app .env
# becomes: every image re-resolved from its tag (lib/images.sh), then Grafana moved to the newest
# release line of its major the registry has (grafana_newest_minor), and never to another major.
# A Grafana tag that is not a release line (set by hand) stays as it resolved. <env-file> itself is
# not written. Fails when an image cannot be resolved; a failed lookup of a newer line keeps the line.
app_update_env() {
  local ref image found new major
  resolve_env_images "$1" "$2" || return 1
  ref="$(sed -n 's/^GRAFANA_IMAGE_REF=//p' "$2" | tail -n 1)"
  image="$(sed -n 's/^GRAFANA_IMAGE=//p' "$2" | tail -n 1)"
  [[ "$ref" =~ ^.+:[0-9]+\.[0-9]+$ ]] || return 0
  found="$(grafana_newest_minor "$ref" "$image")" || return 0
  new="${found%% *}"
  if [ "$new" != "$ref" ]; then
    grafana_env_set "$2" GRAFANA_IMAGE_REF "$new" || return 1
    grafana_env_set "$2" GRAFANA_IMAGE "${found#* }" || return 1
    major="${ref##*:}"
    echo "rc update: Grafana moves to the ${new##*:} release line, the newest of Grafana ${major%%.*}"
  fi
}
