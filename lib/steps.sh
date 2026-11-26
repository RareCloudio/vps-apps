#!/usr/bin/env bash
# Step runner and status file. Sourced after lib/common.sh, never executed.

# set_status installing|ready|failed:<step>
# The status file has no trailing newline and is replaced by rename, so a
# reader (or a container mounting the directory) never sees a partial value.
# The temp file lives in the state dir (same filesystem, not served) and is
# removed if any step before the rename fails.
set_status() {
  local state dir tmp
  state="$(p /var/lib/vps-apps)"
  dir="$state/public/.well-known"
  mkdir -p "$dir"
  tmp="$(mktemp "$state/.status.XXXXXX")"
  if ! { printf '%s' "$1" >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$dir/rarecloud-app-status"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# run_step <name> <function>
# Skips when the marker exists. Otherwise sets installing, runs the function
# and writes the marker. On error sets failed:<name> and returns 1.
# The function runs in a subshell with errexit on and NOT inside an if/||
# condition (bash ignores errexit there), so the first failing command aborts
# the step. Consequences: a step cannot set variables for later steps, and
# callers must invoke run_step plainly, never inside if/||/&& (that would
# disable errexit for the step again).
run_step() {
  local name="$1" fn="$2" marker rc errexit=0
  marker="$(p "/var/lib/vps-apps/steps/${name}.done")"
  if [ -f "$marker" ]; then
    log "step $name: already done, skipping"
    return 0
  fi
  set_status installing
  log "step $name: start"
  case $- in *e*) errexit=1 ;; esac
  set +e
  (
    set -e
    "$fn"
  )
  rc=$?
  [ "$errexit" = 1 ] && set -e
  if [ "$rc" -eq 0 ]; then
    mkdir -p "$(dirname "$marker")"
    : >"$marker"
    log "step $name: done"
  else
    log "step $name: failed (exit $rc)"
    set_status "failed:$name"
    return 1
  fi
}
