#!/usr/bin/env bash
# rc status. Sourced by bin/rc.

rc_status() {
  local file status=""
  [ "$#" -eq 0 ] || rc_usage
  rc_load_app
  file="$(p /var/lib/vps-apps/public/.well-known/rarecloud-app-status)"
  [ ! -r "$file" ] || status="$(cat "$file")"
  echo "Status: ${status:-unknown}"
  echo "Host:   https://$VA_HOST"
  echo
  rc_compose ps
}
