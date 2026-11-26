#!/usr/bin/env bash
# Turns a fresh Ubuntu 24.04 VPS into a Docker or n8n server.
# Usage: install.sh --app <docker|n8n> --host <fqdn> --ip <ipv4> --password-file <path> [--mode starter|pro]
# Exit codes: 0 done, 1 a failed step (retryable), 2 bad arguments, 3 the wrong OS.
set -euo pipefail

VA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$VA_ROOT/lib/common.sh"
# shellcheck source=lib/steps.sh
. "$VA_ROOT/lib/steps.sh"

usage_error() {
  echo "install.sh: $1" >&2
  echo "usage: install.sh --app <docker|n8n> --host <fqdn> --ip <ipv4> --password-file <path> [--mode starter|pro]" >&2
  exit 2
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

parse_args() {
  VA_APP="" VA_HOST="" VA_IP="" VA_PASSWORD_FILE="" VA_MODE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --app | --host | --ip | --password-file | --mode)
        [ $# -ge 2 ] || usage_error "$1 needs a value"
        case "$1" in
          --app) VA_APP="$2" ;;
          --host) VA_HOST="$2" ;;
          --ip) VA_IP="$2" ;;
          --password-file) VA_PASSWORD_FILE="$2" ;;
          --mode) VA_MODE="$2" ;;
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

  local host_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
  [ -n "$VA_HOST" ] || usage_error "--host is required"
  [[ "$VA_HOST" =~ $host_re ]] || usage_error "--host is not a valid hostname"

  local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  local ip_re="^${octet}(\\.${octet}){3}\$"
  [ -n "$VA_IP" ] || usage_error "--ip is required"
  [[ "$VA_IP" =~ $ip_re ]] || usage_error "--ip is not a valid IPv4 address"

  [ -n "$VA_PASSWORD_FILE" ] || usage_error "--password-file is required"
  [ -f "$VA_PASSWORD_FILE" ] || usage_error "--password-file does not exist"

  if [ -n "$VA_MODE" ]; then
    [ "$VA_APP" = "n8n" ] || usage_error "--mode is only valid with --app n8n"
    case "$VA_MODE" in
      starter | pro) ;;
      *) usage_error "--mode must be starter or pro" ;;
    esac
  fi
}

main() {
  parse_args "$@"
  require_ubuntu_2404
  log "install.sh: arguments ok (app=$VA_APP host=$VA_HOST ip=$VA_IP)"
}

main "$@"
