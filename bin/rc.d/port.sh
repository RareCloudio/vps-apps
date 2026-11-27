#!/usr/bin/env bash
# rc port open|close|list. Sourced by bin/rc.

# rc_port_parse <arg>: print the normalised "<port>/<tcp|udp>", or exit 2.
rc_port_parse() {
  local entry
  if ! entry="$(fw_norm_entry "$1")"; then
    echo "rc port: '$1' is not <port>[/tcp|/udp] with a port from 1 to 65535" >&2
    exit 2
  fi
  printf '%s\n' "$entry"
}

# rc_port_apply <file> <entries...>: write the candidate list and apply it; open-ports is
# replaced only when every layer loaded.
rc_port_apply() {
  local file="$1" cand
  shift
  cand="$(mktemp "$(dirname "$file")/.open-ports.XXXXXX")"
  : >"$cand"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >"$cand"
  fi
  if ! firewall_apply "$cand"; then
    rm -f "$cand"
    echo "rc port: could not apply the change, nothing changed" >&2
    exit 1
  fi
}

rc_port() {
  local action="${1:-}" file entry have e ssh_entry=no
  local -a current kept ssh_ports
  if [ "$#" -gt 0 ]; then
    shift
  fi
  case "$action" in
    open | close) [ "$#" -eq 1 ] || rc_usage ;;
    list) [ "$#" -eq 0 ] || rc_usage ;;
    *) rc_usage ;;
  esac
  file="$(p /etc/vps-apps/open-ports)"
  # SSH stays reachable on every port sshd listens on (22 always), like the firewall renders it.
  mapfile -t ssh_ports < <(fw_ssh_ports)

  if [ "$action" = list ]; then
    {
      printf '%s/tcp\n' "${ssh_ports[@]}"
      printf '%s\n' 80/tcp 443/tcp
      fw_open_ports "$file"
    } | awk '!seen[$0]++'
    return 0
  fi

  entry="$(rc_port_parse "$1")"
  # Only 22, 80 and 443 are fixed in the template. Any other port, one sshd listens on included, is
  # opened the normal way: recorded in open-ports and applied, so the loaded rules really hold it.
  case "$action:$entry" in
    open:22/tcp | open:80/tcp | open:443/tcp)
      echo "$entry is always open"
      return 0
      ;;
  esac
  for e in "${ssh_ports[@]}"; do
    [ "$entry" != "$e/tcp" ] || ssh_entry=yes
  done
  if [ "$action" = close ] && [ "$ssh_entry" = yes ]; then
    echo "rc port: $entry carries SSH, SSH stays open" >&2
    exit 2
  fi
  case "$action:$entry" in
    close:80/tcp | close:443/tcp)
      echo "rc port: 80 and 443 carry the proxy and stay open" >&2
      exit 2
      ;;
  esac

  fw_lock
  fw_open_ports "$file" >/dev/null || exit 1
  mapfile -t current < <(fw_open_ports "$file")
  have=no
  kept=()
  for e in "${current[@]}"; do
    if [ "$e" = "$entry" ]; then
      have=yes
    else
      kept+=("$e")
    fi
  done
  if [ "$action" = open ]; then
    if [ "$have" = yes ]; then
      # Already listed: apply the current list again, which repairs a half-applied state.
      rc_port_apply "$file" "${current[@]}"
      echo "$entry is already open"
    else
      rc_port_apply "$file" "${current[@]}" "$entry"
      echo "opened $entry"
    fi
  elif [ "$have" = no ]; then
    echo "$entry was not open"
  else
    rc_port_apply "$file" "${kept[@]}"
    echo "closed $entry"
  fi
}
