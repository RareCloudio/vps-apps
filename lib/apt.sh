#!/usr/bin/env bash
# apt wrapper shared by every step that installs packages. Sourced, never executed.

# apt_safe <apt-get args...>
# Repairs an interrupted dpkg first (a retry after a killed install otherwise fails
# on a half-configured package), then runs apt-get non-interactively and waits up to
# ten minutes for the dpkg lock (unattended-upgrades often holds it on a fresh VPS).
apt_safe() {
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -y "$@"
}
