#!/usr/bin/env bash
# Base step 5: host firewall (own nftables table) plus DOCKER-USER rules for container ports.
# Sourced, never executed; bin/rc sources it too for the render and apply helpers.

VA_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The last line of files/vps-apps.nft.tmpl: a staged nft file that does not end with it was cut short.
VA_NFT_LAST_LINE="# End of the vps-apps rules."

# fw_have <command>: true when the command exists (tests override it).
fw_have() {
  command -v "$1" >/dev/null 2>&1
}

# fw_v6: true when the IPv6 layer can be used. ip6tables-restore exists on every Ubuntu, but on a
# kernel booted with ipv6.disable=1 ip6tables cannot even list its filter table, and every load fails.
fw_v6() {
  fw_have ip6tables-restore && fw_have ip6tables && ip6tables -S >/dev/null 2>&1
}

# fw_norm_entry <port>[/tcp|/udp]: print "<port>/<proto>" with leading zeros removed (tcp when
# no protocol is given), or fail. The one validator shared by rc port and the open-ports file.
fw_norm_entry() {
  local port="${1%%/*}" proto=tcp
  if [[ "$1" == */* ]]; then
    proto="${1#*/}"
  fi
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  if [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
    return 1
  fi
  if [ "$proto" != tcp ] && [ "$proto" != udp ]; then
    return 1
  fi
  printf '%s/%s\n' "$((10#$port))" "$proto"
}

# fw_open_ports <file>: print every entry of the open-ports file as "<port>/<tcp|udp>". Blank
# lines and # comments are skipped. A malformed line fails with a message naming it, and
# nothing is printed, so callers never act on a half-read file.
fw_open_ports() {
  [ -f "$1" ] || return 0
  local raw line entry out="" n=0
  while IFS= read -r raw || [ -n "$raw" ]; do
    n=$((n + 1))
    line="${raw%%#*}"
    line="${line//[[:space:]]/}"
    [ -n "$line" ] || continue
    if ! entry="$(fw_norm_entry "$line")"; then
      echo "firewall: $1 line $n: '$raw' is not <port>/<tcp|udp> with a port from 1 to 65535" >&2
      return 1
    fi
    out+="$entry"$'\n'
  done <"$1"
  if [ -n "$out" ]; then
    printf '%s' "$out"
  fi
}

# fw_ssh_ports: every TCP port sshd listens on, from the port and listenaddress lines of sshd -T,
# plus 22 always; only 22 when sshd -T fails. One per line, sorted.
fw_ssh_ports() {
  local cfg=""
  cfg="$(sshd -T 2>/dev/null)" || cfg=""
  {
    echo 22
    awk '$1 == "port" { p = $2 }
      $1 == "listenaddress" { n = split($2, a, ":"); p = (n > 1) ? a[n] : "" }
      ($1 == "port" || $1 == "listenaddress") && p ~ /^[0-9]+$/ && p + 0 >= 1 && p + 0 <= 65535 { print p + 0 }' <<<"$cfg"
  } | sort -un
}

# render_nft <open-ports-file>: print the nftables file. Fails when the template cannot be read.
render_nft() {
  local line entry port rules="" ssh_rules="" tmpl="$VA_BASE_DIR/files/vps-apps.nft.tmpl"
  if [ ! -r "$tmpl" ]; then
    echo "firewall: cannot read $tmpl" >&2
    return 1
  fi
  while IFS= read -r entry; do
    rules+="    ${entry#*/} dport ${entry%/*} accept"$'\n'
  done < <(fw_open_ports "$1")
  rules="${rules%$'\n'}"
  # 22, 80 and 443 are on the template's fixed line; sshd may listen on other ports too.
  while IFS= read -r port; do
    case "$port" in 22 | 80 | 443) ;; *) ssh_rules+="    tcp dport $port accept"$'\n' ;; esac
  done < <(fw_ssh_ports)
  ssh_rules="${ssh_rules%$'\n'}"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "@SSH_PORT_RULES@" ]; then
      if [ -n "$ssh_rules" ]; then
        printf '%s\n' "$ssh_rules"
      fi
    elif [ "$line" = "@OPEN_PORT_RULES@" ]; then
      if [ -n "$rules" ]; then
        printf '%s\n' "$rules"
      fi
    else
      printf '%s\n' "$line"
    fi
  done <"$tmpl"
}

# fw_nft_whole <file>: the staged nft file holds our table and ends with the template's last line.
fw_nft_whole() {
  grep -qxF 'table inet vps_apps {' "$1" && [ "$(tail -n 1 "$1")" = "$VA_NFT_LAST_LINE" ]
}

# fw_docker_user_whole <file> <ext_if>: the staged DOCKER-USER file drops the outside interface and
# ends with COMMIT.
fw_docker_user_whole() {
  grep -qxF -- "-A DOCKER-USER -i $2 -j DROP" "$1" && [ "$(tail -n 1 "$1")" = COMMIT ]
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

# fw_lock: take the firewall lock for the rest of this process (rc port and firewall_apply
# must not interleave). Re-entrant within one process.
fw_lock() {
  if [ -n "${FW_LOCKED:-}" ]; then
    return 0
  fi
  local lock
  lock="$(p /etc/vps-apps/.firewall.lock)"
  mkdir -p "$(dirname "$lock")"
  exec 9>"$lock"
  flock 9
  FW_LOCKED=1
}

# fw_reload_boot_files <dir>: best effort, put the kernel back on the boot files after a
# failed load.
fw_reload_boot_files() {
  local dir="$1"
  if [ -f "$dir/vps-apps.nft" ]; then
    nft -f "$dir/vps-apps.nft" || true
  fi
  if [ -f "$dir/docker-user.v4" ]; then
    iptables-restore -n "$dir/docker-user.v4" || true
  fi
  if [ -f "$dir/docker-user.v6" ] && fw_v6; then
    ip6tables-restore -n "$dir/docker-user.v6" || true
  fi
}

# fw_apply_staged <dir> <stage-dir> <ports-file>: render into the stage dir, validate every
# layer, load, and only then move the files into place. Any failure leaves the boot files
# and open-ports exactly as they were. Callers run it inside a condition, where errexit is off,
# so every step that matters checks its own result: an empty or cut render (a full disk) must
# never replace the boot files.
fw_apply_staged() {
  local dir="$1" stage="$2" ports="$3" if4 if6 v6=no
  fw_open_ports "$ports" >/dev/null || return 1
  if4="$(fw_default_if 4)"
  if6="$(fw_default_if 6)"
  if [ -z "$if4" ]; then
    echo "firewall: no IPv4 default route, cannot pick the external interface" >&2
    return 1
  fi
  # No IPv6 default route: the IPv4 interface still names the external side.
  if [ -z "$if6" ]; then
    if6="$if4"
  fi
  render_nft "$ports" >"$stage/vps-apps.nft" || return 1
  render_docker_user "$if4" "$ports" >"$stage/docker-user.v4" || return 1
  if fw_v6; then
    v6=yes
    render_docker_user "$if6" "$ports" >"$stage/docker-user.v6" || return 1
  fi
  if ! fw_nft_whole "$stage/vps-apps.nft" || ! fw_docker_user_whole "$stage/docker-user.v4" "$if4" ||
    { [ "$v6" = yes ] && ! fw_docker_user_whole "$stage/docker-user.v6" "$if6"; }; then
    echo "firewall: the rendered rules are incomplete (is the disk full?), nothing changed" >&2
    return 1
  fi

  if ! nft -c -f "$stage/vps-apps.nft"; then
    echo "firewall: nft rejected the rules, nothing changed" >&2
    return 1
  fi
  if ! iptables-restore -t -n "$stage/docker-user.v4"; then
    echo "firewall: iptables rejected the rules, nothing changed" >&2
    return 1
  fi
  if [ "$v6" = yes ] && ! ip6tables-restore -t -n "$stage/docker-user.v6"; then
    echo "firewall: ip6tables rejected the rules, nothing changed" >&2
    return 1
  fi

  if ! nft -f "$stage/vps-apps.nft" ||
    ! iptables-restore -n "$stage/docker-user.v4" ||
    { [ "$v6" = yes ] && ! ip6tables-restore -n "$stage/docker-user.v6"; }; then
    echo "firewall: loading the rules failed, reloaded the previous rules, files unchanged" >&2
    fw_reload_boot_files "$dir"
    return 1
  fi

  mv "$stage/vps-apps.nft" "$dir/vps-apps.nft"
  mv "$stage/docker-user.v4" "$dir/docker-user.v4"
  if [ "$v6" = yes ]; then
    mv "$stage/docker-user.v6" "$dir/docker-user.v6"
  else
    rm -f "$dir/docker-user.v6"
  fi
  chmod 0644 "$dir"/vps-apps.nft "$dir"/docker-user.v[46] 2>/dev/null || true
  if [ "$ports" != "$dir/open-ports" ]; then
    chmod 0644 "$ports"
    mv "$ports" "$dir/open-ports"
  fi

  # Docker adds the FORWARD jump itself; say so when it is missing, never fail on it.
  if fw_have iptables && ! iptables -C FORWARD -j DOCKER-USER 2>/dev/null; then
    log "warning: iptables FORWARD has no jump to DOCKER-USER, container ports are not filtered yet"
  fi
  if [ "$v6" = yes ] && fw_have ip6tables && ! ip6tables -C FORWARD -j DOCKER-USER 2>/dev/null; then
    log "warning: ip6tables FORWARD has no jump to DOCKER-USER, container ports are not filtered yet"
  fi
  return 0
}

# firewall_apply [candidate-ports-file]: apply open-ports (or the candidate, which replaces
# open-ports only when everything loaded).
# shellcheck disable=SC2119,SC2120 # the optional candidate argument is passed by bin/rc.d/port.sh
firewall_apply() {
  fw_lock
  local dir stage rc=0
  dir="$(p /etc/vps-apps)"
  mkdir -p "$dir"
  if [ ! -e "$dir/open-ports" ]; then
    : >"$dir/open-ports"
    chmod 0644 "$dir/open-ports"
  fi
  if ! stage="$(mktemp -d "$dir/.apply.XXXXXX")"; then
    echo "firewall: cannot create a stage directory in $dir, nothing changed" >&2
    return 1
  fi
  fw_apply_staged "$dir" "$stage" "${1:-$dir/open-ports}" || rc=$?
  rm -rf "$stage"
  return "$rc"
}

base_firewall() {
  local unit_dir bin_dir unit
  unit_dir="$(p /etc/systemd/system)"
  bin_dir="$(p /usr/local/bin)"
  mkdir -p "$unit_dir" "$bin_dir"
  for unit in vps-apps-nft vps-apps-docker-user-early vps-apps-docker-user; do
    install -m 0644 "$VA_BASE_DIR/files/$unit.service" "$unit_dir/$unit.service"
  done
  ln -sfn /opt/vps-apps/current/bin/rc "$bin_dir/rc"
  firewall_apply
  systemctl daemon-reload
  systemctl enable vps-apps-nft.service vps-apps-docker-user-early.service vps-apps-docker-user.service
}
