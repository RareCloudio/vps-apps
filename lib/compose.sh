#!/usr/bin/env bash
# Shared docker compose runner for the proxy-attached apps. Sourced after lib/common.sh, never
# executed. The app's hooks must be loaded (app_compose_files).

# compose_run <env-file> <docker compose args...>: docker compose with one -f per file that
# app_compose_files prints, and the given .env. Fails when the app names no compose file.
compose_run() {
  local env_file="$1" f
  local -a args=()
  shift
  while IFS= read -r f; do
    [ -z "$f" ] || args+=(-f "$f")
  done < <(app_compose_files)
  if [ "${#args[@]}" -eq 0 ]; then
    echo "rc: the app names no compose file" >&2
    return 1
  fi
  docker compose "${args[@]}" --env-file "$env_file" "$@"
}
