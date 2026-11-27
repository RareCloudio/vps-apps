#!/usr/bin/env bash
# Base step 1, before packages: an IPv6 default route that works. Sourced after
# lib/common.sh, never executed.
#
# A KVM VPS from the Virtualizor panel gets a netplan file whose IPv6 gateway lies outside the VPS's
# own /64, on a route without on-link: true. systemd-networkd then never installs the IPv6 default
# route: IPv6 does not work at all, and every boot waits two minutes for the network to come online.
# This step adds the flag to such routes (files/netplan-onlink.py decides which, with Python's
# ipaddress; netplan's own command is Python, so python3 is there wherever netplan is) and adds the
# same route to the running system. It never fails the install: what goes wrong is logged, and a
# netplan file is either fixed and validated or left exactly as it was.

VA_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The address the closing check pings, for the install log only (Cloudflare's resolver).
VA_PING6_TARGET=2606:4700:4700::1111

# net_generate: netplan generate, which checks every netplan file and writes the backend files
# without touching the running network. Under a test root it reads the files there.
net_generate() {
  if [ -n "${VPS_APPS_ROOT:-}" ]; then
    netplan generate --root-dir "$VPS_APPS_ROOT"
  else
    netplan generate
  fi
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

# Every log line below carries only the first line of netplan's output: the install log is
# world-readable, and netplan's errors quote the file, which can hold a wifi password or a key.

# net_baseline_ok: 0 when netplan generate accepts the netplan files as they are, checked once per
# run, before the first change. When it fails, no file is changed: a change it rejected could not
# be told apart from the fault that was already there.
net_baseline_ok() {
  local out
  if [ -z "$VA_NET_BASELINE" ]; then
    if out="$(net_generate 2>&1)"; then
      VA_NET_BASELINE=ok
    else
      VA_NET_BASELINE=invalid
      log "network: netplan generate fails before any change, so netplan is already invalid; the netplan files are left as they are: ${out%%$'\n'*}"
    fi
  fi
  [ "$VA_NET_BASELINE" = ok ]
}

# net_fix_file <file> <work-dir>: add on-link: true where netplan-onlink.py says a route needs it.
# The file is touched only then, and only when netplan accepts the files as they are
# (net_baseline_ok): the original is kept once as backup/netplan/<name>.orig (a backup that exists
# is never replaced), the file is replaced whole with its own mode, and netplan generate must accept
# it, or the file is put back byte for byte and generated again. Only a fix that is kept goes to
# net_route. Sets VA_NET_CHANGED=1 when a file needed a change.
net_fix_file() {
  local file="$1" work="$2" name backup mode fixes out dev gw
  name="${file##*/}"
  backup="$(p /var/lib/vps-apps/backup/netplan)"
  rm -f "$work/new" "$work/prev"
  if ! fixes="$(python3 -I "$VA_BASE_DIR/files/netplan-onlink.py" "$file" "$work/new")"; then
    log "network: cannot check $file, left as it is"
    return 0
  fi
  [ -n "$fixes" ] || return 0
  VA_NET_CHANGED=1
  net_baseline_ok || return 0
  if ! { mode="$(stat -c %a "$file")" && mkdir -p "$backup" && chmod 0700 "$backup" &&
    { [ -e "$backup/$name.orig" ] || cp -p "$file" "$backup/$name.orig"; } && cat "$file" >"$work/prev"; }; then
    log "network: cannot keep a copy of $file, left as it is"
    return 0
  fi
  if ! write_atomic "$file" "$mode" <"$work/new"; then
    log "network: cannot write $file, left as it is"
    return 0
  fi
  if ! out="$(net_generate 2>&1)"; then
    if write_atomic "$file" "$mode" <"$work/prev"; then
      log "network: netplan generate rejected the change to $file, the original is back: ${out%%$'\n'*}"
      # The rejected run may have left files in /run for the changed version: generate them again.
      if out="$(net_generate 2>&1)"; then
        log "network: netplan generate after the restore: ok"
      else
        log "network: netplan generate after the restore failed: ${out%%$'\n'*}"
      fi
    else
      log "network: netplan generate rejected the change to $file, which could not be put back; the original is $backup/$name.orig"
    fi
    return 0
  fi
  while read -r dev gw keys; do
    log "network: $file: on-link added to the IPv6 default route via $gw on $dev (original: $backup/$name.orig)"
    # A plain live default route would not be the one this route item describes.
    if [ -n "$keys" ]; then
      log "network: the route via $gw on $dev has ${keys//,/, }, so the live route is not added; netplan sets it up at the next boot"
    else
      net_route "$dev" "$gw"
    fi
  done <<<"$fixes"
}

# net_fix_all: net_fix_file for every netplan file, with a private work directory in the state dir.
net_fix_all() {
  local state work f
  if ! command -v python3 >/dev/null 2>&1; then
    log "network: python3 is missing, the netplan files are not checked"
    return 0
  fi
  state="$(p /var/lib/vps-apps)"
  if ! { mkdir -p "$state" && work="$(mktemp -d "$state/.network.XXXXXX")"; }; then
    log "network: cannot make a work directory in $state, the netplan files are not checked"
    return 0
  fi
  for f in "$(p /etc/netplan)"/*.yaml; do
    # Replacing a link would put a regular file in its place and leave its target as it was.
    if [ -L "$f" ]; then
      log "network: $f is a symlink, left as it is"
      continue
    fi
    [ -f "$f" ] || continue
    net_fix_file "$f" "$work"
  done
  rm -rf "$work"
  [ "$VA_NET_CHANGED" = 1 ] || log "network: the netplan files need no change"
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
  VA_NET_CHANGED=0 VA_NET_BASELINE="" VA_NET_V6_BEFORE=""
  { net_fix_all; net_ping6; } || true
}
