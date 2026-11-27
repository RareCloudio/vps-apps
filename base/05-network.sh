#!/usr/bin/env bash
# Base step 1, before packages: an IPv6 default route that works, now and after every boot. Sourced
# after lib/common.sh, never executed.
#
# A KVM VPS from the Virtualizor panel gets a netplan file whose IPv6 gateway lies outside the VPS's
# own /64, on a route without on-link: true. systemd-networkd then never installs the IPv6 default
# route: IPv6 does not work at all, and every boot waits two minutes for the network to come online.
# A restart from the panel writes that file again before the VM boots, so a fix made once would not
# last. This step installs files/vps-apps-ipv6-onlink (the file fix, with files/netplan-onlink.py,
# Python's ipaddress; netplan's own command is Python, so python3 is there wherever netplan is) and
# a unit that runs it before every start of networkd (boot included), runs it once now, and adds
# the fixed route to the running system when IPv6 does not answer yet. It never fails the install:
# what goes wrong is logged, and a netplan file is either fixed and validated or left exactly as it
# was.

VA_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The address the IPv6 checks ping (Cloudflare's resolver).
VA_PING6_TARGET=2606:4700:4700::1111
VA_ONLINK_CHECKER=/usr/local/lib/vps-apps/netplan-onlink.py
VA_ONLINK_RUNNER=/usr/local/sbin/vps-apps-ipv6-onlink
VA_ONLINK_UNIT=vps-apps-ipv6-onlink.service

# net_install: the checker, the runner and the unit, enabled to run before every start of networkd.
# Fails, logged, when a file cannot be installed; a unit that cannot be enabled is logged only.
net_install() {
  local unit_dir
  unit_dir="$(p /etc/systemd/system)"
  if ! { mkdir -p "$(p "${VA_ONLINK_CHECKER%/*}")" "$(p "${VA_ONLINK_RUNNER%/*}")" "$unit_dir" &&
    install -m 0644 "$VA_BASE_DIR/files/netplan-onlink.py" "$(p "$VA_ONLINK_CHECKER")" &&
    install -m 0755 "$VA_BASE_DIR/files/vps-apps-ipv6-onlink" "$(p "$VA_ONLINK_RUNNER")" &&
    install -m 0644 "$VA_BASE_DIR/files/$VA_ONLINK_UNIT" "$unit_dir/$VA_ONLINK_UNIT"; }; then
    log "network: cannot install the IPv6 on-link runner, the netplan files are not checked"
    return 1
  fi
  if ! { systemctl daemon-reload && systemctl enable "$VA_ONLINK_UNIT"; }; then
    log "network: cannot enable $VA_ONLINK_UNIT, so the netplan files are not checked at boot"
  fi
  return 0
}

# net_ping6_ok: one IPv6 ping to VA_PING6_TARGET answered.
net_ping6_ok() {
  ping -6 -c1 -W3 "$VA_PING6_TARGET" >/dev/null 2>&1
}

# net_route <device> <gateway>: the fixed route on the running system now, without netplan apply
# (which would reconfigure the live network in the middle of the install). Failures are logged.
# Nothing is added when IPv6 already answered before the first live route (a route learned from
# router advertisements, say): the fixed file is enough then, from the next boot.
net_route() {
  if [ -z "$VA_NET_V6_BEFORE" ]; then
    VA_NET_V6_BEFORE=no
    if net_ping6_ok; then
      VA_NET_V6_BEFORE=yes
    fi
  fi
  if [ "$VA_NET_V6_BEFORE" = yes ]; then
    log "network: IPv6 already answers, so the live route via $2 on $1 is not added; netplan sets it up at the next boot"
    return 0
  fi
  # A host route to the gateway on this link: the kernel then reaches the gateway directly, as the
  # on-link flag tells it to, although the address lies outside the interface's prefix.
  ip -6 route replace "$2" dev "$1" || log "network: ip -6 route replace $2 dev $1 failed"
  ip -6 route replace default via "$2" dev "$1" onlink ||
    log "network: ip -6 route replace default via $2 dev $1 onlink failed"
}

# net_run_fix: the installed runner once now. Its messages go to the install log; each fix it kept
# gets a live route (net_route), unless the route item has keys a plain live default route would
# not match.
net_run_fix() {
  local state fixes out line dev gw keys
  state="$(p /var/lib/vps-apps)"
  if ! { mkdir -p "$state" && fixes="$(mktemp "$state/.onlink-fixes.XXXXXX")"; }; then
    log "network: cannot make a temp file in $state, the netplan files are not checked"
    return 0
  fi
  out="$(VA_ONLINK_FIXES="$fixes" "$(p "$VA_ONLINK_RUNNER")" 2>&1)" ||
    log "network: $VA_ONLINK_RUNNER exited with $?"
  while IFS= read -r line; do
    [ -z "$line" ] || log "network: $line"
  done <<<"$out"
  while read -r dev gw keys; do
    [ -n "$dev" ] || continue
    if [ -n "$keys" ]; then
      log "network: the route via $gw on $dev has ${keys//,/, }, so the live route is not added; netplan sets it up at the next boot"
    else
      net_route "$dev" "$gw"
    fi
  done <"$fixes"
  rm -f "$fixes"
}

# net_ping6: whether IPv6 answers now, for the install log only.
net_ping6() {
  if net_ping6_ok; then
    log "network: IPv6 ping to $VA_PING6_TARGET answered"
  else
    log "network: IPv6 ping to $VA_PING6_TARGET got no reply"
  fi
}

# base_network: the step. Its body runs as a condition, so errexit is off inside: every command that
# matters checks its own result above, and nothing here can fail the install.
base_network() {
  VA_NET_V6_BEFORE=""
  { net_install && net_run_fix; net_ping6; } || true
}
