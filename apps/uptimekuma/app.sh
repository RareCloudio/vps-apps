#!/usr/bin/env bash
# The "uptimekuma" app: Uptime Kuma on its embedded SQLite database. Sourced by install.sh and by
# rc, never executed. It implements the hook contract described in apps/docker/app.sh.
#
# The order that matters: the stack starts with Uptime Kuma published on 127.0.0.1 only
# (compose.setup.yml), the admin account is created through Uptime Kuma's own first-run "setup"
# call on that loopback server, and only then does app_expose swap in compose.expose.yml (the caddy
# labels, no published port). Uptime Kuma has no environment variable for the first account in 2.x:
# until one exists, whoever opens it first creates it, so nobody else can ever reach it before then.
#
# The setup call is a socket.io event, so admin.js makes it with the app container's own node and
# the socket.io-client Uptime Kuma ships (docker compose exec). The password is only ever read from
# the password file and sent on stdin; it is in no compose file, env file, container environment or
# command line.
#
# The image is the official one on its major tag 2: "Latest version of v2 (Recommended)" in
# https://github.com/louislam/uptime-kuma/wiki/Docker-Tags. The latest tag still points to 1.x, and
# 3.0 is in beta under its own tags. The full image (not -slim) carries the Chromium the "Browser
# Engine" monitor needs, and runs as root as the docs recommend (rootless "may not work as expected").
# rc update re-resolves the 2 tag, which only ever points to a 2.x release, so a server stays on 2.x;
# Uptime Kuma migrates its database forward only, and 2 to 3 is a manual migration with a backup
# (https://github.com/louislam/uptime-kuma/wiki/Migration-From-v2-To-v3).

VA_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VA_UPTIME_KUMA_IMAGE_REF="louislam/uptime-kuma:2"
# The user admin.js creates; Uptime Kuma has one account.
VA_UK_USERNAME=admin

app_data_dir() {
  p /opt/vps-apps-data/uptimekuma
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

# app_prepare: the .env, created once, mode 0600. An existing .env is kept as it is, so a re-run
# changes nothing and the pinned digest stays. There is no secret to generate here: Uptime Kuma makes
# its own session signing key in its database on first start, on this server.
app_prepare() {
  local data image line out="" key
  data="$(app_data_dir)"
  mkdir -p "$data"
  [ ! -f "$data/.env" ] || return 0

  image="$(resolve_image_digest "$VA_UPTIME_KUMA_IMAGE_REF")" || return 1
  local -A vars=(
    [UPTIME_KUMA_IMAGE]="$image" [UPTIME_KUMA_IMAGE_REF]="$VA_UPTIME_KUMA_IMAGE_REF"
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

# uk_client <mode> [arg]: admin.js run by the app container's own node, against the container's own
# loopback server unless the mode takes another URL. docker compose exec -T passes stdin through:
# the password, when the mode needs one, comes on the caller's stdin. The script itself is the only
# argument that carries code, and it holds no secret.
uk_client() {
  local script
  script="$(cat "$VA_APP_DIR/admin.js")" || return 1
  app_compose exec -T uptime-kuma node -e "$script" "$@"
}

# uk_wait_for_api: wait, bounded, until Uptime Kuma's main server answers on the loopback port.
# It registers its routes and socket handlers only once the database is ready, so an entry page of
# type entryPage says the setup call will work. Its database setup server answers the same path
# with type setup-database, which is not ready (and cannot happen with UPTIME_KUMA_DB_TYPE set).
uk_wait_for_api() {
  local deadline body
  deadline=$((SECONDS + ${VA_UK_WAIT:-300}))
  while :; do
    if body="$(curl -fsS --max-time 30 http://127.0.0.1:3001/api/entry-page 2>/dev/null)" &&
      [ "$(jq -r '.type // empty' <<<"$body" 2>/dev/null)" = entryPage ]; then
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "uptimekuma: not ready on 127.0.0.1:3001"
      return 1
    fi
    sleep "${VA_UK_INTERVAL:-3}"
  done
}

# uk_password_ok <file>: Uptime Kuma's own rule, judged on the exact bytes of the file. It calls
# check-password-strength 2.0.10 (server/server.js:707 in 2.5.12) and refuses "Too weak": under 6
# characters, or fewer than two of lowercase, uppercase, digits and symbols (ASCII punctuation).
# Only printable ASCII is accepted, so the password is one the customer can type in the login form;
# anything else deterministically takes the generated fallback. Every order-form password (8 to 64
# printable ASCII characters with an uppercase letter and a digit) passes.
uk_password_ok() {
  local LC_ALL=C pw kinds=0
  pw="$(
    cat "$1"
    printf x
  )"
  pw="${pw%x}"
  [[ "$pw" =~ ^[[:print:]]+$ ]] || return 1
  [ "${#pw}" -ge 6 ] || return 1
  if [[ "$pw" =~ [a-z] ]]; then kinds=$((kinds + 1)); fi
  if [[ "$pw" =~ [A-Z] ]]; then kinds=$((kinds + 1)); fi
  if [[ "$pw" =~ [0-9] ]]; then kinds=$((kinds + 1)); fi
  if [[ "$pw" =~ [[:punct:]] ]]; then kinds=$((kinds + 1)); fi
  [ "$kinds" -ge 2 ]
}

# uk_fallback_password_file <file>: write a password that satisfies Uptime Kuma's rule into <file>
# and keep it in /root/vps-apps-credentials.txt (mode 600). A retry reuses the one already there.
uk_fallback_password_file() {
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
      printf 'Uptime Kuma admin login, generated because the password you chose does not meet Uptime Kuma rules\nUsername: %s\nPassword: %s\n' \
        "$VA_UK_USERNAME" "$(cat "$1")" | write_atomic "$cred" 0600
    )
  fi
}

# uk_setup_admin <password-file>: admin.js setup with the password on stdin, against the loopback
# server, with this server's address for the Primary Base URL. 0 when the admin exists and logs in
# with that password, 2 when Uptime Kuma finds the password too weak, 1 for anything else.
uk_setup_admin() {
  local rc=0
  uk_client setup "https://$VA_HOST" <"$1" || rc=$?
  case "$rc" in
    0 | 2) return "$rc" ;;
    *)
      log "uptimekuma: the admin setup failed (exit $rc)"
      return 1
      ;;
  esac
}

# app_create_admin <password-file>: the admin account through Uptime Kuma's first-run setup on the
# loopback server (admin.js setup), then a login with the same password, so a retry after the account
# was made counts only when the password opens it. A password that breaks Uptime Kuma's rule (by our
# check or by Uptime Kuma's own answer) is replaced by a generated one in
# /root/vps-apps-credentials.txt, and the call is made again. Once that file exists, a retry uses it.
app_create_admin() {
  local pwfile="$1" tmp rc=0
  tmp="$(mktemp "$(app_data_dir)/.admin-pw.XXXXXX")"
  chmod 600 "$tmp"
  if [ -f "$(p /root/vps-apps-credentials.txt)" ]; then
    log "uptimekuma: a generated password is already in /root/vps-apps-credentials.txt, using it"
    uk_fallback_password_file "$tmp"
    pwfile="$tmp"
  elif ! uk_password_ok "$pwfile"; then
    log "uptimekuma: the chosen password does not meet Uptime Kuma's rule, using a generated one"
    uk_fallback_password_file "$tmp"
    pwfile="$tmp"
  fi
  if uk_wait_for_api; then
    uk_setup_admin "$pwfile" || rc=$?
    if [ "$rc" -eq 2 ] && [ "$pwfile" != "$tmp" ]; then
      log "uptimekuma: Uptime Kuma rejected the chosen password, using a generated one"
      uk_fallback_password_file "$tmp"
      rc=0
      uk_setup_admin "$tmp" || rc=$?
    fi
  else
    rc=1
  fi
  rm -f "$tmp"
  [ "$rc" -eq 0 ] || return 1
}

# uk_setup_still_offered: succeeds unless Uptime Kuma says, readably, that it no longer offers its
# first-run setup (its needSetup answer is false). Fails closed.
uk_setup_still_offered() {
  local out
  out="$(uk_client need-setup </dev/null 2>/dev/null)" || return 0
  [ "$out" = false ] || return 0
  return 1
}

# app_expose: first puts the stack back into setup state (marker removed, Uptime Kuma published on
# the loopback port only) and waits for it. That makes a retry after a failed or interrupted expose
# recover on its own, and it is where the admin check can be made. Then it refuses while Uptime Kuma
# still offers its setup, so an Uptime Kuma without an account is never put on the internet.
app_expose() {
  rm -f "$(app_data_dir)/exposed"
  if ! app_compose up -d; then
    log "uptimekuma: cannot bring the setup stack up before exposing"
    return 1
  fi
  if ! uk_wait_for_api; then
    return 1
  fi
  if uk_setup_still_offered; then
    log "uptimekuma: refusing to expose, the first-run setup is still offered or its state is unreadable"
    return 1
  fi
  : >"$(app_data_dir)/exposed"
  set_site_mode app
  if ! app_compose up -d; then
    log "uptimekuma: starting the exposed stack failed"
    # Stop whatever came up, drop the marker (so rc names the setup file again) and show the failed
    # page instead of leaving a half-exposed server.
    app_compose down || true
    rm -f "$(app_data_dir)/exposed"
    set_site_mode failed
    return 1
  fi
}

# Uptime Kuma's main server must answer its entry page over HTTPS on the server's own name with a
# valid certificate. The body is captured first: a pipe into a reader can fail curl with error 23
# under pipefail.
app_ready_check() {
  local body
  body="$(curl -fsS --max-time 10 --resolve "$VA_HOST:443:127.0.0.1" "https://$VA_HOST/api/entry-page")" || return 1
  [ "$(jq -r '.type // empty' <<<"$body" 2>/dev/null)" = entryPage ]
}

# app_domain_added <domain>: rewrite the address list from the host and /etc/vps-apps/domains, so
# every name stays served, and recreate Uptime Kuma with the new labels. Uptime Kuma serves the
# dashboard on any name and a status page on the names mapped to it in that page's settings, so it
# needs nothing else.
app_domain_added() {
  local env_file line out="" site_addrs
  env_file="$(app_data_dir)/.env"
  site_addrs="$(app_site_addrs)"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" != VA_SITE_ADDRS=* ]] || line="VA_SITE_ADDRS=\"$site_addrs\""
    out+="$line"$'\n'
  done <"$env_file"
  printf '%s' "$out" | write_atomic "$env_file" 0600
  app_compose up -d
}
