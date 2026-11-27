#!/usr/bin/env bash
# rc update. Sourced by bin/rc.

# rc_update: re-resolve the digests of the app and the proxy (convention in lib/images.sh), then
# pull and bring both up. Every digest is resolved before anything is pulled or restarted.
rc_update() {
  local proxy
  [ "$#" -eq 0 ] || rc_usage
  rc_load_app
  rc_require_serving
  proxy="$(p /opt/vps-apps-data/proxy)"

  refresh_image_digests "$(p "/opt/vps-apps-data/$VA_APP/.env")" || {
    echo "rc update: could not resolve the app images, nothing changed" >&2
    exit 1
  }
  refresh_image_digests "$proxy/.env" || {
    echo "rc update: could not resolve the proxy images" >&2
    exit 1
  }

  rc_compose pull
  rc_compose up -d
  docker compose -f "$proxy/compose.yml" --env-file "$proxy/.env" pull
  docker compose -f "$proxy/compose.yml" --env-file "$proxy/.env" up -d
  echo "updated"
}
