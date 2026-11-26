#!/usr/bin/env bash
# Step runner and status file. Sourced after lib/common.sh, never executed.

# set_status installing|ready|failed:<step>
# The status file has no trailing newline and is replaced by rename, so a
# reader (or a container mounting the directory) never sees a partial value.
set_status() {
  local dir tmp
  dir="$(p /var/lib/vps-apps/public/.well-known)"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.status.XXXXXX")"
  printf '%s' "$1" >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$dir/rarecloud-app-status"
}

# run_step <name> <function>
# Skips when the marker exists. Otherwise sets installing, runs the function
# and writes the marker. On error sets failed:<name> and returns 1.
run_step() {
  local name="$1" fn="$2" marker
  marker="$(p "/var/lib/vps-apps/steps/${name}.done")"
  if [ -f "$marker" ]; then
    log "step $name: already done, skipping"
    return 0
  fi
  set_status installing
  log "step $name: start"
  if "$fn"; then
    mkdir -p "$(dirname "$marker")"
    : >"$marker"
    log "step $name: done"
  else
    log "step $name: failed"
    set_status "failed:$name"
    return 1
  fi
}
