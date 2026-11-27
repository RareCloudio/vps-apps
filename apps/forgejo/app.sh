#!/usr/bin/env bash
# The "forgejo" app: Forgejo (self-hosted Git) from its rootless image, on SQLite, with git over SSH
# on port 2222. Sourced by install.sh and by rc, never executed. It implements the hook contract
# described in apps/docker/app.sh.
#
# The order that matters: the stack starts with Forgejo published on 127.0.0.1:3000 only
# (compose.setup.yml) and its web installer locked (compose.yml), so there is no setup page at all.
# The admin is made with Forgejo's own CLI inside the container and gets its password through the
# loopback API. Only then does app_expose open 2222 in the firewall and swap in compose.expose.yml
# (the caddy labels and the SSH port, no loopback port).
#
# The password: Forgejo's CLI takes one only as an argument (admin user create --password), which
# would put it in the process list. So the CLI creates the account with --random-password (that value
# is thrown away unread) and makes an access token that can only administer. The password is then set
# with that token through PATCH /api/v1/admin/users/<name>, in a JSON body jq builds from the
# password file and curl sends on stdin. The token and the login check's credential travel in 0600
# header files (curl -H @file), never as an argument, and the token is deleted once the password
# logs in. The password is in no compose file, env file or container environment.

VA_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 15 is Forgejo's current LTS major, supported until 15 July 2027 (the newest stable, 17, until
# 28 January 2027). The 15-rootless tag follows the newest 15.x release, so rc update stays on 15.
VA_FORGEJO_IMAGE_REF="codeberg.org/forgejo/forgejo:15-rootless"
# The admin login. "admin" itself is reserved by Forgejo (reservedUsernames in models/user/user.go).
VA_FORGEJO_ADMIN=gitadmin
VA_FORGEJO_SSH_PORT=2222
# The name of every access token the admin step makes, so a later run finds and deletes them all.
VA_FORGEJO_TOKEN_PREFIX=vps-apps-setup-
VA_FORGEJO_URL="http://127.0.0.1:3000"

app_data_dir() {
  p /opt/vps-apps-data/forgejo
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

# forgejo_cli <args...>: Forgejo's CLI inside the running container, as its own git user.
forgejo_cli() {
  app_compose exec -T forgejo forgejo "$@"
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

# app_prepare: the .env, created once. An existing .env is kept as it is, so the secret key stays
# byte-identical on a re-run (Forgejo encrypts stored secrets with it). The image is resolved before
# anything is written.
app_prepare() {
  local data image secret line out="" site_addrs key
  data="$(app_data_dir)"
  mkdir -p "$data"
  [ ! -f "$data/.env" ] || return 0

  image="$(resolve_image_digest "$VA_FORGEJO_IMAGE_REF")" || return 1
  secret="$(openssl rand -hex 32)" || return 1
  [[ "$secret" =~ ^[0-9a-f]{64}$ ]] || return 1
  site_addrs="$(app_site_addrs)"

  local -A vars=(
    [FORGEJO_IMAGE]="$image" [FORGEJO_IMAGE_REF]="$VA_FORGEJO_IMAGE_REF"
    [FORGEJO_SECRET_KEY]="$secret"
    [VA_SITE_ADDRS]="$site_addrs"
    [FORGEJO_DOMAIN]="$VA_HOST"
    [FORGEJO_ROOT_URL]="https://$VA_HOST/"
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

# forgejo_wait_for_api: wait, bounded, until Forgejo answers its health check on the loopback port.
# /api/healthz answers 200 only once the database is reachable, after the migrations of a start
# (routers/web/healthcheck), so the CLI never races them.
forgejo_wait_for_api() {
  local deadline
  deadline=$((SECONDS + ${VA_FORGEJO_WAIT:-180}))
  until curl -fsS -o /dev/null --max-time 30 "$VA_FORGEJO_URL/api/healthz" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "forgejo: not ready on 127.0.0.1:3000"
      return 1
    fi
    sleep "${VA_FORGEJO_INTERVAL:-3}"
  done
}

# forgejo_password_ok <file>: Forgejo's rule as this server runs it, judged on the exact bytes of the
# file: at least 8 characters (MIN_PASSWORD_LENGTH, with PASSWORD_COMPLEXITY off) and at most 255 (the
# API's limit). Only printable ASCII is accepted, so anything else deterministically takes the
# fallback.
forgejo_password_ok() {
  local LC_ALL=C pw
  pw="$(
    cat "$1"
    printf x
  )"
  pw="${pw%x}"
  [[ "$pw" =~ ^[[:print:]]+$ ]] || return 1
  [ "${#pw}" -ge 8 ] && [ "${#pw}" -le 255 ]
}

# forgejo_fallback_password_file <file>: write a password that meets Forgejo's rule into <file> and
# keep it in /root/vps-apps-credentials.txt (mode 600). A retry reuses the one already stored there.
forgejo_fallback_password_file() {
  local cred gen
  cred="$(p /root/vps-apps-credentials.txt)"
  if [ -f "$cred" ]; then
    sed -n 's/^Password: //p' "$cred" | head -n1 | tr -d '\n' >"$1"
  fi
  if [ ! -s "$1" ]; then
    gen="$(openssl rand -hex 16)" || return 1
    [[ "$gen" =~ ^[0-9a-f]{32}$ ]] || return 1
    printf 'Rc9%s' "$gen" >"$1"
    mkdir -p "$(dirname "$cred")"
    printf 'Forgejo admin login, generated because the password you chose does not meet Forgejo rules\nUsername: %s\nPassword: %s\n' \
      "$VA_FORGEJO_ADMIN" "$(cat "$1")" | write_atomic "$cred" 0600
  fi
}

# forgejo_admin_listed: 0 when the admin exists as an active site admin, 1 when it does not, 2 when
# the CLI cannot list the admins.
forgejo_admin_listed() {
  local out
  out="$(forgejo_cli admin user list --admin)" || return 2
  awk -v u="$VA_FORGEJO_ADMIN" 'NR > 1 && $2 == u && $4 == "true" { found = 1 } END { exit !found }' <<<"$out"
}

# forgejo_ensure_admin <work-dir>: the admin account, created unless an earlier run made it. The
# random password the CLI prints on stdout is discarded; the real one is set over the API.
forgejo_ensure_admin() {
  local rc=0
  forgejo_admin_listed || rc=$?
  case "$rc" in
    0) return 0 ;;
    2)
      log "forgejo: cannot list the admin users"
      return 1
      ;;
  esac
  if ! forgejo_cli admin user create --admin --username "$VA_FORGEJO_ADMIN" --email "admin@$VA_HOST" \
    --random-password --must-change-password=false >/dev/null 2>"$1/err"; then
    log "forgejo: creating the admin failed: $(head -c 300 "$1/err" | tr '\n' ' ')"
    return 1
  fi
  if ! forgejo_admin_listed; then
    log "forgejo: the admin is not listed after it was created"
    return 1
  fi
}

# forgejo_setup_token <header-file>: an access token for the admin that can only administer, under a
# name of its own, written as an Authorization header line. It reaches this shell on the CLI's stdout.
forgejo_setup_token() {
  local name out
  name="$VA_FORGEJO_TOKEN_PREFIX$(openssl rand -hex 4)" || return 1
  if ! out="$(forgejo_cli admin user generate-access-token --username "$VA_FORGEJO_ADMIN" \
    --token-name "$name" --scopes write:admin --raw)"; then
    log "forgejo: the CLI did not make a setup token"
    return 1
  fi
  out="${out//[[:space:]]/}"
  if [[ ! "$out" =~ ^[0-9a-f]{40}$ ]]; then
    log "forgejo: the setup token is not 40 hex characters"
    return 1
  fi
  printf 'Authorization: token %s\n' "$out" >"$1"
}

# forgejo_call <method> <path> <header-file> <body-out> [-]: one loopback API call with the
# Authorization header read from <header-file>; with a fifth argument "-", a JSON body from stdin.
# Prints the HTTP status, 000 when nothing answered.
forgejo_call() {
  local code
  local -a data=()
  if [ "${5:-}" = - ]; then
    data=(-H 'Content-Type: application/json' --data-binary @-)
  fi
  code="$(curl -sS --max-time 30 -o "$4" -w '%{http_code}' -X "$1" -H "@$3" "${data[@]}" \
    "$VA_FORGEJO_URL$2")" || code=000
  printf '%s' "${code:-000}"
}

# forgejo_set_password <work-dir> <password-file>: the admin's password through the API, with the
# setup token. 0 when Forgejo answers with the admin, 2 when it rejects the password (400 for its
# length or complexity rule, 422 for the API's size limit), 1 for anything else.
forgejo_set_password() {
  local code
  code="$(jq -n --rawfile pw "$2" '{password: $pw, must_change_password: false}' |
    forgejo_call PATCH "/api/v1/admin/users/$VA_FORGEJO_ADMIN" "$1/token" "$1/body" -)" || code=000
  case "$code" in
    200)
      jq -e --arg u "$VA_FORGEJO_ADMIN" '.login == $u' "$1/body" >/dev/null 2>&1 && return 0
      ;;
    400 | 422)
      log "forgejo: Forgejo rejected the password with HTTP $code: $(head -c 200 "$1/body")"
      return 2
      ;;
  esac
  log "forgejo: setting the admin password failed with HTTP $code: $(head -c 200 "$1/body" 2>/dev/null)"
  return 1
}

# forgejo_basic_header <password-file> <header-file>: the admin's HTTP basic credential as a header
# line. The password reaches base64 on stdin.
forgejo_basic_header() {
  local b64
  b64="$({
    printf '%s:' "$VA_FORGEJO_ADMIN"
    cat "$1"
  } | base64 -w0)" || return 1
  printf 'Authorization: Basic %s\n' "$b64" >"$2"
}

# forgejo_login_ok <work-dir>: the admin logs in to the API with the password (basic auth).
forgejo_login_ok() {
  local code
  code="$(forgejo_call GET /api/v1/user "$1/basic" "$1/body")"
  [ "$code" = 200 ] && jq -e --arg u "$VA_FORGEJO_ADMIN" '.login == $u' "$1/body" >/dev/null 2>&1
}

# forgejo_drop_setup_tokens <work-dir>: delete every access token of the admin whose name carries the
# setup prefix, this run's and any an interrupted run left. Forgejo deletes tokens only for a basic
# login, which the password now gives.
forgejo_drop_setup_tokens() {
  local code ids id
  code="$(forgejo_call GET "/api/v1/users/$VA_FORGEJO_ADMIN/tokens?limit=50" "$1/basic" "$1/body")"
  if [ "$code" != 200 ]; then
    log "forgejo: listing the admin's access tokens failed with HTTP $code"
    return 1
  fi
  if ! ids="$(jq -r --arg p "$VA_FORGEJO_TOKEN_PREFIX" '.[] | select(.name | startswith($p)) | .id' "$1/body")"; then
    log "forgejo: the access token list cannot be read"
    return 1
  fi
  for id in $ids; do
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    code="$(forgejo_call DELETE "/api/v1/users/$VA_FORGEJO_ADMIN/tokens/$id" "$1/basic" "$1/body")"
    if [ "$code" != 204 ]; then
      log "forgejo: deleting the setup token $id failed with HTTP $code"
      return 1
    fi
  done
}

# forgejo_make_admin <work-dir> <password-file>: the admin step itself (see app_create_admin).
forgejo_make_admin() {
  local work="$1" pwfile="$2" rc=0
  if ! forgejo_password_ok "$pwfile"; then
    log "forgejo: the chosen password does not meet Forgejo's rule, using a generated one"
    forgejo_fallback_password_file "$work/pw" || return 1
    pwfile="$work/pw"
  fi
  forgejo_wait_for_api || return 1
  forgejo_ensure_admin "$work" || return 1
  forgejo_setup_token "$work/token" || return 1
  forgejo_set_password "$work" "$pwfile" || rc=$?
  if [ "$rc" -eq 2 ] && [ "$pwfile" != "$work/pw" ]; then
    log "forgejo: Forgejo rejected the chosen password, using a generated one"
    forgejo_fallback_password_file "$work/pw" || return 1
    pwfile="$work/pw"
    rc=0
    forgejo_set_password "$work" "$pwfile" || rc=$?
  fi
  [ "$rc" -eq 0 ] || return 1
  forgejo_basic_header "$pwfile" "$work/basic" || return 1
  if ! forgejo_login_ok "$work"; then
    log "forgejo: the admin cannot log in with the password just set"
    return 1
  fi
  forgejo_drop_setup_tokens "$work"
}

# app_create_admin <password-file>: the admin account (VA_FORGEJO_ADMIN, admin@<host>) with the
# password from the file. A password that breaks Forgejo's rule (by our check or by Forgejo's own
# 400) is replaced by a generated one in /root/vps-apps-credentials.txt. Every step can run again: an
# existing admin is reused, its password set again, and every setup token deleted. The work files
# (token, credential, answers) live in a 0700 directory removed at the end.
app_create_admin() {
  local work rc=0
  work="$(mktemp -d "$(app_data_dir)/.admin.XXXXXX")" || return 1
  (
    umask 077
    forgejo_make_admin "$work" "$1"
  ) || rc=$?
  rm -rf "$work"
  [ "$rc" -eq 0 ] || return 1
}

# forgejo_signup_closed: the loopback signup page shows Forgejo's "Registration is disabled" text and
# no signup form (routers/web/auth/auth.go, SignUp). Fails closed when the page cannot be read.
forgejo_signup_closed() {
  local body
  body="$(curl -fsS --max-time 30 -H 'Accept-Language: en-US' "$VA_FORGEJO_URL/user/sign_up" 2>/dev/null)" || return 1
  [[ "$body" == *"Registration is disabled"* ]] && [[ "$body" != *'name="user_name"'* ]]
}

# forgejo_open_ssh_port: list 2222/tcp in /etc/vps-apps/open-ports through the firewall's own
# apply (base/50-firewall.sh, as rc port open does), so the host and the DOCKER-USER rules pass git
# over SSH. Every port already listed is kept; a port already there is left as it is. On a failure
# nothing changes.
forgejo_open_ssh_port() {
  local file cand current entry="$VA_FORGEJO_SSH_PORT/tcp"
  file="$(p /etc/vps-apps/open-ports)"
  fw_lock
  current="$(fw_open_ports "$file")" || return 1
  if grep -qxF "$entry" <<<"$current"; then
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  cand="$(mktemp "$(dirname "$file")/.open-ports.XXXXXX")" || return 1
  {
    [ -z "$current" ] || printf '%s\n' "$current"
    printf '%s\n' "$entry"
  } >"$cand"
  if ! firewall_apply "$cand"; then
    rm -f "$cand"
    log "forgejo: the firewall did not take $entry"
    return 1
  fi
}

# app_expose: first puts the stack back into setup state (marker removed, Forgejo on the loopback
# port only) and waits for it, which makes a retry after a failed or interrupted expose recover on
# its own. It refuses unless the admin exists and the signup page is closed, so a Forgejo nobody
# administers, or one anybody can join, is never put on the internet. Then it opens the SSH port in
# the firewall and starts the exposed stack.
app_expose() {
  local rc=0
  rm -f "$(app_data_dir)/exposed"
  if ! app_compose up -d; then
    log "forgejo: cannot bring the setup stack up before exposing"
    return 1
  fi
  if ! forgejo_wait_for_api; then
    return 1
  fi
  forgejo_admin_listed || rc=$?
  if [ "$rc" -ne 0 ]; then
    log "forgejo: refusing to expose, the admin $VA_FORGEJO_ADMIN does not exist or cannot be listed"
    return 1
  fi
  if ! forgejo_signup_closed; then
    log "forgejo: refusing to expose, the signup page is open or cannot be read"
    return 1
  fi
  if ! forgejo_open_ssh_port; then
    return 1
  fi
  : >"$(app_data_dir)/exposed"
  set_site_mode app
  if ! app_compose up -d; then
    log "forgejo: starting the exposed stack failed"
    # Stop whatever came up, drop the marker (so rc names the setup file again) and show the failed
    # page instead of leaving a half-exposed server.
    app_compose down || true
    rm -f "$(app_data_dir)/exposed"
    set_site_mode failed
    return 1
  fi
}

# Forgejo must pass its health check over HTTPS on the server's own name with a valid certificate.
# /api/healthz needs no login, also with REQUIRE_SIGNIN_VIEW on. The body is captured first: a pipe
# into grep -q can fail curl with error 23 under pipefail.
app_ready_check() {
  local body
  body="$(curl -fsS --max-time 10 --resolve "$VA_HOST:443:127.0.0.1" "https://$VA_HOST/api/healthz")" || return 1
  grep -Eq '"status": *"pass"' <<<"$body"
}

# app_domain_added <domain>: rewrite the address list from the host and /etc/vps-apps/domains, so
# every name stays served, and move Forgejo's own name (ROOT_URL, DOMAIN and SSH_DOMAIN, used in
# links and clone URLs) to the domain just added, the newest one. Then recreate Forgejo. An invalid
# name leaves the URL variables on the server's own name.
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
      FORGEJO_DOMAIN) line="FORGEJO_DOMAIN=$url_host" ;;
      FORGEJO_ROOT_URL) line="FORGEJO_ROOT_URL=https://$url_host/" ;;
    esac
    out+="$line"$'\n'
  done <"$env_file"
  printf '%s' "$out" | write_atomic "$env_file" 0600
  app_compose up -d
}
