#!/usr/bin/env bash
# rc port open|close|list. Sourced by bin/rc.

# rc_port_parse <arg>: print the normalised "<port>/<tcp|udp>", or exit 2.
rc_port_parse() {
  local port="${1%%/*}" proto=tcp
  if [[ "$1" == */* ]]; then
    proto="${1#*/}"
  fi
  if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
    echo "rc port: '$1' is not a port between 1 and 65535" >&2
    exit 2
  fi
  if [ "$proto" != tcp ] && [ "$proto" != udp ]; then
    echo "rc port: protocol must be tcp or udp, not '$proto'" >&2
    exit 2
  fi
  printf '%s/%s\n' "$((10#$port))" "$proto"
}

# rc_port_write <file> [entries...]: replace the open-ports file atomically.
rc_port_write() {
  local file="$1" tmp
  shift
  tmp="$file.tmp.$$"
  : >"$tmp"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" >"$tmp"
  fi
  chmod 0644 "$tmp"
  mv "$tmp" "$file"
}

rc_port() {
  local action="${1:-}" file entry have e
  local -a current kept
  if [ "$#" -gt 0 ]; then
    shift
  fi
  file="$(p /etc/vps-apps/open-ports)"
  mkdir -p "$(dirname "$file")"
  case "$action" in
    open | close)
      [ "$#" -eq 1 ] || rc_usage
      entry="$(rc_port_parse "$1")"
      if [ "$action" = close ] && [[ "$entry" == 80/* || "$entry" == 443/* ]]; then
        echo "rc port: 80 and 443 carry the proxy and stay open" >&2
        exit 2
      fi
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
      if [ "$action" = open ] && [ "$have" = yes ]; then
        echo "$entry is already open"
      elif [ "$action" = open ]; then
        rc_port_write "$file" "${current[@]}" "$entry"
        firewall_apply
        echo "opened $entry"
      elif [ "$have" = no ]; then
        echo "$entry was not open"
      else
        rc_port_write "$file" "${kept[@]}"
        firewall_apply
        echo "closed $entry"
      fi
      ;;
    list)
      [ "$#" -eq 0 ] || rc_usage
      printf '%s\n' 22/tcp 80/tcp 443/tcp
      fw_open_ports "$file"
      ;;
    *) rc_usage ;;
  esac
}
