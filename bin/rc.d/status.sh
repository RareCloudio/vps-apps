#!/usr/bin/env bash
# rc status. Sourced by bin/rc.

# rc_status: the install status always; the app's containers only once there is something to ask
# docker about. During the install the app's .env or docker itself may not exist yet, and rc
# status must still answer and exit 0.
rc_status() {
  local file status=""
  [ "$#" -eq 0 ] || rc_usage
  rc_load_env
  file="$(p /var/lib/vps-apps/public/.well-known/rarecloud-app-status)"
  [ ! -r "$file" ] || status="$(cat "$file")"
  echo "Status: ${status:-unknown}"
  echo "Host:   https://$VA_HOST"
  if [ -f "$(p "/opt/vps-apps-data/$VA_APP/.env")" ] &&
    [ -f "$(p "/opt/vps-apps/current/apps/$VA_APP/app.sh")" ] &&
    command -v docker >/dev/null 2>&1; then
    echo
    rc_load_app
    rc_compose ps
  fi
}
