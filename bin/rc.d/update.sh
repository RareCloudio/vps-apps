#!/usr/bin/env bash
# rc update. Sourced by bin/rc.

# rc_update: re-resolve the digests of the app and the proxy (convention in lib/images.sh), then
# pull and bring both up. Both .env files are resolved first and written only when both resolved,
# so a failure leaves every file as it was and nothing is pulled or restarted.
rc_update() {
  local proxy app_env tmp
  [ "$#" -eq 0 ] || rc_usage
  rc_load_app
  rc_require_serving
  proxy="$(p /opt/vps-apps-data/proxy)"
  app_env="$(p "/opt/vps-apps-data/$VA_APP/.env")"

  tmp="$(mktemp -d)"
  if ! { resolve_env_images "$app_env" "$tmp/app" && resolve_env_images "$proxy/.env" "$tmp/proxy"; }; then
    rm -rf "$tmp"
    echo "rc update: could not resolve every image digest, nothing changed" >&2
    exit 1
  fi
  apply_env_images "$app_env" "$tmp/app"
  apply_env_images "$proxy/.env" "$tmp/proxy"
  rm -rf "$tmp"

  rc_compose pull
  rc_compose up -d
  docker compose -f "$proxy/compose.yml" --env-file "$proxy/.env" pull
  docker compose -f "$proxy/compose.yml" --env-file "$proxy/.env" up -d
  echo "updated"
}
