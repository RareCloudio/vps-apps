#!/usr/bin/env bats
load test_helper

setup() {
  # shellcheck source=../lib/common.sh
  . "$BATS_TEST_DIRNAME/../lib/common.sh"
  # shellcheck source=../base/50-firewall.sh
  . "$BATS_TEST_DIRNAME/../base/50-firewall.sh"
  RC="$BATS_TEST_DIRNAME/../bin/rc"
  DIR="$(p /etc/vps-apps)"
  PORTS="$DIR/open-ports"
  mkdir -p "$DIR"
  : >"$PORTS"
  FWLOG="$BATS_TEST_TMPDIR/fw.log"
  FILES="$BATS_TEST_DIRNAME/../base/files"
}

# line_of <file> <exact line>: the line number of the first line equal to the string.
line_of() { grep -nxF -- "$2" "$1" | head -n1 | cut -d: -f1; }

# boot_state: the three boot files plus open-ports, for before/after comparisons.
boot_state() { cat "$DIR/vps-apps.nft" "$DIR/docker-user.v4" "$DIR/docker-user.v6" "$PORTS" 2>&1; }

@test "the nft file replaces only its own table" {
  render_nft "$PORTS" >"$BATS_TEST_TMPDIR/f.nft"
  [ "$(sed -n '/^table/p;/^delete/p' "$BATS_TEST_TMPDIR/f.nft" | sed -n 1p)" = "table inet vps_apps {}" ]
  [ "$(sed -n '/^table/p;/^delete/p' "$BATS_TEST_TMPDIR/f.nft" | sed -n 2p)" = "delete table inet vps_apps" ]
  run grep -c 'flush ruleset' "$BATS_TEST_TMPDIR/f.nft"
  [ "$output" = 0 ]
}

@test "the input chain order" {
  printf '5432/tcp\n51820/udp\n' >"$PORTS"
  render_nft "$PORTS" >"$BATS_TEST_TMPDIR/f.nft"
  local f="$BATS_TEST_TMPDIR/f.nft" prev=0 n pat
  grep -qF 'type filter hook input priority 0; policy drop;' "$f"
  for pat in "iif lo accept" \
    "ct state established,related accept" \
    "ct state invalid drop" \
    "ip protocol icmp accept" \
    "icmpv6 type { echo-request, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert, mld-listener-query, destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept" \
    "ip6 saddr fe80::/10 udp sport 547 udp dport 546 accept" \
    "tcp dport { 22, 80, 443 } accept" \
    "tcp dport 5432 accept" \
    "udp dport 51820 accept"; do
    n="$(line_of "$f" "    $pat")"
    [ -n "$n" ]
    [ "$n" -gt "$prev" ]
    prev="$n"
  done
}

@test "an empty open-ports file adds no rules and no template marker survives" {
  render_nft "$PORTS" >"$BATS_TEST_TMPDIR/f.nft"
  run grep -c '@' "$BATS_TEST_TMPDIR/f.nft"
  [ "$output" = 0 ]
  run grep -c 'dport' "$BATS_TEST_TMPDIR/f.nft"
  [ "$output" = 2 ]
}

@test "the DOCKER-USER input" {
  printf '5432/tcp\n51820/udp\n' >"$PORTS"
  render_docker_user eth0 "$PORTS" >"$BATS_TEST_TMPDIR/d.rules"
  local expected
  expected='*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport 80 -j RETURN
-A DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport 443 -j RETURN
-A DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport 5432 -j RETURN
-A DOCKER-USER -i eth0 -p udp -m conntrack --ctorigdstport 51820 -j RETURN
-A DOCKER-USER -i eth0 -j DROP
-A DOCKER-USER -j RETURN
COMMIT'
  [ "$(cat "$BATS_TEST_TMPDIR/d.rules")" = "$expected" ]
}

@test "the open-ports validator: comments, blanks, leading zeros, range" {
  printf '# a comment\n\n  0080/tcp  # trailing\n05432\n  51820/udp\n' >"$PORTS"
  run fw_open_ports "$PORTS"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '80/tcp\n5432/tcp\n51820/udp')" ]
  printf '5432/tcp\n70000/tcp\n' >"$PORTS"
  run fw_open_ports "$PORTS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 2"* ]]
  [[ "$output" == *"70000/tcp"* ]]
  printf '0/tcp\n' >"$PORTS"
  run fw_open_ports "$PORTS"
  [ "$status" -ne 0 ]
  printf '22/sctp\n' >"$PORTS"
  run fw_open_ports "$PORTS"
  [ "$status" -ne 0 ]
}

@test "a malformed open-ports file refuses the apply and keeps the old rules" {
  run firewall_apply
  [ "$status" -eq 0 ]
  local v4
  v4="$(cat "$DIR/docker-user.v4")"
  : >"$FWLOG"
  printf '5432/tcp\nbogus\n' >"$PORTS"
  run firewall_apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"line 2"* ]]
  run grep -c '^nft ' "$FWLOG"
  [ "$output" = 0 ]
  [ "$(cat "$DIR/docker-user.v4")" = "$v4" ]
}

@test "the nft unit orders itself like ufw and nftables, without a boot cycle" {
  local u="$FILES/vps-apps-nft.service"
  grep -qx 'DefaultDependencies=no' "$u"
  grep -qx 'Before=network-pre.target shutdown.target' "$u"
  grep -qx 'Conflicts=shutdown.target' "$u"
  grep -qx 'After=local-fs.target' "$u"
  grep -qx 'Wants=network-pre.target' "$u"
  grep -qx 'WantedBy=sysinit.target' "$u"
  grep -qx 'ExecStart=/usr/sbin/nft -f /etc/vps-apps/vps-apps.nft' "$u"
  grep -qx 'RemainAfterExit=yes' "$u"
}

@test "the docker-user unit that runs after docker" {
  local u="$FILES/vps-apps-docker-user.service"
  grep -qx 'After=docker.service' "$u"
  grep -qx 'PartOf=docker.service' "$u"
  grep -qx 'WantedBy=docker.service' "$u"
  grep -qx 'RemainAfterExit=yes' "$u"
  grep -q '^ExecStart=/usr/sbin/iptables-restore -n ' "$u"
  grep -q '^ExecStart=.*ip6tables-restore -n ' "$u"
}

@test "the early docker-user unit closes the boot window before dockerd starts" {
  local u="$FILES/vps-apps-docker-user-early.service"
  grep -qx 'Before=docker.service' "$u"
  grep -qx 'WantedBy=docker.service' "$u"
  grep -qx 'RemainAfterExit=yes' "$u"
  grep -q '^ExecStart=/usr/sbin/iptables-restore -n /etc/vps-apps/docker-user.v4' "$u"
  grep -q '^ExecStart=.*ip6tables-restore -n ' "$u"
  run grep -c 'After=docker.service' "$u"
  [ "$output" = 0 ]
}

@test "base_firewall installs units and rc, applies both families and enables the units" {
  base_firewall
  [ -f "$(p /etc/systemd/system/vps-apps-nft.service)" ]
  [ -f "$(p /etc/systemd/system/vps-apps-docker-user.service)" ]
  [ -f "$(p /etc/systemd/system/vps-apps-docker-user-early.service)" ]
  [ "$(readlink "$(p /usr/local/bin/rc)")" = /opt/vps-apps/current/bin/rc ]
  [ -e "$PORTS" ]
  [ -f "$DIR/vps-apps.nft" ]
  grep -q '^nft -c -f ' "$FWLOG"
  grep -q '^nft -f ' "$FWLOG"
  grep -q '^iptables-restore -t -n ' "$FWLOG"
  grep -q '^iptables-restore -n ' "$FWLOG"
  grep -q '^ip6tables-restore -n ' "$FWLOG"
  grep -qxF -- '-A DOCKER-USER -i eth0 -j DROP' "$BATS_TEST_TMPDIR/ip6tables-restore.in"
  grep -qxF "enable vps-apps-nft.service vps-apps-docker-user-early.service vps-apps-docker-user.service" "$BATS_TEST_TMPDIR/systemctl.log"
}

@test "the IPv6 rules always apply, on the IPv4 interface when there is no IPv6 default route" {
  touch "$BATS_TEST_TMPDIR/ip6_none"
  base_firewall
  grep -q '^ip6tables-restore -n ' "$FWLOG"
  [ -f "$DIR/docker-user.v6" ]
  grep -qxF -- '-A DOCKER-USER -i eth0 -j DROP' "$DIR/docker-user.v6"
}

@test "the IPv6 part is skipped only when ip6tables is unavailable" {
  fw_have() { [ "$1" != ip6tables-restore ]; }
  base_firewall
  grep -q '^iptables-restore -n ' "$FWLOG"
  run grep -c '^ip6tables-restore ' "$FWLOG"
  [ "$output" = 0 ]
  [ ! -e "$DIR/docker-user.v6" ]
}

@test "no IPv4 default route is a clear failure" {
  ip() { :; }
  run firewall_apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"no IPv4 default route"* ]]
}

@test "a rejected validation leaves boot files and open-ports untouched" {
  local tool before
  run firewall_apply
  [ "$status" -eq 0 ]
  "$RC" port open 5432
  before="$(boot_state)"
  for tool in nft iptables-restore ip6tables-restore; do
    touch "$BATS_TEST_TMPDIR/fail_${tool}_check"
    run "$RC" port open 6000
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing changed"* ]]
    [ "$(boot_state)" = "$before" ]
    rm -f "$BATS_TEST_TMPDIR/fail_${tool}_check"
  done
  run "$RC" port open 6000
  [ "$status" -eq 0 ]
}

@test "a failed load keeps the old boot files and open-ports" {
  local tool before
  run firewall_apply
  [ "$status" -eq 0 ]
  "$RC" port open 5432
  before="$(boot_state)"
  for tool in nft iptables-restore ip6tables-restore; do
    touch "$BATS_TEST_TMPDIR/fail_${tool}_load"
    run "$RC" port open 6000
    [ "$status" -ne 0 ]
    [ "$(boot_state)" = "$before" ]
    rm -f "$BATS_TEST_TMPDIR/fail_${tool}_load"
  done
}

# apply_once_and_open_5432: boot files in place and one opened port, for the guard tests below.
apply_once_and_open_5432() {
  run firewall_apply
  [ "$status" -eq 0 ]
  "$RC" port open 5432
}

@test "an empty nft render (empty template) leaves boot files and open-ports alone and rc port fails" {
  local copy="$BATS_TEST_TMPDIR/code" before
  apply_once_and_open_5432
  before="$(boot_state)"
  mkdir -p "$copy"
  cp -r "$BATS_TEST_DIRNAME/../bin" "$BATS_TEST_DIRNAME/../lib" "$BATS_TEST_DIRNAME/../base" "$copy/"
  : >"$copy/base/files/vps-apps.nft.tmpl"
  run "$copy/bin/rc" port open 6000
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing changed"* ]]
  [ "$(boot_state)" = "$before" ]
}

@test "render_nft fails when the template cannot be read" {
  VA_BASE_DIR="$BATS_TEST_TMPDIR/no-such-dir"
  run render_nft "$PORTS"
  [ "$status" -ne 0 ]
}

@test "an empty or cut DOCKER-USER render leaves boot files and open-ports alone" {
  local before
  apply_once_and_open_5432
  before="$(boot_state)"
  printf '5432/tcp\n6000/tcp\n' >"$BATS_TEST_TMPDIR/cand"
  render_docker_user() { :; }
  run firewall_apply "$BATS_TEST_TMPDIR/cand"
  [ "$status" -ne 0 ]
  [ "$(boot_state)" = "$before" ]
  # Everything but the COMMIT line, as a full disk would leave it.
  render_docker_user() { printf '*filter\n:DOCKER-USER - [0:0]\n-A DOCKER-USER -i %s -j DROP\n' "$1"; }
  run firewall_apply "$BATS_TEST_TMPDIR/cand"
  [ "$status" -ne 0 ]
  [ "$(boot_state)" = "$before" ]
  # A COMMIT without the DROP line is not whole either.
  render_docker_user() { printf '*filter\n:DOCKER-USER - [0:0]\n-A DOCKER-USER -j RETURN\nCOMMIT\n'; }
  run firewall_apply "$BATS_TEST_TMPDIR/cand"
  [ "$status" -ne 0 ]
  [ "$(boot_state)" = "$before" ]
}

@test "an nft render cut before its last line leaves boot files and open-ports alone" {
  local before
  apply_once_and_open_5432
  before="$(boot_state)"
  printf '5432/tcp\n6000/tcp\n' >"$BATS_TEST_TMPDIR/cand"
  eval "real_$(declare -f render_nft)"
  render_nft() { real_render_nft "$@" | head -n -1; }
  run firewall_apply "$BATS_TEST_TMPDIR/cand"
  [ "$status" -ne 0 ]
  [ "$(boot_state)" = "$before" ]
}

@test "a failed mktemp for the stage dir changes nothing and loads nothing" {
  local before
  apply_once_and_open_5432
  before="$(boot_state)"
  : >"$FWLOG"
  mktemp() { return 1; }
  run firewall_apply
  [ "$status" -ne 0 ]
  [ "$(boot_state)" = "$before" ]
  [ ! -s "$FWLOG" ]
}

@test "a missing DOCKER-USER jump in FORWARD logs a warning and does not fail" {
  touch "$BATS_TEST_TMPDIR/fail_iptables_C" "$BATS_TEST_TMPDIR/fail_ip6tables_C"
  run firewall_apply
  [ "$status" -eq 0 ]
  grep -qxF "iptables -C FORWARD -j DOCKER-USER" "$FWLOG"
  grep -qxF "ip6tables -C FORWARD -j DOCKER-USER" "$FWLOG"
  grep -q 'warning.*DOCKER-USER' "$(p /var/log/vps-apps-install.log)"
}

@test "the firewall apply is serialised with flock" {
  run "$RC" port open 5432
  [ "$status" -eq 0 ]
  [ -e "$DIR/.firewall.lock" ]
}

@test "rc with no arguments or an unknown subcommand prints usage and exits 2" {
  run "$RC"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: rc"* ]]
  run "$RC" nonsense
  [ "$status" -eq 2 ]
  run "$RC" ../x
  [ "$status" -eq 2 ]
}

@test "rc port usage paths exit 2 with usage" {
  run "$RC" port
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: rc"* ]]
  run "$RC" port list extra
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: rc"* ]]
  run "$RC" port open
  [ "$status" -eq 2 ]
  run "$RC" port open 1 2
  [ "$status" -eq 2 ]
  run "$RC" port close
  [ "$status" -eq 2 ]
  run "$RC" port frobnicate 80
  [ "$status" -eq 2 ]
}

@test "rc port validates" {
  local bad
  for bad in 0 abc 70000 5432/sctp ""; do
    run "$RC" port open "$bad"
    [ "$status" -eq 2 ]
  done
  [ ! -s "$PORTS" ]
  run "$RC" port open 5432
  [ "$status" -eq 0 ]
  [ "$(cat "$PORTS")" = "5432/tcp" ]
  run "$RC" port open 5432/tcp
  [ "$status" -eq 0 ]
  run "$RC" port open 51820/udp
  [ "$(cat "$PORTS")" = "$(printf '5432/tcp\n51820/udp')" ]
  run "$RC" port open 07000
  [ "$(tail -n1 "$PORTS")" = "7000/tcp" ]
}

@test "rc port open applies the change to nft and both DOCKER-USER families at once" {
  run "$RC" port open 5432
  [ "$status" -eq 0 ]
  grep -qxF "tcp dport 5432 accept" <(sed 's/^ *//' "$DIR/vps-apps.nft")
  grep -qxF "tcp dport 5432 accept" <(sed 's/^ *//' "$BATS_TEST_TMPDIR/nft.in")
  grep -qF -- '--ctorigdstport 5432 -j RETURN' "$BATS_TEST_TMPDIR/iptables-restore.in"
  grep -qF -- '--ctorigdstport 5432 -j RETURN' "$BATS_TEST_TMPDIR/ip6tables-restore.in"
}

@test "an already open port is not duplicated but is applied again" {
  "$RC" port open 5432
  : >"$FWLOG"
  run "$RC" port open 5432
  [ "$status" -eq 0 ]
  [ "$(grep -c '5432' "$PORTS")" = 1 ]
  grep -q '^nft -f ' "$FWLOG"
}

@test "rc port open of the always-open ports is a no-op with a message" {
  local port
  for port in 22 22/tcp 80 443/tcp; do
    : >"$FWLOG"
    run "$RC" port open "$port"
    [ "$status" -eq 0 ]
    [[ "$output" == *"always open"* ]]
    [ ! -s "$PORTS" ]
    [ ! -s "$FWLOG" ]
  done
}

@test "rc port close removes the entry and reloads" {
  "$RC" port open 5432
  "$RC" port open 51820/udp
  : >"$FWLOG"
  run "$RC" port close 5432
  [ "$status" -eq 0 ]
  [ "$(cat "$PORTS")" = "51820/udp" ]
  grep -q '^nft -f ' "$FWLOG"
  run grep -c 5432 "$DIR/vps-apps.nft"
  [ "$output" = 0 ]
  run "$RC" port close 5432
  [ "$status" -eq 0 ]
}

@test "rc port close 80/tcp and 443/tcp refuse" {
  local port
  for port in 80 443 80/tcp 443/tcp; do
    run "$RC" port close "$port"
    [ "$status" -eq 2 ]
    [[ "$output" == *"80 and 443 carry the proxy"* ]]
  done
}

@test "rc port close 22 says SSH stays open" {
  run "$RC" port close 22
  [ "$status" -eq 2 ]
  [[ "$output" == *"SSH stays open"* ]]
}

@test "the UDP twins of 80 and 443 and 22 are ordinary ports" {
  local port
  for port in 80/udp 443/udp 22/udp; do
    run "$RC" port open "$port"
    [ "$status" -eq 0 ]
    run "$RC" port close "$port"
    [ "$status" -eq 0 ]
    [[ "$output" == *"closed"* ]]
  done
  [ ! -s "$PORTS" ]
}

@test "rc port list shows the fixed ports and the opened ones" {
  "$RC" port open 5432
  run "$RC" port list
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '22/tcp\n80/tcp\n443/tcp\n5432/tcp')" ]
}
