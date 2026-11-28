#!/usr/bin/env bash
# Shared by the two CI runner apps, ghrunner (GitHub Actions) and glrunner (GitLab Runner): the
# registration page, its login, and the root unit that registers the runner. Sourced by
# apps/<app>/app.sh, never executed. The app sets VA_APP_DIR, VA_RUNNER_APP (its slug) and
# VA_RUNNER_KIND (github or gitlab) first, and defines runner_register (see runner_handle_request).
# This directory is not an app: install.sh and rc load apps/<slug>/app.sh only for a slug on their
# allowlist, and "_runner-common" can never be one.
#
# Why a page: an order cannot carry the registration token (WHMCS and Virtualizor pass no custom
# field to the recipe), so the runner is installed unregistered and the customer registers it from
# https://<host>/ with the token from GitHub or GitLab. In order:
#   1. app_create_admin makes the page's login before anything is exposed: user admin, the order
#      password bcrypt-hashed by `caddy hash-password` (the proxy's own pinned image), from stdin.
#      The hash goes into the app .env; compose.expose.yml refuses to render without it, and
#      app_expose refuses too. So https://<host>/ never answers without the login.
#   2. page.py, behind Caddy basic auth, runs as the unprivileged user vps-apps-page on a read-only
#      root filesystem, with no Docker socket. It validates the form and writes one 0600 JSON file,
#      /run/vps-apps-<app>/inbox/request. /run is a tmpfs, so the token never reaches a disk.
#   3. The path unit vps-apps-<app>-register.path starts vps-apps-<app>-register.service (root,
#      register.sh), which moves the file into a root-only directory, reads it, deletes it, checks it
#      again (it trusts nothing the page wrote) and calls runner_register with the token in a shell
#      variable. The token reaches the runner's own tool through its environment, never its argv,
#      and no log gets it (runner_redact). The unit writes a small status file the page shows.

# The page needs only Python's standard library. 3.14 is the current Python series (bugfix releases
# until October 2027, security fixes until 2030), so rc update follows its patch releases and stays
# on 3.14 (https://devguide.python.org/versions/).
VA_RUNNER_PAGE_IMAGE_REF="python:3.14-alpine"
VA_RUNNER_PAGE_USER="vps-apps-page"
VA_RUNNER_LOGIN="admin"
VA_RUNNER_MAX_REQUEST=4096

app_data_dir() {
  p "/opt/vps-apps-data/$VA_RUNNER_APP"
}

# runner_run_dir: the tmpfs directory of the inbox (the page's) and the work directory (root's).
runner_run_dir() {
  p "/run/vps-apps-$VA_RUNNER_APP"
}

runner_status_file() {
  printf '%s/status/status.json\n' "$(app_data_dir)"
}

app_compose_files() {
  printf '%s\n' "$VA_APP_DIR/compose.yml"
  if [ -f "$(app_data_dir)/exposed" ]; then
    printf '%s\n' "$VA_APP_DIR/compose.expose.yml"
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

# runner_name: the runner's name in GitHub or GitLab, the first label of the server's name.
runner_name() {
  printf '%s\n' "${VA_HOST%%.*}"
}

# runner_env_get <file> <key>: the value on the key's last line, as written.
runner_env_get() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

# runner_env_put <file> <key> <value>: the key on one line, KEY=value, in place of its first line
# (later ones dropped) or appended; every other line kept. Replaced atomically, mode 0600.
runner_env_put() {
  local file="$1" key="$2" value="$3" line out="" put=no
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "$key="* ]]; then
      [ "$put" = no ] || continue
      line="$key=$value" put=yes
    fi
    out+="$line"$'\n'
  done <"$file"
  [ "$put" = yes ] || out+="$key=$value"$'\n'
  printf '%s' "$out" | write_atomic "$file" 0600
}

# runner_render_env <var-array-name>: env.tmpl with every @KEY@ replaced literally by the value of
# that key in the named associative array, on stdout.
runner_render_env() {
  local -n vars_ref="$1"
  local line key out=""
  while IFS= read -r line || [ -n "$line" ]; do
    for key in "${!vars_ref[@]}"; do
      line="${line//@${key}@/"${vars_ref[$key]}"}"
    done
    out+="$line"$'\n'
  done <"$VA_APP_DIR/env.tmpl"
  printf '%s' "$out"
}

# runner_ensure_user <name> [useradd args...]: a system user and its own group, made once. Nobody
# logs in as it.
runner_ensure_user() {
  local name="$1"
  shift
  id -u "$name" >/dev/null 2>&1 && return 0
  useradd --system --user-group --shell /usr/sbin/nologin "$@" "$name"
}

# runner_prepare_host <page-uid> <page-gid>: what the host keeps for the page and the root unit.
#   - /run/vps-apps-<app>/inbox, the page user's (0700), and /run/vps-apps-<app>/work, root's (0700),
#     made now and at every boot by tmpfiles.d (before Docker starts the page);
#   - the status directory (root, 0755, mounted read-only into the page) with "not registered yet";
#   - the path unit and the root service that registers, enabled.
# Rewritten whole on every run; an existing status is kept. Every step checks its result, since the
# callers run it inside a condition, where errexit is off.
runner_prepare_host() {
  local uid="$1" gid="$2" run unit_dir tmpfiles app="$VA_RUNNER_APP" status_dir
  run="$(runner_run_dir)"
  status_dir="$(dirname "$(runner_status_file)")"
  if ! { mkdir -p "$run/inbox" "$run/work" "$status_dir" && chmod 0755 "$run" "$status_dir" &&
    chown "$uid:$gid" "$run/inbox" && chmod 0700 "$run/inbox" "$run/work"; }; then
    log "$VA_RUNNER_APP: cannot make the page's inbox and status directories"
    return 1
  fi
  if [ ! -f "$(runner_status_file)" ]; then
    runner_write_status none "Not registered yet." "" || return 1
  fi

  tmpfiles="$(p /etc/tmpfiles.d)"
  unit_dir="$(p /etc/systemd/system)"
  mkdir -p "$tmpfiles" "$unit_dir" || return 1
  write_atomic "$tmpfiles/vps-apps-$app.conf" 0644 <<CONF || return 1
# vps-apps $app: the registration page's inbox and the root unit's work directory (tmpfs).
d /run/vps-apps-$app 0755 root root -
d /run/vps-apps-$app/inbox 0700 $VA_RUNNER_PAGE_USER $VA_RUNNER_PAGE_USER -
d /run/vps-apps-$app/work 0700 root root -
CONF
  write_atomic "$unit_dir/vps-apps-$app-register.path" 0644 <<UNIT || return 1
[Unit]
Description=vps-apps: a runner registration request from the page

[Path]
PathExists=/run/vps-apps-$app/inbox/request
Unit=vps-apps-$app-register.service

[Install]
WantedBy=multi-user.target
UNIT
  # Root on purpose (no User=): it reads the request out of the page's reach and runs the runner's
  # registration. TMPDIR keeps anything bash or a tool writes on the tmpfs.
  write_atomic "$unit_dir/vps-apps-$app-register.service" 0644 <<UNIT || return 1
[Unit]
Description=vps-apps: register the runner from the page's request
After=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash /opt/vps-apps/current/apps/_runner-common/register.sh $app
Environment=TMPDIR=/run/vps-apps-$app/work
UMask=0077
TimeoutStartSec=10min
UNIT
  systemctl daemon-reload || return 1
  systemctl enable --now "vps-apps-$app-register.path"
}

# runner_page_env_vars <array-name>: the page's keys for env.tmpl (image, user, site names) into the
# named associative array. Resolves the page image; fails when it cannot.
runner_page_env_vars() {
  local -n page_vars="$1"
  local image uid gid
  image="$(resolve_image_digest "$VA_RUNNER_PAGE_IMAGE_REF")" || return 1
  uid="$(id -u "$VA_RUNNER_PAGE_USER")" || return 1
  gid="$(id -g "$VA_RUNNER_PAGE_USER")" || return 1
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 1
  # shellcheck disable=SC2034 # filled for the caller through the nameref
  page_vars=(
    [PAGE_IMAGE]="$image" [PAGE_IMAGE_REF]="$VA_RUNNER_PAGE_IMAGE_REF"
    [PAGE_UID]="$uid" [PAGE_GID]="$gid"
    [VA_SITE_ADDRS]="$(app_site_addrs)"
  )
}

# runner_prepare_page: the page user and the host side (runner_prepare_host). The app writes the
# .env itself, once.
runner_prepare_page() {
  local uid gid
  runner_ensure_user "$VA_RUNNER_PAGE_USER" --no-create-home --home-dir /nonexistent || return 1
  uid="$(id -u "$VA_RUNNER_PAGE_USER")" || return 1
  gid="$(id -g "$VA_RUNNER_PAGE_USER")" || return 1
  runner_prepare_host "$uid" "$gid"
}

# runner_password_ok <file>: the login's rule, judged on the exact bytes of the file: 1 to 72
# printable ASCII characters. 72 is bcrypt's limit (Go's bcrypt refuses a longer password). Every
# order-form password (8 to 64 printable ASCII characters, no spaces) passes.
runner_password_ok() {
  local LC_ALL=C pw
  pw="$(
    cat "$1"
    printf x
  )"
  pw="${pw%x}"
  [[ "$pw" =~ ^[[:print:]]+$ ]] && [ "${#pw}" -le 72 ]
}

# runner_fallback_password_file <file>: write a password the login takes into <file> and keep it in
# /root/vps-apps-credentials.txt (mode 600). A retry reuses the one already stored there.
runner_fallback_password_file() {
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
    printf 'Runner page login, generated because the password you chose cannot be used for it\nUsername: %s\nPassword: %s\n' \
      "$VA_RUNNER_LOGIN" "$(cat "$1")" | write_atomic "$cred" 0600
  fi
}

# runner_caddy_image: the proxy's own Caddy image, pinned by digest in its .env (base/60-proxy.sh).
runner_caddy_image() {
  local img
  img="$(runner_env_get "$(p /opt/vps-apps-data/proxy/.env)" CADDY_IMAGE 2>/dev/null)" || return 1
  [[ "$img" =~ ^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$img"
}

# shellcheck disable=SC2016 # a regular expression: the dollar signs are literal
VA_RUNNER_HASH_RE='^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$'

# runner_hash_password <password-file>: the bcrypt hash Caddy's basic_auth checks, from
# `caddy hash-password` in the proxy's own image, without network. The password goes to it on stdin
# with one newline after it: without a terminal, hash-password reads one line and drops that newline
# (cmdHashPassword in modules/caddyhttp/caddyauth/command.go, Caddy 2.11.4, the version in
# caddy-docker-proxy 2.13.1; https://caddyserver.com/docs/command-line#caddy-hash-password).
# Cost 10, as for Grafana's push credential: Caddy checks every login attempt, and its default cost
# of 14 lets anyone without the password keep a CPU busy with wrong guesses. The order password's
# length and character rule is what keeps online guessing impractical.
VA_RUNNER_BCRYPT_COST=10
runner_hash_password() {
  local img out
  img="$(runner_caddy_image)" || {
    log "$VA_RUNNER_APP: no pinned Caddy image in the proxy .env"
    return 1
  }
  out="$({
    cat "$1"
    printf '\n'
  } | docker run --rm -i --network none --entrypoint caddy "$img" hash-password --algorithm bcrypt \
    --bcrypt-cost "$VA_RUNNER_BCRYPT_COST")" || return 1
  out="${out//[[:space:]]/}"
  [[ "$out" =~ $VA_RUNNER_HASH_RE ]] || return 1
  printf '%s\n' "$out"
}

# runner_login_ready: the .env carries a bcrypt hash for the login, single-quoted (compose reads a
# single-quoted value literally; unquoted, it would take the $ in the hash for variables).
runner_login_ready() {
  local h
  h="$(runner_env_get "$(app_data_dir)/.env" RUNNER_PAGE_AUTH_HASH)"
  [[ "$h" == \'*\' ]] || return 1
  h="${h#\'}"
  h="${h%\'}"
  [[ "$h" =~ $VA_RUNNER_HASH_RE ]]
}

# app_create_admin <password-file>: the page's login, user admin with the order password, as a
# bcrypt hash in the app .env (RUNNER_PAGE_AUTH_HASH). A password the login cannot take is replaced
# by a generated one in /root/vps-apps-credentials.txt; once that file exists, a retry uses it. A
# retry hashes again (a new salt, the same password): the step can always run again.
app_create_admin() {
  local pwfile="$1" tmp hash="" rc=0
  tmp="$(mktemp "$(app_data_dir)/.login-pw.XXXXXX")" || return 1
  chmod 600 "$tmp"
  if [ -f "$(p /root/vps-apps-credentials.txt)" ]; then
    log "$VA_RUNNER_APP: a generated password is already in /root/vps-apps-credentials.txt, using it"
    runner_fallback_password_file "$tmp" || rc=1
    pwfile="$tmp"
  elif ! runner_password_ok "$pwfile"; then
    log "$VA_RUNNER_APP: the chosen password cannot be used for the page login, using a generated one"
    runner_fallback_password_file "$tmp" || rc=1
    pwfile="$tmp"
  fi
  if [ "$rc" -eq 0 ]; then
    hash="$(runner_hash_password "$pwfile")" || rc=1
  fi
  rm -f "$tmp"
  if [ "$rc" -ne 0 ]; then
    log "$VA_RUNNER_APP: hashing the page login failed"
    return 1
  fi
  runner_env_put "$(app_data_dir)/.env" RUNNER_PAGE_AUTH_HASH "'$hash'"
}

# app_expose: first puts the stack back into setup state (marker removed, the page on no proxy
# network) and starts it, which makes a retry after a failed or interrupted expose recover on its
# own. It refuses unless the login exists, so the page is never on the internet without it. Then it
# writes the marker and starts the stack with the caddy labels.
app_expose() {
  rm -f "$(app_data_dir)/exposed"
  if ! app_compose up -d; then
    log "$VA_RUNNER_APP: cannot bring the setup stack up before exposing"
    return 1
  fi
  if ! runner_login_ready; then
    log "$VA_RUNNER_APP: refusing to expose, the page login does not exist"
    return 1
  fi
  : >"$(app_data_dir)/exposed"
  set_site_mode app
  if ! app_compose up -d; then
    log "$VA_RUNNER_APP: starting the exposed stack failed"
    # Stop whatever came up, drop the marker and show the failed page instead of leaving a
    # half-exposed server.
    app_compose down || true
    rm -f "$(app_data_dir)/exposed"
    set_site_mode failed
    return 1
  fi
}

# runner_basic_header <header-file>: the login as an Authorization header line, from the generated
# password when there is one, else from the password file install.sh hands the app
# (VA_PASSWORD_FILE). The password reaches base64 on stdin, never an argument.
runner_basic_header() {
  local cred pw
  cred="$(p /root/vps-apps-credentials.txt)"
  if [ -f "$cred" ]; then
    pw="$(sed -n 's/^Password: //p' "$cred" | head -n1)"
    [ -n "$pw" ] || return 1
    printf 'Authorization: Basic %s\n' "$(printf '%s:%s' "$VA_RUNNER_LOGIN" "$pw" | base64 -w0)" >"$1"
  else
    [ -r "${VA_PASSWORD_FILE:-}" ] || return 1
    printf 'Authorization: Basic %s\n' "$({
      printf '%s:' "$VA_RUNNER_LOGIN"
      cat "$VA_PASSWORD_FILE"
    } | base64 -w0)" >"$1"
  fi
}

# app_ready_check: over HTTPS on the server's own name, with a valid certificate, the page must ask
# for the login (401 with a Basic challenge, so the gate is closed), and the login must open it
# (/healthz answers ok). The credential travels in a 0600 header file (curl -H @file), never as an
# argument. The bodies are captured first: a pipe into a reader can fail curl under pipefail.
app_ready_check() {
  local head body work rc=1
  head="$(curl -sS -o /dev/null -D - --max-time 10 --resolve "$VA_HOST:443:127.0.0.1" "https://$VA_HOST/")" || return 1
  [[ "$head" =~ ^HTTP/[0-9.]+\ 401[[:space:]] ]] || return 1
  grep -qi '^www-authenticate: *basic' <<<"$head" || return 1
  work="$(mktemp -d "$(app_data_dir)/.ready.XXXXXX")" || return 1
  if (
    umask 077
    runner_basic_header "$work/auth"
  ) && body="$(curl -fsS --max-time 10 --resolve "$VA_HOST:443:127.0.0.1" -H "@$work/auth" \
    "https://$VA_HOST/healthz")" && [ "$body" = ok ]; then
    rc=0
  fi
  rm -rf "$work"
  return "$rc"
}

# app_domain_added <domain>: rewrite the address list from the host and /etc/vps-apps/domains, so
# every name stays served (all behind the same login), and recreate the page with the new labels.
# The page itself needs no name: it checks a form's Origin against the Host it was asked for.
app_domain_added() {
  local env_file line out=""
  env_file="$(app_data_dir)/.env"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" != VA_SITE_ADDRS=* ]] || line="VA_SITE_ADDRS=\"$(app_site_addrs)\""
    out+="$line"$'\n'
  done <"$env_file"
  printf '%s' "$out" | write_atomic "$env_file" 0600
  app_compose up -d
}

# --- The registration request (the root unit, register.sh) ---------------------------------------

# runner_say <message>: one line on stdout, which the register unit's journal keeps.
runner_say() {
  printf '%s: %s\n' "$VA_RUNNER_APP" "$*"
}

# runner_write_status <state> <message> <url>: the status the page shows, replaced atomically,
# mode 0644 (the page reads it). state is none, working, registered or failed; url is the address
# the runner is registered with now, empty when it is not. Never carries a token.
runner_write_status() {
  local f
  f="$(runner_status_file)"
  mkdir -p "$(dirname "$f")"
  jq -n --arg s "$1" --arg m "$2" --arg u "$3" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{state: $s, message: $m, url: $u, updated: $t}' | write_atomic "$f" 0644
}

# runner_status_url: the address in the status file when it is a valid one, else nothing.
runner_status_url() {
  local u
  u="$(jq -r '.url // "" | strings' "$(runner_status_file)" 2>/dev/null)" || return 0
  if runner_valid_url "$u"; then
    printf '%s\n' "$u"
  fi
}

# The address and token rules, the same as page.py's (valid_url, valid_token), on the address as
# the page normalized it. The tests run both on one table of cases.
VA_RUNNER_GH_URL_RE='^https://github\.com/[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?(/[A-Za-z0-9._-]{1,100})?$'
VA_RUNNER_GL_URL_RE='^https://([^/:]+)(:([0-9]{1,5}))?((/[A-Za-z0-9._~-]+)*)$'
VA_RUNNER_GL_HOST_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'

# runner_valid_url <url>: a GitHub repository or organization address, https://github.com/<owner>
# or https://github.com/<owner>/<repo>; or a GitLab instance over HTTPS, with an optional port and
# path (a GitLab under a relative URL).
runner_valid_url() {
  local LC_ALL=C u="$1" repo host port path seg
  local -a segs=()
  case "$VA_RUNNER_KIND" in
    github)
      if [ "${#u}" -gt 200 ] || ! [[ "$u" =~ $VA_RUNNER_GH_URL_RE ]]; then
        return 1
      fi
      repo="${u#https://github.com/}"
      if [[ "$repo" == */* ]]; then
        repo="${repo#*/}"
        case "$repo" in . | .. | *.git) return 1 ;; esac
      fi
      ;;
    gitlab)
      if [ "${#u}" -gt 255 ] || ! [[ "$u" =~ $VA_RUNNER_GL_URL_RE ]]; then
        return 1
      fi
      host="${BASH_REMATCH[1]}" port="${BASH_REMATCH[3]}" path="${BASH_REMATCH[4]}"
      if [ "${#host}" -gt 253 ] || ! [[ "$host" =~ $VA_RUNNER_GL_HOST_RE ]]; then
        return 1
      fi
      if [ -n "$port" ] && { [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; }; then
        return 1
      fi
      IFS=/ read -r -a segs <<<"${path#/}"
      for seg in "${segs[@]}"; do
        case "$seg" in . | ..) return 1 ;; esac
      done
      ;;
    *) return 1 ;;
  esac
}

# runner_valid_token <token>: a GitHub runner registration token (never a personal access or OAuth
# token), or a GitLab runner authentication token (glrt-, the runner creation flow of GitLab 16 and
# later: https://docs.gitlab.com/runner/register/).
runner_valid_token() {
  local LC_ALL=C
  case "$VA_RUNNER_KIND" in
    github)
      [[ "$1" =~ ^[A-Za-z0-9_-]{20,255}$ ]] || return 1
      case "$1" in ghp_* | gho_* | ghu_* | ghs_* | ghr_* | github_pat_*) return 1 ;; esac
      ;;
    gitlab) [[ "$1" =~ ^glrt-[A-Za-z0-9_.-]{20,250}$ ]] ;;
    *) return 1 ;;
  esac
}

# runner_redact <secret>: stdin to stdout with the secret, every 8-character piece of it, and any
# GitLab runner token replaced by [hidden], so no part of a token long enough to matter reaches a
# log. At most 4000 characters come out.
runner_redact() {
  local s="$1" out i
  out="$(head -c 16000)"
  if [ -n "$s" ]; then
    out="${out//"$s"/[hidden]}"
    for ((i = 0; i + 8 <= ${#s}; i++)); do
      out="${out//"${s:i:8}"/[hidden]}"
    done
  fi
  out="$(sed -E 's/glrt-[A-Za-z0-9_.-]+/glrt-[hidden]/g' <<<"$out")"
  printf '%s\n' "${out:0:4000}"
}

# runner_take_request: the page's request, moved out of the inbox into the root-only work directory
# (a rename, so the page cannot change it afterwards), checked to be what the page writes (a regular
# file of the page user with one link and at most 4096 bytes), read into RUNNER_REQUEST and deleted.
# 1 when there is no request; 2 when there was one that cannot be used (it is deleted all the same).
# A symlink or a hard link the page planted is moved and deleted, never followed.
runner_take_request() {
  local inbox work req info uid type owner links size
  inbox="$(runner_run_dir)/inbox/request"
  work="$(runner_run_dir)/work"
  req="$work/request"
  RUNNER_REQUEST=""
  [ -e "$inbox" ] || [ -L "$inbox" ] || return 1
  if ! { mkdir -p "$work" && chmod 0700 "$work"; }; then
    return 2
  fi
  rm -rf -- "$req"
  if ! mv -fT -- "$inbox" "$req" 2>/dev/null; then
    rm -rf -- "$inbox"
    return 2
  fi
  uid="$(runner_env_get "$(app_data_dir)/.env" PAGE_UID)"
  info="$(stat -c '%F|%u|%h|%s' -- "$req" 2>/dev/null)" || info=""
  IFS='|' read -r type owner links size <<<"$info"
  if [ "$type" != "regular file" ] || [ -z "$uid" ] || [ "$owner" != "$uid" ] || [ "$links" != 1 ] ||
    ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -gt "$VA_RUNNER_MAX_REQUEST" ]; then
    rm -rf -- "$req"
    return 2
  fi
  RUNNER_REQUEST="$(head -c "$VA_RUNNER_MAX_REQUEST" -- "$req")"
  rm -f -- "$req"
}

# runner_parse_request: RUNNER_URL and RUNNER_TOKEN from RUNNER_REQUEST, a JSON object with exactly
# the string keys url and token, both valid. jq prints them into shell variables: no argv, no file.
runner_parse_request() {
  # shellcheck disable=SC2016 # a jq program, not shell
  local filter='if type == "object" and (keys == ["token", "url"]) and (.url | type) == "string" and (.token | type) == "string" then .[$k] else error("bad request") end'
  RUNNER_URL="" RUNNER_TOKEN=""
  RUNNER_URL="$(jq -er --arg k url "$filter" <<<"$RUNNER_REQUEST" 2>/dev/null)" || return 1
  RUNNER_TOKEN="$(jq -er --arg k token "$filter" <<<"$RUNNER_REQUEST" 2>/dev/null)" || return 1
  runner_valid_url "$RUNNER_URL" && runner_valid_token "$RUNNER_TOKEN"
}

# runner_handle_request: one run of the register unit. Takes the request (runner_take_request),
# checks it (runner_parse_request) and calls the app's runner_register <url> with the token in
# RUNNER_TOKEN. runner_register sets RUNNER_RESULT (the message the page shows) and RUNNER_KEPT
# (yes when a failed attempt left the earlier registration in place). Every outcome writes the
# status. One run at a time (flock on fd 8, open only for the call), however the unit was started.
runner_handle_request() {
  local work
  work="$(runner_run_dir)/work"
  if ! { mkdir -p "$work" && chmod 0700 "$work"; }; then
    return 1
  fi
  runner_handle_locked 8>"$work/.lock"
}

runner_handle_locked() {
  local rc=0 before
  flock -w 300 8 || return 1
  runner_take_request || rc=$?
  case "$rc" in
    1) return 0 ;;
    2)
      runner_say "a request that is not a regular file of the page user was dropped"
      runner_write_status failed "The request could not be read. Send the form again." "$(runner_status_url)"
      return 1
      ;;
  esac
  if ! runner_parse_request; then
    RUNNER_TOKEN="" RUNNER_REQUEST=""
    runner_say "a request with an invalid address or token was dropped"
    runner_write_status failed "The address or the token is not valid. Send the form again." "$(runner_status_url)"
    return 1
  fi
  RUNNER_REQUEST=""
  before="$(runner_status_url)"
  runner_write_status working "Registering with $RUNNER_URL." "$before"
  runner_say "registering with $RUNNER_URL"
  RUNNER_RESULT="" RUNNER_KEPT=no
  runner_register "$RUNNER_URL" || rc=$?
  RUNNER_TOKEN=""
  if [ "$rc" -eq 0 ]; then
    runner_say "registered with $RUNNER_URL"
    runner_write_status registered "${RUNNER_RESULT:-Registered with $RUNNER_URL.}" "$RUNNER_URL"
    return 0
  fi
  runner_say "the registration with $RUNNER_URL failed"
  if [ "$RUNNER_KEPT" != yes ]; then
    before=""
  fi
  runner_write_status failed "${RUNNER_RESULT:-The registration failed.}" "$before"
  return 1
}

# runner_finish_interrupted: register.sh's exit trap. A run that died while the status said
# "working" says so, so the page does not wait forever.
runner_finish_interrupted() {
  local state
  state="$(jq -r '.state // ""' "$(runner_status_file)" 2>/dev/null)" || return 0
  if [ "$state" = working ]; then
    runner_write_status failed "The registration was interrupted. Send the form again." "$(runner_status_url)"
  fi
}
