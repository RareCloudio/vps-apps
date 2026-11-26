#!/usr/bin/env bash
# Base step 1: packages, automatic security updates and time sync. Sourced, never executed.

base_packages() {
  apt_safe update
  apt_safe install unattended-upgrades fail2ban nftables bind9-dnsutils jq curl ca-certificates

  local f
  f="$(p /etc/apt/apt.conf.d/20auto-upgrades)"
  mkdir -p "$(dirname "$f")"
  cat >"$f" <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF

  timedatectl set-ntp true
}
