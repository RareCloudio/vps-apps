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
