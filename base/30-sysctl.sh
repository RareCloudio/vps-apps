#!/usr/bin/env bash
# Base step 3: kernel hardening baseline. Sourced, never executed.

VA_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

base_sysctl() {
  local dir
  dir="$(p /etc/sysctl.d)"
  mkdir -p "$dir"
  install -m 0644 "$VA_BASE_DIR/files/99-vps-apps.conf" "$dir/99-vps-apps.conf"
  sysctl --system
}
