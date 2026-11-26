#!/usr/bin/env bash
# Base step 5: host firewall (own nftables table) plus DOCKER-USER rules for container ports.
# Sourced, never executed; bin/rc sources it too for the render and apply helpers.

VA_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fw_open_ports <file>: print each valid "<port>/<tcp|udp>" line; blank lines, comments
# and malformed lines are skipped.
fw_open_ports() {
  [ -f "$1" ] || return 0
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    if [[ "$line" =~ ^[0-9]{1,5}/(tcp|udp)$ ]]; then
      printf '%s\n' "$line"
    fi
  done <"$1"
  return 0
}

# render_nft <open-ports-file>: print the nftables file.
render_nft() {
  local line entry rules=""
  while IFS= read -r entry; do
    rules+="    ${entry#*/} dport ${entry%/*} accept"$'\n'
  done < <(fw_open_ports "$1")
  rules="${rules%$'\n'}"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "@OPEN_PORT_RULES@" ]; then
      if [ -n "$rules" ]; then
        printf '%s\n' "$rules"
      fi
    else
      printf '%s\n' "$line"
    fi
  done <"$VA_BASE_DIR/files/vps-apps.nft.tmpl"
}

# render_docker_user <ext_if> <open-ports-file>: print an iptables-restore -n input, valid
# for iptables and ip6tables. Container ports reached from the outside interface are dropped
# unless they are 80, 443 or listed; the chain declaration flushes DOCKER-USER atomically.
render_docker_user() {
  local ext_if="$1" entry
  local -a entries=(80/tcp 443/tcp)
  while IFS= read -r entry; do
    entries+=("$entry")
  done < <(fw_open_ports "$2")
  printf '*filter\n:DOCKER-USER - [0:0]\n'
  printf -- '-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN\n'
  for entry in "${entries[@]}"; do
    printf -- '-A DOCKER-USER -i %s -p %s -m conntrack --ctorigdstport %s -j RETURN\n' \
      "$ext_if" "${entry#*/}" "${entry%/*}"
  done
  printf -- '-A DOCKER-USER -i %s -j DROP\n' "$ext_if"
  printf -- '-A DOCKER-USER -j RETURN\nCOMMIT\n'
}

# fw_default_if <4|6>: the interface that carries the default route, empty when none.
fw_default_if() {
  local flag=-4
  if [ "$1" = 6 ]; then
    flag=-6
  fi
  ip "$flag" route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

# firewall_apply: regenerate the rule files from open-ports and load them now. The same
# files are what the systemd units load at boot.
firewall_apply() {
  local dir ports if4 if6
  dir="$(p /etc/vps-apps)"
  ports="$dir/open-ports"
  mkdir -p "$dir"
  [ -e "$ports" ] || : >"$ports"
  if4="$(fw_default_if 4)"
  if6="$(fw_default_if 6)"
  if [ -z "$if4" ]; then
    echo "firewall: no IPv4 default route, cannot pick the external interface" >&2
    return 1
  fi
  render_nft "$ports" >"$dir/vps-apps.nft"
  render_docker_user "$if4" "$ports" >"$dir/docker-user.v4"
  if [ -n "$if6" ]; then
    render_docker_user "$if6" "$ports" >"$dir/docker-user.v6"
  else
    rm -f "$dir/docker-user.v6"
  fi
  nft -f "$dir/vps-apps.nft"
  iptables-restore -n "$dir/docker-user.v4"
  if [ -n "$if6" ]; then
    ip6tables-restore -n "$dir/docker-user.v6"
  fi
}

base_firewall() {
  local unit_dir bin_dir
  unit_dir="$(p /etc/systemd/system)"
  bin_dir="$(p /usr/local/bin)"
  mkdir -p "$unit_dir" "$bin_dir"
  install -m 0644 "$VA_BASE_DIR/files/vps-apps-nft.service" "$unit_dir/vps-apps-nft.service"
  install -m 0644 "$VA_BASE_DIR/files/vps-apps-docker-user.service" "$unit_dir/vps-apps-docker-user.service"
  ln -sfn /opt/vps-apps/current/bin/rc "$bin_dir/rc"
  firewall_apply
  systemctl daemon-reload
  systemctl enable vps-apps-nft.service vps-apps-docker-user.service
}
