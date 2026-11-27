#!/usr/bin/env bats
load test_helper

setup() {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  NETPLAN="$VPS_APPS_ROOT/etc/netplan"
  BACKUP="$VPS_APPS_ROOT/var/lib/vps-apps/backup/netplan"
  LOG="$VPS_APPS_ROOT/var/log/vps-apps-install.log"
  VIRT="$NETPLAN/99-virt-eth0.yaml"
  mkdir -p "$NETPLAN"
  # The step runs with the stubs and these basic tools only, so no real netplan, ip or ping can run.
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  local t
  for t in bash python3 cat cp mv rm mkdir mktemp chmod stat date dirname; do
    ln -sf "$(command -v "$t")" "$BIN/$t"
  done
}

# network_step: base_network as install.sh runs it (errexit, nounset, pipefail), in a fresh bash
# with the restricted PATH.
network_step() {
  run env PATH="$BATS_TEST_DIRNAME/stubs:$BIN" bash -c \
    'set -euo pipefail; . "$1/lib/common.sh"; . "$1/base/05-network.sh"; base_network' _ "$ROOT_DIR"
}

# virt_file: the netplan file the Virtualizor panel writes on a new KVM VPS, byte for byte.
virt_file() {
  cat >"$VIRT" <<'YAML'
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: false
      dhcp6: false
      addresses:
        - 85.121.55.177/24
        - 2a06:a880:0005:32c0:0000:0000:0000:0001/64
      routes:
        - to: 0.0.0.0/0
          via: 85.121.55.1
        - to: ::/0
          via: 2a06:a880:5::1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2001:4860:4860::8844]
YAML
  chmod 600 "$VIRT"
}

# keep_copies <file>...: a copy of each file, <name>.before in the test dir, for untouched.
keep_copies() {
  local f
  for f in "$@"; do cp -p "$f" "$BATS_TEST_TMPDIR/$(basename "$f").before"; done
}

# untouched <file>...: each file equals the copy keep_copies took.
untouched() {
  local f
  for f in "$@"; do cmp "$BATS_TEST_TMPDIR/$(basename "$f").before" "$f"; done
}

# nothing_done: no backup, no netplan call and no route change happened.
nothing_done() {
  [ ! -e "$BACKUP" ]
  [ ! -e "$STUB_TMP/netplan.log" ]
  [ ! -e "$STUB_TMP/ip.log" ]
  grep -q 'network: the netplan files need no change' "$LOG"
}

@test "the Virtualizor file gets on-link: true under its IPv6 default route and nothing else" {
  virt_file
  keep_copies "$VIRT"
  network_step
  [ "$status" -eq 0 ]
  run diff "$BATS_TEST_TMPDIR/99-virt-eth0.yaml.before" "$VIRT"
  [ "$output" = "$(printf '15a16\n>           on-link: true')" ]
  [ "$(sed -n 15p "$VIRT")" = "          via: 2a06:a880:5::1" ]
  # The original is kept, netplan generate validated the new file, and nothing called netplan apply.
  cmp "$BATS_TEST_TMPDIR/99-virt-eth0.yaml.before" "$BACKUP/99-virt-eth0.yaml.orig"
  [ "$(cat "$STUB_TMP/netplan.log")" = "generate --root-dir $VPS_APPS_ROOT" ]
  grep -qx '          on-link: true' "$STUB_TMP/netplan.seen"
  grep -qF "network: $VIRT: on-link added to the IPv6 default route via 2a06:a880:5::1 on eth0" "$LOG"
}

@test "the route is made effective now with ip, on-link, for the device and gateway of the fix" {
  virt_file
  network_step
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_TMP/ip.log")" = "$(printf '%s\n' '-6 route replace 2a06:a880:5::1 dev eth0' \
    '-6 route replace default via 2a06:a880:5::1 dev eth0 onlink')" ]
}

@test "a failing ip is logged, both commands are tried, and the step still succeeds" {
  virt_file
  : >"$STUB_TMP/fail_ip_route_replace"
  network_step
  [ "$status" -eq 0 ]
  [ "$(grep -c 'route replace' "$STUB_TMP/ip.log")" -eq 2 ]
  grep -qx '          on-link: true' "$VIRT"
  grep -qF 'network: ip -6 route replace 2a06:a880:5::1 dev eth0 failed' "$LOG"
  grep -qF 'network: ip -6 route replace default via 2a06:a880:5::1 dev eth0 onlink failed' "$LOG"
}

@test "to: default with an IPv6 gateway gets on-link too (compact list, quoted values, no last newline)" {
  printf '%s\n' 'network:' '  version: 2' '  ethernets:' '    ens3:' \
    '      addresses: ["2001:db8:10:20::5/64", 192.0.2.10/24]' '      routes:' '      - to: default' >"$NETPLAN/50-ens3.yaml"
  printf '%s' '        via: "2001:db8:10::1"' >>"$NETPLAN/50-ens3.yaml"
  network_step
  [ "$status" -eq 0 ]
  printf '%s\n' 'network:' '  version: 2' '  ethernets:' '    ens3:' \
    '      addresses: ["2001:db8:10:20::5/64", 192.0.2.10/24]' '      routes:' '      - to: default' \
    '        via: "2001:db8:10::1"' >"$BATS_TEST_TMPDIR/want"
  printf '%s' '        on-link: true' >>"$BATS_TEST_TMPDIR/want"
  cmp "$BATS_TEST_TMPDIR/want" "$NETPLAN/50-ens3.yaml"
  grep -qxF -- '-6 route replace default via 2001:db8:10::1 dev ens3 onlink' "$STUB_TMP/ip.log"
}

@test "a renamed device gets the route under its set-name, with via before to and a comment" {
  cat >"$NETPLAN/50-cloud-init.yaml" <<'YAML'
network:
  version: 2
  ethernets:
    uplink:
      match:
        macaddress: "52:54:00:12:34:56"
      set-name: eth0
      addresses:
        - 2a06:a880:5:32c0::1/64  # the VPS
      routes:
        - via: 2a06:a880:5::1  # the node's gateway
          to: "::/0"
YAML
  keep_copies "$NETPLAN/50-cloud-init.yaml"
  network_step
  [ "$status" -eq 0 ]
  run diff "$BATS_TEST_TMPDIR/50-cloud-init.yaml.before" "$NETPLAN/50-cloud-init.yaml"
  [ "$output" = "$(printf '11a12\n>           on-link: true')" ]
  grep -qxF -- '-6 route replace default via 2a06:a880:5::1 dev eth0 onlink' "$STUB_TMP/ip.log"
}

@test "a route that already says on-link (true or false) is left alone, with no backup" {
  virt_file
  sed -i 's/^          via: 2a06:a880:5::1$/&\n          on-link: true/' "$VIRT"
  sed 's/eth0/eth1/; s/on-link: true/on-link: false/' "$VIRT" >"$NETPLAN/99-virt-eth1.yaml"
  grep -qx '          on-link: false' "$NETPLAN/99-virt-eth1.yaml"
  keep_copies "$VIRT" "$NETPLAN/99-virt-eth1.yaml"
  network_step
  [ "$status" -eq 0 ]
  untouched "$VIRT" "$NETPLAN/99-virt-eth1.yaml"
  nothing_done
}

@test "a gateway inside the interface's own prefix, or a link-local one, is left alone" {
  virt_file
  sed -i 's/via: 2a06:a880:5::1$/via: 2a06:a880:5:32c0::ffff/' "$VIRT"
  sed 's/eth0/eth1/; s/via: 2a06:a880:5:32c0::ffff$/via: fe80::1/' "$VIRT" >"$NETPLAN/99-virt-eth1.yaml"
  grep -qx '          via: fe80::1' "$NETPLAN/99-virt-eth1.yaml"
  keep_copies "$VIRT" "$NETPLAN/99-virt-eth1.yaml"
  network_step
  [ "$status" -eq 0 ]
  untouched "$VIRT" "$NETPLAN/99-virt-eth1.yaml"
  nothing_done
}

@test "an IPv4-only file is left alone, even with a gateway outside its prefix" {
  cat >"$NETPLAN/99-virt-eth0.yaml" <<'YAML'
network:
  version: 2
  ethernets:
    eth0:
      addresses:
        - 85.121.55.177/24
      routes:
        - to: default
          via: 10.0.0.1
        - to: 0.0.0.0/0
          via: 85.121.55.1
YAML
  keep_copies "$VIRT"
  network_step
  [ "$status" -eq 0 ]
  untouched "$VIRT"
  nothing_done
}

@test "an interface without a static IPv6 address is left alone: IPv6 DNS servers do not count" {
  virt_file
  sed -i '/2a06:a880:0005:32c0/d' "$VIRT"
  refute_grep -q 2a06:a880:0005 "$VIRT"
  keep_copies "$VIRT"
  network_step
  [ "$status" -eq 0 ]
  untouched "$VIRT"
  nothing_done
}

@test "two netplan files are each fixed, backed up and validated" {
  virt_file
  sed 's/eth0:/eth1:/; s/^          via: 2a06:a880:5::1$/          via: 2a06:a880:5::1  # gateway/' "$VIRT" >"$NETPLAN/99-virt-eth1.yaml"
  chmod 600 "$NETPLAN/99-virt-eth1.yaml"
  keep_copies "$VIRT" "$NETPLAN/99-virt-eth1.yaml"
  network_step
  [ "$status" -eq 0 ]
  local f
  for f in 99-virt-eth0.yaml 99-virt-eth1.yaml; do
    run diff "$BATS_TEST_TMPDIR/$f.before" "$NETPLAN/$f"
    [ "$output" = "$(printf '15a16\n>           on-link: true')" ]
    cmp "$BATS_TEST_TMPDIR/$f.before" "$BACKUP/$f.orig"
  done
  [ "$(grep -c '^generate' "$STUB_TMP/netplan.log")" -eq 2 ]
  grep -qxF -- '-6 route replace default via 2a06:a880:5::1 dev eth0 onlink' "$STUB_TMP/ip.log"
  grep -qxF -- '-6 route replace default via 2a06:a880:5::1 dev eth1 onlink' "$STUB_TMP/ip.log"
}

@test "a failing netplan generate puts the original back byte for byte and the step still succeeds" {
  virt_file
  keep_copies "$VIRT"
  echo 1 >"$STUB_TMP/netplan_rc"
  network_step
  [ "$status" -eq 0 ]
  untouched "$VIRT"
  [ "$(stat -c %a "$VIRT")" = 600 ]
  # generate did see the changed file; a fix it rejected is not applied to the running system either.
  grep -qx '          on-link: true' "$STUB_TMP/netplan.seen"
  [ ! -e "$STUB_TMP/ip.log" ]
  grep -qF "network: netplan generate rejected the change to $VIRT, the original is back" "$LOG"
  [ -z "$(find "$NETPLAN" "$VPS_APPS_ROOT/var/lib/vps-apps" -maxdepth 1 -name '.*' -type f)" ]
}

@test "run_step records the network step as done even when netplan generate fails" {
  virt_file
  echo 1 >"$STUB_TMP/netplan_rc"
  run env PATH="$BATS_TEST_DIRNAME/stubs:$BIN" bash -c \
    'set -euo pipefail; . "$1/lib/common.sh"; . "$1/lib/steps.sh"; . "$1/base/05-network.sh"; run_step network base_network' \
    _ "$ROOT_DIR"
  [ "$status" -eq 0 ]
  [ -f "$VPS_APPS_ROOT/var/lib/vps-apps/steps/network.done" ]
  [ "$(cat "$VPS_APPS_ROOT/var/lib/vps-apps/public/.well-known/rarecloud-app-status")" = installing ]
}

@test "a second run changes nothing and reports nothing to fix" {
  virt_file
  network_step
  [ "$status" -eq 0 ]
  keep_copies "$VIRT" "$BACKUP/99-virt-eth0.yaml.orig"
  local inode
  inode="$(stat -c %i "$VIRT")"
  rm -f "$STUB_TMP/netplan.log" "$STUB_TMP/ip.log"
  refute_grep -q 'need no change' "$LOG"
  network_step
  [ "$status" -eq 0 ]
  untouched "$VIRT" "$BACKUP/99-virt-eth0.yaml.orig"
  [ "$(stat -c %i "$VIRT")" = "$inode" ]
  [ ! -e "$STUB_TMP/netplan.log" ]
  [ ! -e "$STUB_TMP/ip.log" ]
  grep -q 'network: the netplan files need no change' "$LOG"
}

@test "an existing backup is never overwritten" {
  virt_file
  mkdir -p "$BACKUP"
  printf 'the first original\n' >"$BACKUP/99-virt-eth0.yaml.orig"
  network_step
  [ "$status" -eq 0 ]
  [ "$(cat "$BACKUP/99-virt-eth0.yaml.orig")" = "the first original" ]
  grep -qx '          on-link: true' "$VIRT"
}

@test "the fixed file keeps its mode and the backup directory is private" {
  virt_file
  chmod 640 "$VIRT"
  network_step
  [ "$status" -eq 0 ]
  grep -qx '          on-link: true' "$VIRT"
  [ "$(stat -c %a "$VIRT")" = 640 ]
  [ "$(stat -c %a "$BACKUP")" = 700 ]
}

@test "the IPv6 ping is logged, answered or not, and never fails the step" {
  rmdir "$NETPLAN"
  network_step
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_TMP/ping.log")" = "-6 -c1 -W3 2606:4700:4700::1111" ]
  grep -qF 'network: IPv6 ping to 2606:4700:4700::1111 answered' "$LOG"
  echo 1 >"$STUB_TMP/ping_rc"
  network_step
  [ "$status" -eq 0 ]
  grep -qF 'network: IPv6 ping to 2606:4700:4700::1111 got no reply' "$LOG"
}

@test "without python3 the step says so, changes nothing and succeeds" {
  virt_file
  keep_copies "$VIRT"
  rm "$BIN/python3"
  network_step
  [ "$status" -eq 0 ]
  untouched "$VIRT"
  [ ! -e "$BACKUP" ]
  grep -qF 'network: python3 is missing, the netplan files are not checked' "$LOG"
}
