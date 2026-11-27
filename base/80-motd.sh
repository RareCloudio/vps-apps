#!/usr/bin/env bash
# Base step 9: the login message. Sourced after lib/common.sh, never executed.

VA_MOTD_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/files/99-vps-apps-motd"

# base_motd: installs one update-motd.d script. It reads the install status when a user logs in,
# so it is true at any time. It touches no other file of Ubuntu's login message.
base_motd() {
  local dir
  dir="$(p /etc/update-motd.d)"
  mkdir -p "$dir"
  write_atomic "$dir/99-vps-apps" 0755 <"$VA_MOTD_SRC"
}
