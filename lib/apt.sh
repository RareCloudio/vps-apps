#!/usr/bin/env bash
# apt wrapper shared by every step that installs packages. Sourced, never executed.

# apt_wait_lock: wait, up to VA_APT_LOCK_WAIT seconds (600) and checking every VA_APT_LOCK_INTERVAL
# seconds (5), while another process (on a fresh VPS, usually the first-boot unattended-upgrades)
# holds the dpkg lock. dpkg --configure -a has no lock timeout of its own and fails at once, which
# cost a whole bootstrap attempt. Fails when the lock is still held at the end. Without fuser there
# is nothing to wait with, and dpkg reports a held lock itself.
apt_wait_lock() {
  local deadline=$((SECONDS + ${VA_APT_LOCK_WAIT:-600}))
  command -v fuser >/dev/null 2>&1 || return 0
  while fuser "$(p /var/lib/dpkg/lock-frontend)" "$(p /var/lib/dpkg/lock)" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "apt: another process still holds the dpkg lock after ${VA_APT_LOCK_WAIT:-600} seconds"
      return 1
    fi
    sleep "${VA_APT_LOCK_INTERVAL:-5}"
  done
}

# apt_safe <apt-get args...>
# Waits for the dpkg lock and repairs an interrupted dpkg first (a retry after a killed install
# otherwise fails on a half-configured package), then runs apt-get non-interactively and waits up
# to ten minutes for the dpkg lock (unattended-upgrades often holds it on a fresh VPS).
apt_safe() {
  apt_wait_lock || return 1
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -y "$@"
}
