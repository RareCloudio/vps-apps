#!/usr/bin/env bash
# The "n8n" app: n8n on Postgres, plus Valkey and two workers in pro mode. Sourced by install.sh and
# by rc, never executed. It implements the hook contract described in apps/docker/app.sh.
#
# The order that matters: the stack starts with n8n published on 127.0.0.1 only (compose.setup.yml),
# the owner account is created through n8n's own REST call on that loopback port, and only then does
# app_expose swap in compose.expose.yml (the caddy labels, no published port). Nobody else can reach
# the setup page before the owner exists.
#
# The owner is created by the REST call, not by environment variables, so it stays an ordinary
# account the owner can change in the n8n UI. Its password is only ever read from the password file
# and sent on stdin; it is in no compose file, env file or container environment.

VA_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# n8n's stable tag is its newest stable release (beta and next carry the betas, and there is no tag
# per major version).
VA_N8N_IMAGE_REF="docker.n8n.io/n8nio/n8n:stable"
VA_N8N_POSTGRES_IMAGE_REF="postgres:16-alpine"
VA_N8N_VALKEY_IMAGE_REF="valkey/valkey:8-alpine"

app_data_dir() {
  p /opt/vps-apps-data/n8n
}

# The mode chosen at install ("starter" or "pro") lives in a file, because rc runs later without
# arguments. An empty or missing value means starter.
app_mode() {
  local f mode=""
  f="$(app_data_dir)/mode"
  [ ! -r "$f" ] || mode="$(cat "$f")"
  [ "$mode" = pro ] && echo pro || echo starter
}

app_compose_files() {
  printf '%s\n' "$VA_APP_DIR/compose.yml"
  if [ "$(app_mode)" = pro ]; then
    printf '%s\n' "$VA_APP_DIR/compose.pro.yml"
  fi
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
# /etc/vps-apps/domains (one per line), separated by spaces. The caddy label uses it byte for byte.
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

# app_prepare: the mode, then the .env, created once. An existing .env is kept as it is, so every
# secret stays byte-identical on a re-run. Every image is resolved before anything is written.
app_prepare() {
  local data n8n_image pg_image valkey_image line out="" site_addrs
  data="$(app_data_dir)"
  mkdir -p "$data"
  if [ -n "${VA_MODE:-}" ] || [ ! -f "$data/mode" ]; then
    printf '%s' "${VA_MODE:-starter}" | write_atomic "$data/mode" 0644
  fi
  [ ! -f "$data/.env" ] || return 0

  n8n_image="$(resolve_image_digest "$VA_N8N_IMAGE_REF")" || return 1
  pg_image="$(resolve_image_digest "$VA_N8N_POSTGRES_IMAGE_REF")" || return 1
  valkey_image="$(resolve_image_digest "$VA_N8N_VALKEY_IMAGE_REF")" || return 1
  site_addrs="$(app_site_addrs)"

  local -A vars=(
    [N8N_IMAGE]="$n8n_image" [N8N_IMAGE_REF]="$VA_N8N_IMAGE_REF"
    [POSTGRES_IMAGE]="$pg_image" [POSTGRES_IMAGE_REF]="$VA_N8N_POSTGRES_IMAGE_REF"
    [VALKEY_IMAGE]="$valkey_image" [VALKEY_IMAGE_REF]="$VA_N8N_VALKEY_IMAGE_REF"
    [POSTGRES_PASSWORD]="$(openssl rand -hex 24)"
    [N8N_ENCRYPTION_KEY]="$(openssl rand -hex 32)"
    [VALKEY_PASSWORD]="$(openssl rand -hex 32)"
    [VA_SITE_ADDRS]="$site_addrs"
    [N8N_HOST]="$VA_HOST"
    [WEBHOOK_URL]="https://$VA_HOST/"
    [N8N_EDITOR_BASE_URL]="https://$VA_HOST"
  )
  local key
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

# n8n_password_ok <file>: the n8n rule, 8 to 64 characters with an uppercase letter and a digit,
# judged on the exact bytes of the file. Only printable ASCII is accepted: n8n counts UTF-16 units
# and its uppercase test is ASCII-only, so anything else deterministically takes the fallback.
n8n_password_ok() {
  local LC_ALL=C pw
  pw="$(
    cat "$1"
    printf x
  )"
  pw="${pw%x}"
  [[ "$pw" =~ ^[[:print:]]+$ ]] || return 1
  [ "${#pw}" -ge 8 ] && [ "${#pw}" -le 64 ] && [[ "$pw" =~ [A-Z] ]] && [[ "$pw" =~ [0-9] ]]
}

# n8n_wait_for_api: wait, bounded, until n8n is fully ready on the loopback port. While migrations
# still run, n8n answers every path but /healthz* with HTTP 200 "starting up", so only
# /healthz/readiness (200 once connected and migrated) says that the owner call will really work.
n8n_wait_for_api() {
  local deadline
  deadline=$((SECONDS + ${VA_N8N_WAIT:-180}))
  until curl -fsS -o /dev/null --max-time 30 http://127.0.0.1:5678/healthz/readiness 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "n8n: not ready on 127.0.0.1:5678"
      return 1
    fi
    sleep "${VA_N8N_INTERVAL:-3}"
  done
}

# n8n_owner_email: the owner login install.sh settled on (VA_ADMIN_EMAIL: the customer's email, or
# admin@<host>).
n8n_owner_email() {
  printf '%s' "${VA_ADMIN_EMAIL:-admin@$VA_HOST}"
}

# n8n_post_owner <password-file>: one owner setup call, the body built by jq from the file and sent
# on stdin. Returns 0 when the owner exists afterwards (the response is the owner, or n8n says the
# owner is already set up), 2 when n8n rejects the password, 1 for anything else. A 200 whose body
# is not the owner (n8n's "starting up" page) is a failure, never a success.
n8n_post_owner() {
  local body code rc=1 msg email
  email="$(n8n_owner_email)"
  body="$(mktemp)"
  code="$(jq -n --rawfile pw "$1" --arg email "$email" \
    '{email: $email, firstName: "Admin", lastName: "RareCloud", password: $pw}' |
    curl -sS --max-time 30 -o "$body" -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- \
      http://127.0.0.1:5678/rest/owner/setup)" || code=000
  case "$code" in
    200) jq -e --arg e "$email" '.data.email == $e' "$body" >/dev/null 2>&1 && rc=0 ;;
    400)
      msg="$(jq -r '.message // empty' "$body" 2>/dev/null || true)"
      case "$msg" in
        "Instance owner already setup") rc=0 ;;
        "Password must"*) rc=2 ;;
      esac
      ;;
  esac
  [ "$rc" -ne 1 ] || log "n8n: owner setup failed with HTTP $code: $(head -c 200 "$body")"
  rm -f "$body"
  return "$rc"
}

# n8n_fallback_password_file <file>: write a password that satisfies n8n's rule into <file> and
# keep it in /root/vps-apps-credentials.txt (mode 600). A retry reuses the one already stored there.
n8n_fallback_password_file() {
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
      printf 'n8n owner login, generated because the password you chose does not meet n8n rules\nEmail: %s\nPassword: %s\n' \
        "$(n8n_owner_email)" "$(cat "$1")" | write_atomic "$cred" 0600
    )
  fi
}

# app_create_admin <password-file>: the owner account through n8n's REST call on the loopback port.
# A password that breaks n8n's rule (by our check or by n8n's own 400 "Password must ...") is
# replaced by a generated one in /root/vps-apps-credentials.txt, and the call is made again.
app_create_admin() {
  local pwfile="$1" tmp="" rc=0
  tmp="$(mktemp "$(app_data_dir)/.owner-pw.XXXXXX")"
  chmod 600 "$tmp"
  if ! n8n_password_ok "$pwfile"; then
    log "n8n: the chosen password does not meet n8n's rule, using a generated one"
    n8n_fallback_password_file "$tmp"
    pwfile="$tmp"
  fi
  if n8n_wait_for_api; then
    n8n_post_owner "$pwfile" || rc=$?
    if [ "$rc" -eq 2 ] && [ "$pwfile" != "$tmp" ]; then
      log "n8n: n8n rejected the chosen password, using a generated one"
      n8n_fallback_password_file "$tmp"
      rc=0
      n8n_post_owner "$tmp" || rc=$?
    fi
  else
    rc=1
  fi
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || return 1
}

# n8n_setup_still_offered: succeeds unless the loopback settings endpoint says, readably, that n8n
# no longer offers the owner setup (userManagement.showSetupOnFirstLoad is false). Fails closed.
n8n_setup_still_offered() {
  local body
  body="$(curl -fsS --max-time 30 http://127.0.0.1:5678/rest/settings 2>/dev/null)" || return 0
  [ "$(jq -r '(.data // .) | .userManagement.showSetupOnFirstLoad' <<<"$body" 2>/dev/null)" = false ] || return 0
  return 1
}

# app_expose: first puts the stack back into setup state (marker removed, n8n published on the
# loopback port only) and waits for it. That makes a retry after a failed or interrupted expose
# recover on its own, and it is where the owner check can be made. Then it refuses while n8n still
# offers the owner setup, so an n8n without an owner is never put on the internet.
app_expose() {
  rm -f "$(app_data_dir)/exposed"
  if ! app_compose up -d; then
    log "n8n: cannot bring the setup stack up before exposing"
    return 1
  fi
  if ! n8n_wait_for_api; then
    return 1
  fi
  if n8n_setup_still_offered; then
    log "n8n: refusing to expose, the owner setup is still offered or its state is unreadable"
    return 1
  fi
  : >"$(app_data_dir)/exposed"
  set_site_mode app
  if ! app_compose up -d; then
    log "n8n: starting the exposed stack failed"
    # Stop whatever came up, drop the marker (so rc names the setup file again) and show the failed
    # page instead of leaving a half-exposed server.
    app_compose down || true
    rm -f "$(app_data_dir)/exposed"
    set_site_mode failed
    return 1
  fi
}

# n8n must answer /healthz/readiness over HTTPS on the server's own name with a valid certificate,
# so ready means the editor works. The body is captured first: a pipe into grep -q can fail curl
# with error 23 under pipefail.
app_ready_check() {
  local body
  body="$(curl -fsS --max-time 10 --resolve "$VA_HOST:443:127.0.0.1" "https://$VA_HOST/healthz/readiness")" || return 1
  grep -q '"status":"ok"' <<<"$body"
}

# app_domain_added <domain>: rewrite the address list from the host and /etc/vps-apps/domains, so
# every name stays served, and move the three URL variables (webhook URLs, editor links, N8N_HOST)
# to the domain just added, the newest one. Then recreate n8n. An invalid name leaves the URL
# variables on the server's own name.
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
      WEBHOOK_URL) line="WEBHOOK_URL=https://$url_host/" ;;
      N8N_EDITOR_BASE_URL) line="N8N_EDITOR_BASE_URL=https://$url_host" ;;
      N8N_HOST) line="N8N_HOST=$url_host" ;;
    esac
    out+="$line"$'\n'
  done <"$env_file"
  printf '%s' "$out" | write_atomic "$env_file" 0600
  app_compose up -d
}

# app_update_env <env-file> <out-file>: rc update's hook (bin/rc.d/update.sh). Writes to <out-file>
# what the app .env becomes: the keys env.tmpl gained since this server was installed
# (n8n_fill_env), then every image re-resolved from its tag (lib/images.sh). <env-file> itself is
# not written. Fails when a key or an image cannot be made.
app_update_env() {
  local filled rc=0
  filled="$(mktemp)"
  { n8n_fill_env "$1" >"$filled" && resolve_env_images "$filled" "$2"; } || rc=1
  rm -f "$filled"
  return "$rc"
}

# n8n_fill_env <env-file>: print <env-file> line by line as it is, then every key of env.tmpl it
# lacks, so a server installed from an earlier release gets the settings added since (app_prepare
# never rewrites an existing .env). A missing key gets its value from the template when that value
# is a constant, and VALKEY_PASSWORD a new secret as at install. A value the install derived (the
# database password, the encryption key, the URLs, the images) is never made up here.
n8n_fill_env() {
  local line valkey_pw=""
  local -a lines=()
  local -A have=()
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
    if [[ "$line" =~ ^([A-Za-z0-9_]+)= ]]; then
      have["${BASH_REMATCH[1]}"]=1
    fi
  done <"$1" || return 1
  if [ -z "${have[VALKEY_PASSWORD]+x}" ]; then
    valkey_pw="$(openssl rand -hex 32)" || return 1
    [[ "$valkey_pw" =~ ^[0-9a-f]{64}$ ]] || return 1
  fi
  [ "${#lines[@]}" -eq 0 ] || printf '%s\n' "${lines[@]}"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Za-z0-9_]+)= ]] || continue
    [ -z "${have[${BASH_REMATCH[1]}]+x}" ] || continue
    line="${line//@VALKEY_PASSWORD@/"$valkey_pw"}"
    if [[ ! "$line" =~ @[A-Z0-9_]+@ ]]; then
      printf '%s\n' "$line"
    fi
  done <"$VA_APP_DIR/env.tmpl"
}
