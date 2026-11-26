#!/usr/bin/env bats
load test_helper

setup() {
  # shellcheck source=../lib/common.sh
  . "$BATS_TEST_DIRNAME/../lib/common.sh"
  # shellcheck source=../base/50-firewall.sh
  . "$BATS_TEST_DIRNAME/../base/50-firewall.sh"
  RC="$BATS_TEST_DIRNAME/../bin/rc"
  PORTS="$(p /etc/vps-apps/open-ports)"
  mkdir -p "$(dirname "$PORTS")"
  : >"$PORTS"
  FWLOG="$BATS_TEST_TMPDIR/fw.log"
}

# line_of <file> <fixed string>: the line number of the first line equal to the string.
line_of() { grep -nxF -- "$2" "$1" | head -n1 | cut -d: -f1; }

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
    "icmpv6 type { echo-request, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept" \
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
  [ "$output" = 1 ]
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

@test "the docker-user unit" {
  local u="$BATS_TEST_DIRNAME/../base/files/vps-apps-docker-user.service"
  grep -qx 'After=docker.service' "$u"
  grep -qx 'PartOf=docker.service' "$u"
  grep -qx 'WantedBy=docker.service' "$u"
  grep -qx 'RemainAfterExit=yes' "$u"
  grep -q '^ExecStart=/usr/sbin/iptables-restore -n ' "$u"
  grep -q '^ExecStart=.*ip6tables-restore -n ' "$u"
}

@test "the nft unit loads the table file" {
  grep -qx 'ExecStart=/usr/sbin/nft -f /etc/vps-apps/vps-apps.nft' "$BATS_TEST_DIRNAME/../base/files/vps-apps-nft.service"
}

@test "base_firewall installs units and rc, applies both families and enables the units" {
  base_firewall
  [ -f "$(p /etc/systemd/system/vps-apps-nft.service)" ]
  [ -f "$(p /etc/systemd/system/vps-apps-docker-user.service)" ]
  [ "$(readlink "$(p /usr/local/bin/rc)")" = /opt/vps-apps/current/bin/rc ]
  [ -e "$PORTS" ]
  grep -qxF "nft -f $(p /etc/vps-apps/vps-apps.nft)" "$FWLOG"
  grep -qxF "iptables-restore -n $(p /etc/vps-apps/docker-user.v4)" "$FWLOG"
  grep -qxF "ip6tables-restore -n $(p /etc/vps-apps/docker-user.v6)" "$FWLOG"
  grep -qxF -- '-A DOCKER-USER -i eth0 -j DROP' "$BATS_TEST_TMPDIR/ip6tables-restore.in"
  grep -qxF "enable vps-apps-nft.service vps-apps-docker-user.service" "$BATS_TEST_TMPDIR/systemctl.log"
}

@test "without an IPv6 default route the ip6tables part is skipped and does not fail" {
  touch "$BATS_TEST_TMPDIR/ip6_none"
  base_firewall
  grep -q '^iptables-restore ' "$FWLOG"
  run grep -c '^ip6tables-restore ' "$FWLOG"
  [ "$output" = 0 ]
  [ ! -e "$(p /etc/vps-apps/docker-user.v6)" ]
}

@test "no IPv4 default route is a clear failure" {
  ip() { :; }
  run firewall_apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"no IPv4 default route"* ]]
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
}

@test "rc port open applies the change to nft and both DOCKER-USER families at once" {
  run "$RC" port open 5432
  [ "$status" -eq 0 ]
  grep -qxF "tcp dport 5432 accept" <(sed 's/^ *//' "$(p /etc/vps-apps/vps-apps.nft)")
  grep -qxF "nft -f $(p /etc/vps-apps/vps-apps.nft)" "$FWLOG"
  grep -qF -- '--ctorigdstport 5432 -j RETURN' "$BATS_TEST_TMPDIR/iptables-restore.in"
  grep -qF -- '--ctorigdstport 5432 -j RETURN' "$BATS_TEST_TMPDIR/ip6tables-restore.in"
}

@test "an already open port does not reload anything" {
  "$RC" port open 5432
  : >"$FWLOG"
  run "$RC" port open 5432
  [ "$status" -eq 0 ]
  [ ! -s "$FWLOG" ]
}

@test "rc port close removes the entry and reloads" {
  "$RC" port open 5432
  "$RC" port open 51820/udp
  : >"$FWLOG"
  run "$RC" port close 5432
  [ "$status" -eq 0 ]
  [ "$(cat "$PORTS")" = "51820/udp" ]
  grep -q '^nft -f ' "$FWLOG"
  run grep -c 5432 "$(p /etc/vps-apps/vps-apps.nft)"
  [ "$output" = 0 ]
  run "$RC" port close 5432
  [ "$status" -eq 0 ]
}

@test "rc port close 80 and 443 refuse" {
  local port
  for port in 80 443 80/tcp 443/udp; do
    run "$RC" port close "$port"
    [ "$status" -eq 2 ]
    [[ "$output" == *"80 and 443 carry the proxy"* ]]
  done
}

@test "rc port list shows the fixed ports and the opened ones" {
  "$RC" port open 5432
  run "$RC" port list
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '22/tcp\n80/tcp\n443/tcp\n5432/tcp')" ]
}
