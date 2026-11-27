#!/usr/bin/env bash
# rc update. Sourced by bin/rc.

# rc_update: re-resolve the digests of the app and the proxy (convention in lib/images.sh), then
# pull and bring both up.
#   1. An app with an app_fill_env hook first adds what a newer release of the app needs to its
#      .env, on its own: a failed image resolution afterwards never leaves the .env without a key
#      the app's compose files need.
#   2. An app with an app_update_env hook writes its own resolved .env (same contract as
#      resolve_env_images: write the new content to the second file, change nothing else, fail when
#      something cannot be resolved). Both .env files are resolved first and written only when both
#      resolved, so a failure leaves every image as it was and nothing is pulled or restarted.
rc_update() {
  local proxy app_env tmp resolve_app=resolve_env_images
  [ "$#" -eq 0 ] || rc_usage
  rc_load_app
  rc_require_serving
  proxy="$(p /opt/vps-apps-data/proxy)"
  app_env="$(p "/opt/vps-apps-data/$VA_APP/.env")"
  if declare -F app_fill_env >/dev/null && ! app_fill_env "$app_env"; then
    echo "rc update: could not add the new settings to $app_env, nothing changed" >&2
    exit 1
  fi
  if declare -F app_update_env >/dev/null; then
    resolve_app=app_update_env
  fi

  tmp="$(mktemp -d)"
  # What the hook says (on stdout) is held back until every image resolved and both files are
  # written, so it never announces a change that did not happen.
  if ! { "$resolve_app" "$app_env" "$tmp/app" >"$tmp/said" && resolve_env_images "$proxy/.env" "$tmp/proxy"; }; then
    rm -rf "$tmp"
    echo "rc update: could not resolve every image digest, no image changed" >&2
    exit 1
  fi
  apply_env_images "$app_env" "$tmp/app"
  apply_env_images "$proxy/.env" "$tmp/proxy"
  cat "$tmp/said"
  rm -rf "$tmp"

  rc_compose pull
  rc_compose up -d
  docker compose -f "$proxy/compose.yml" --env-file "$proxy/.env" pull
  docker compose -f "$proxy/compose.yml" --env-file "$proxy/.env" up -d
  echo "updated"
}
