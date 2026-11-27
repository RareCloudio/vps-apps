#!/usr/bin/env bash
# Shared helpers: path prefixing and logging. Sourced, never executed.
# Every filesystem path goes through p so tests can run in a temp root.

# p <abs-path>: echo the path under VPS_APPS_ROOT (empty on a real server).
p() {
  printf '%s%s\n' "${VPS_APPS_ROOT:-}" "$1"
}

# log <msg>: append "<ISO-8601 UTC> <msg>" to the install log.
log() {
  local file
  file="$(p /var/log/vps-apps-install.log)"
  mkdir -p "$(dirname "$file")"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$file"
}

# write_atomic <dest> <mode>: store stdin as <dest> through a temp file in the destination's own
# directory (same filesystem) and a rename, so a reader never sees a partial file, including a
# container reading a mounted directory. The temp file is removed if any step fails.
write_atomic() {
  local dest="$1" mode="$2" tmp
  tmp="$(mktemp "$(dirname "$dest")/.tmp.XXXXXX")" || return 1
  if ! { cat >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# read_app_env: the installed app's settings, read as data (never sourced), into VA_APP, VA_MODE,
# VA_HOST (lowercased), VA_IP and VA_ADMIN_EMAIL, and the file's path into VA_ENV_FILE. The file is
# /etc/vps-apps/app.env, which install.sh writes from its validated arguments; a server installed
# before app.env existed only has the bootstrap's /etc/vps-apps/env. Fails when neither can be
# read. The values are not validated here.
# shellcheck disable=SC2034 # the variables are the result, read by the callers
read_app_env() {
  local key value
  VA_ENV_FILE="$(p /etc/vps-apps/app.env)"
  [ -r "$VA_ENV_FILE" ] || VA_ENV_FILE="$(p /etc/vps-apps/env)"
  [ -r "$VA_ENV_FILE" ] || return 1
  VA_APP="" VA_MODE="" VA_HOST="" VA_IP="" VA_ADMIN_EMAIL=""
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      APP) VA_APP="$value" ;;
      MODE) VA_MODE="$value" ;;
      VA_HOST) VA_HOST="${value,,}" ;;
      VA_IP) VA_IP="$value" ;;
      ADMIN_EMAIL) VA_ADMIN_EMAIL="$value" ;;
    esac
  done <"$VA_ENV_FILE"
}

# valid_email <address>: a conservative lowercase address that n8n accepts as its owner login: a
# local part of a-z, 0-9 and . _ % + - (no dot at either end or twice in a row, 64 characters at
# most), an @, and a DNS name whose last label is 2 to 63 letters; 254 characters in total. The
# bootstrap embedded in the recipe checks the same email_re.
valid_email() {
  local email_re='^[a-z0-9_%+-]+(\.[a-z0-9_%+-]+)*@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
  local local_part="${1%@*}"
  [ "${#1}" -le 254 ] && [ "${#local_part}" -le 64 ] && [[ "$1" =~ $email_re ]]
}

# valid_hostname <name>: a lowercase DNS name with at least two labels, each 1 to 63 characters of
# a-z, 0-9 and hyphen (not at either end), 253 characters in total. The one rule every entry point
# (install.sh, rc) uses.
valid_hostname() {
  local name="$1"
  local re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
  [ "${#name}" -le 253 ] && [[ "$name" =~ $re ]]
}

# valid_ipv4 <addr>: a dotted quad with every octet 0 to 255.
valid_ipv4() {
  local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  [[ "$1" =~ ^${octet}(\.${octet}){3}$ ]]
}
