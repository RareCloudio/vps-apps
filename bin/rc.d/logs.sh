#!/usr/bin/env bash
# rc logs [service]. Sourced by bin/rc.

rc_logs() {
  [ "$#" -le 1 ] || rc_usage
  # A service name starts with a letter or digit, so it can never be read as an option.
  if [ "$#" -eq 1 ] && ! [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "rc logs: '$1' is not a service name" >&2
    exit 2
  fi
  rc_load_app
  rc_compose logs --tail 200 -f "$@"
}
