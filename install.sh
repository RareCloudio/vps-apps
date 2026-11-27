#!/usr/bin/env bash
# Turns a fresh Ubuntu 24.04 VPS into a Docker or n8n server.
# Usage: install.sh --app <docker|n8n> --host <fqdn> --ip <ipv4> --password-file <path> [--mode starter|pro]
#          [--admin-email <email>]
#        install.sh --site-failed   (the bootstrap, after its last attempt: see site_failed)
# Exit codes: 0 done, 1 a failed step (retryable), 2 bad arguments, 3 the wrong OS.
set -euo pipefail

VA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$VA_ROOT/lib/common.sh"
# shellcheck source=lib/steps.sh
. "$VA_ROOT/lib/steps.sh"

usage_error() {
  echo "install.sh: $1" >&2
  echo "usage: install.sh --app <docker|n8n> --host <fqdn> --ip <ipv4> --password-file <path> [--mode starter|pro]" \
    "[--admin-email <email>]" >&2
  exit 2
}

# require_root: install.sh changes the whole system. A non-empty VPS_APPS_ROOT is a test root, where
# root is not needed (the same rule as rc).
require_root() {
  if [ -z "${VPS_APPS_ROOT:-}" ] && [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: run as root (sudo $0 ...)" >&2
    exit 2
  fi
}

require_ubuntu_2404() {
  local f id version
  f="$(p /etc/os-release)"
  if [ ! -r "$f" ]; then
    echo "install.sh: cannot read $f" >&2
    exit 3
  fi
  id="$(sed -n 's/^ID=//p' "$f" | head -n1 | tr -d '"')"
  version="$(sed -n 's/^VERSION_ID=//p' "$f" | head -n1 | tr -d '"')"
  if [ "$id" != "ubuntu" ] || [ "$version" != "24.04" ]; then
    echo "install.sh: Ubuntu 24.04 is required (found ${id:-unknown} ${version:-unknown})" >&2
    exit 3
  fi
}

# parse_args: the arguments into VA_APP, VA_HOST, VA_IP, VA_PASSWORD_FILE, VA_MODE and
# VA_ADMIN_EMAIL, or exit 2. The owner email is optional and never fatal: it is lowercased, and
# admin@<host> takes its place when it is absent or not a plain address (valid_email).
parse_args() {
  VA_APP="" VA_HOST="" VA_IP="" VA_PASSWORD_FILE="" VA_MODE="" VA_ADMIN_EMAIL=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --app | --host | --ip | --password-file | --mode | --admin-email)
        [ $# -ge 2 ] || usage_error "$1 needs a value"
        case "$1" in
          --app) VA_APP="$2" ;;
          --host) VA_HOST="$2" ;;
          --ip) VA_IP="$2" ;;
          --password-file) VA_PASSWORD_FILE="$2" ;;
          --mode) VA_MODE="$2" ;;
          --admin-email) VA_ADMIN_EMAIL="${2,,}" ;;
        esac
        shift 2
        ;;
      *) usage_error "unknown argument: $1" ;;
    esac
  done

  case "$VA_APP" in
    docker | n8n) ;;
    "") usage_error "--app is required" ;;
    *) usage_error "--app must be docker or n8n" ;;
  esac

  [ -n "$VA_HOST" ] || usage_error "--host is required"
  valid_hostname "$VA_HOST" || usage_error "--host is not a valid hostname"

  [ -n "$VA_IP" ] || usage_error "--ip is required"
  valid_ipv4 "$VA_IP" || usage_error "--ip is not a valid IPv4 address"

  [ -n "$VA_PASSWORD_FILE" ] || usage_error "--password-file is required"
  [ -f "$VA_PASSWORD_FILE" ] || usage_error "--password-file does not exist"

  if [ -n "$VA_MODE" ]; then
    [ "$VA_APP" = "n8n" ] || usage_error "--mode is only valid with --app n8n"
    case "$VA_MODE" in
      starter | pro) ;;
      *) usage_error "--mode must be starter or pro" ;;
    esac
  fi

  if [ -n "$VA_ADMIN_EMAIL" ] && ! valid_email "$VA_ADMIN_EMAIL"; then
    log "install.sh: --admin-email is not a plain address, the owner login is admin@$VA_HOST"
    VA_ADMIN_EMAIL=""
  fi
  [ -n "$VA_ADMIN_EMAIL" ] || VA_ADMIN_EMAIL="admin@$VA_HOST"
}

# record_install: what rc and the login message read later, from the validated arguments.
#   - /etc/vps-apps/app.env holds the settings (no secrets, mode 0644, replaced atomically). The
#     bootstrap's /etc/vps-apps/env is never written: its strict parser refuses any other shape.
#   - /opt/vps-apps/current points at this code. It is changed only when it does not lead here
#     already, and the target is the physical directory, so a run through the link itself never
#     makes the link point at itself. Anything there that is not a symlink is left alone.
record_install() {
  local etc code current
  etc="$(p /etc/vps-apps)"
  mkdir -p "$etc"
  printf 'APP=%s\nMODE=%s\nVA_HOST=%s\nVA_IP=%s\nADMIN_EMAIL=%s\n' \
    "$VA_APP" "$VA_MODE" "$VA_HOST" "$VA_IP" "$VA_ADMIN_EMAIL" | write_atomic "$etc/app.env" 0644
  code="$(cd "$VA_ROOT" && pwd -P)"
  current="$(p /opt/vps-apps/current)"
  if [ "$(cd "$current" 2>/dev/null && pwd -P)" = "$code" ]; then
    return 0
  fi
  if [ -e "$current" ] && [ ! -L "$current" ]; then
    log "install.sh: $current is not a symlink, left as it is"
    return 0
  fi
  mkdir -p "$(dirname "$current")"
  ln -sfn "$code" "$current"
}

# prepare_password: the password as the apps read it, in a copy without the one trailing newline an
# editor or `echo` adds, mode 0600 in the state dir. VA_PASSWORD_FILE then names the copy. It is
# shredded when install.sh exits, and by the bootstrap when it finishes (in case install.sh was
# killed). The given file itself is left as it is.
VA_PASSWORD_COPY=""
prepare_password() {
  local copy last
  copy="$(p /var/lib/vps-apps/.admin-password)"
  mkdir -p "$(dirname "$copy")"
  VA_PASSWORD_COPY="$copy"
  trap remove_password_copy EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  rm -f "$copy"
  (
    umask 077
    : >"$copy"
  )
  chmod 600 "$copy"
  last="$(tail -c 1 "$VA_PASSWORD_FILE" | od -An -tx1 | tr -d ' \n')"
  if [ "$last" = 0a ]; then
    head -c -1 "$VA_PASSWORD_FILE" >"$copy"
  else
    cat "$VA_PASSWORD_FILE" >"$copy"
  fi
  VA_PASSWORD_FILE="$copy"
}

remove_password_copy() {
  if [ -n "$VA_PASSWORD_COPY" ] && [ -e "$VA_PASSWORD_COPY" ]; then
    shred -u "$VA_PASSWORD_COPY" 2>/dev/null || rm -f "$VA_PASSWORD_COPY"
  fi
}

# load_code: the libraries, every base step and the chosen app. Kept in one function so a test can
# replace it with stubs.
load_code() {
  local f
  for f in "$VA_ROOT/lib/apt.sh" "$VA_ROOT/lib/images.sh" "$VA_ROOT/lib/compose.sh" \
    "$VA_ROOT"/base/[0-9][0-9]-*.sh "$VA_ROOT/apps/$VA_APP/app.sh"; do
    # A file that cannot be loaded is a broken download, which a retry can fix: exit 1, not 2.
    # shellcheck source=/dev/null
    if ! . "$f"; then
      log "install.sh: cannot load $f"
      exit 1
    fi
  done
}

# app_create_admin takes the password file; run_step calls a function without arguments.
step_app_create_admin() {
  app_create_admin "$VA_PASSWORD_FILE"
}

# wait_until_ready: app_ready_check retried every VA_READY_INTERVAL seconds (default 5) for
# VA_READY_TIMEOUT seconds (default 300). It is not a step with a marker: a retry of install.sh must
# check again. Sets failed:ready-check and returns 1 when the app never answers.
wait_until_ready() {
  local deadline mode=""
  deadline=$((SECONDS + ${VA_READY_TIMEOUT:-300}))
  set_status installing
  until (app_ready_check); do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "ready check: the app does not answer on https://$VA_HOST"
      set_status failed:ready-check
      return 1
    fi
    sleep "${VA_READY_INTERVAL:-5}"
  done
  [ ! -r "$(p /var/lib/vps-apps/site-mode)" ] || mode="$(cat "$(p /var/lib/vps-apps/site-mode)")"
  if [ "$mode" != app ]; then
    log "ready check: site mode is '$mode', not app"
    set_status failed:ready-check
    return 1
  fi
}

# The steps in their order, as <name>:<function>. A finished step leaves steps/<name>.done.
VA_STEPS=(
  packages:base_packages swap:base_swap sysctl:base_sysctl docker:base_docker
  firewall:base_firewall proxy:base_proxy ssh:base_ssh motd:base_motd
  app_prepare:app_prepare app_up_setup:app_up_setup app_create_admin:step_app_create_admin
  app_expose:app_expose
)

# already_ready: the status is ready and every step has its marker, so there is nothing to do. A
# second run must then not write the status at all (the ready wait would show installing again).
already_ready() {
  local s status=""
  [ ! -r "$(p /var/lib/vps-apps/public/.well-known/rarecloud-app-status)" ] ||
    status="$(cat "$(p /var/lib/vps-apps/public/.well-known/rarecloud-app-status)")"
  [ "$status" = ready ] || return 1
  for s in "${VA_STEPS[@]}"; do
    [ -f "$(p "/var/lib/vps-apps/steps/${s%%:*}.done")" ] || return 1
  done
}

# site_failed: the --site-failed entry point. The bootstrap calls it when its budget is spent or an
# attempt ended for good, so the HTTPS page says the install failed instead of "being set up"
# forever. Only an installing page is replaced (site mode installing or http-only); a server in app
# mode, or with no site yet, is left alone. The host comes from app.env.
site_failed() {
  local mode="" f
  f="$(p /var/lib/vps-apps/site-mode)"
  [ ! -r "$f" ] || mode="$(cat "$f")"
  case "$mode" in
    installing | http-only) ;;
    *) return 0 ;;
  esac
  if ! read_app_env || ! valid_hostname "$VA_HOST"; then
    echo "install.sh: no valid host in $(p /etc/vps-apps/app.env), the page stays as it is" >&2
    return 1
  fi
  # shellcheck source=base/60-proxy.sh
  . "$VA_ROOT/base/60-proxy.sh"
  set_site_mode failed
}

main() {
  local s
  require_root
  if [ "${1:-}" = --site-failed ]; then
    [ "$#" -eq 1 ] || usage_error "--site-failed takes no other argument"
    site_failed
    return
  fi
  parse_args "$@"
  require_ubuntu_2404
  log "install.sh: arguments ok (app=$VA_APP host=$VA_HOST ip=$VA_IP)"
  if already_ready; then
    log "install.sh: already ready, nothing to do"
    return 0
  fi
  record_install
  prepare_password
  # base_proxy and the app read these.
  export VA_HOST VA_IP VA_ADMIN_EMAIL
  load_code

  # run_step stays a plain command (errexit must apply to it), so a failed step ends the install.
  for s in "${VA_STEPS[@]}"; do
    run_step "${s%%:*}" "${s#*:}"
  done
  wait_until_ready
  set_status ready
  log "install.sh: ready"
}

# Run only when executed, so tests can source this file and replace load_code.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
