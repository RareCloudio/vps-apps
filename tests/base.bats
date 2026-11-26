#!/usr/bin/env bats
load test_helper

setup() {
  # shellcheck source=../lib/common.sh
  . "$BATS_TEST_DIRNAME/../lib/common.sh"
  # shellcheck source=../lib/apt.sh
  . "$BATS_TEST_DIRNAME/../lib/apt.sh"
  # shellcheck source=/dev/null
  for f in "$BATS_TEST_DIRNAME"/../base/[0-9]*.sh; do . "$f"; done
  CALLS="$BATS_TEST_TMPDIR/calls.log"
  : >"$CALLS"
  mkdir -p "$(p /proc)" "$(p /etc)"
}

meminfo() { printf 'MemTotal:       %s kB\n' "$1" >"$(p /proc/meminfo)"; }

@test "apt_safe repairs an interrupted dpkg first" {
  apt_safe install foo
  apt_safe update
  [ "$(sed -n 1p "$CALLS")" = "dpkg --configure -a" ]
  [ "$(sed -n 2p "$CALLS")" = "apt-get -o DPkg::Lock::Timeout=600 -y install foo" ]
  [ "$(sed -n 3p "$CALLS")" = "dpkg --configure -a" ]
  [ "$(sed -n 4p "$CALLS")" = "apt-get -o DPkg::Lock::Timeout=600 -y update" ]
}

@test "packages are installed, auto-upgrades enabled and NTP switched on" {
  base_packages
  grep -qF "install unattended-upgrades fail2ban nftables bind9-dnsutils jq curl ca-certificates" "$CALLS"
  grep -qF 'APT::Periodic::Unattended-Upgrade "1";' "$(p /etc/apt/apt.conf.d/20auto-upgrades)"
  grep -qxF "timedatectl set-ntp true" "$CALLS"
}

@test "the swap size follows RAM" {
  local pair kb want
  for pair in 1:1 2:2 4:2 8:4; do
    kb=$(( ${pair%%:*} * 1048576 ))
    want="${pair##*:}"
    : >"$CALLS"
    rm -f "$(p /swapfile)"
    meminfo "$kb"
    base_swap
    grep -qxF "fallocate -l ${want}G $(p /swapfile).tmp" "$CALLS"
  done
}

@test "a 1 GiB VPS that reports slightly less than 1 GiB still gets 1 GiB" {
  meminfo 1015000
  base_swap
  grep -qF "fallocate -l 1G " "$CALLS"
}

@test "swap is private, in fstab once, and a second run changes nothing" {
  meminfo 2097152
  base_swap
  base_swap
  [ "$(grep -c '^/swapfile none swap sw 0 0$' "$(p /etc/fstab)")" = 1 ]
  [ "$(grep -c '^fallocate' "$CALLS")" = 1 ]
  [ "$(grep -c '^mkswap' "$CALLS")" = 1 ]
  [ -f "$(p /swapfile)" ]
  [ ! -e "$(p /swapfile).tmp" ]
  [ "$(stat -c %a "$(p /swapfile)")" = 600 ]
}

@test "sysctl baseline is installed and applied" {
  base_sysctl
  f="$(p /etc/sysctl.d/99-vps-apps.conf)"
  grep -qx 'net.ipv4.tcp_syncookies=1' "$f"
  grep -qx 'net.ipv4.conf.all.rp_filter=1' "$f"
  grep -qx 'net.ipv4.conf.all.accept_redirects=0' "$f"
  grep -qx 'net.ipv6.conf.all.accept_redirects=0' "$f"
  grep -qx 'kernel.kptr_restrict=2' "$f"
  grep -qxF "sysctl --system" "$CALLS"
}

@test "docker: repo, packages and daemon.json" {
  base_docker
  [ -s "$(p /etc/apt/keyrings/docker.asc)" ]
  grep -qx 'URIs: https://download.docker.com/linux/ubuntu' "$(p /etc/apt/sources.list.d/docker.sources)"
  grep -qxF "apt-get -o DPkg::Lock::Timeout=600 -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin" "$CALLS"
  d="$(p /etc/docker/daemon.json)"
  [ "$(jq -r '."log-driver"' "$d")" = json-file ]
  [ "$(jq -r '."log-opts"."max-size"' "$d")" = 10m ]
  [ "$(jq -r '."log-opts"."max-file"' "$d")" = 3 ]
  [ "$(jq -r '."live-restore"' "$d")" = true ]
  [ "$(jq -r '."firewall-backend"' "$d")" = iptables ]
  grep -qx 'enable --now docker' "$BATS_TEST_TMPDIR/systemctl.log"
}

@test "docker: a second run leaves the config and the apt source identical" {
  base_docker
  cp "$(p /etc/docker/daemon.json)" "$BATS_TEST_TMPDIR/d1"
  cp "$(p /etc/apt/sources.list.d/docker.sources)" "$BATS_TEST_TMPDIR/s1"
  base_docker
  cmp "$(p /etc/docker/daemon.json)" "$BATS_TEST_TMPDIR/d1"
  cmp "$(p /etc/apt/sources.list.d/docker.sources)" "$BATS_TEST_TMPDIR/s1"
  [ "$(grep -c '^Types:' "$(p /etc/apt/sources.list.d/docker.sources)")" = 1 ]
}

@test "the prune timer is weekly" {
  base_docker
  d="$(p /etc/systemd/system)"
  grep -qx 'OnCalendar=weekly' "$d/vps-apps-docker-prune.timer"
  grep -qE '^ExecStart=.*docker image prune -f$' "$d/vps-apps-docker-prune.service"
  grep -qE '^ExecStart=.*docker builder prune -f --filter until=168h$' "$d/vps-apps-docker-prune.service"
  grep -qx 'enable --now vps-apps-docker-prune.timer' "$BATS_TEST_TMPDIR/systemctl.log"
}
