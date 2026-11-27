#!/usr/bin/env bash
# rc domain add <domain>. Sourced by bin/rc.

# rc_domain_add <domain>: records one more domain in /etc/vps-apps/domains (one per line) and calls
# the app's app_domain_added, which applies the whole list (the app's caddy label lives in its
# compose.expose.yml). RC_DNS_WAIT is the DNS wait in seconds (default 300, digits only).
rc_domain_add() {
  local domain file current wait="${RC_DNS_WAIT:-300}"
  [ "$#" -eq 1 ] || rc_usage
  domain="${1,,}"
  if ! valid_hostname "$domain"; then
    echo "rc domain: '$1' is not a valid domain name" >&2
    exit 2
  fi
  if ! [[ "$wait" =~ ^[0-9]+$ ]]; then
    echo "rc domain: RC_DNS_WAIT must be a number of seconds" >&2
    exit 2
  fi
  rc_load_app
  if [ "$domain" = "$VA_HOST" ]; then
    echo "rc domain: $domain is already this server's own domain" >&2
    exit 2
  fi
  rc_require_serving
  if declare -F app_domain_check >/dev/null; then
    app_domain_check "$domain" || exit 1
  fi

  echo "Point an A record for $domain to $VA_IP"
  if ! wait_for_name "$domain" "$VA_IP" "$wait"; then
    echo "$domain does not point to $VA_IP yet; the certificate is issued once it does"
  fi

  file="$(p /etc/vps-apps/domains)"
  current=""
  [ ! -f "$file" ] || current="$(cat "$file")"
  if ! printf '%s\n' "$current" | grep -qxF -- "$domain"; then
    {
      [ -z "$current" ] || printf '%s\n' "$current"
      printf '%s\n' "$domain"
    } | write_atomic "$file" 0644
  fi
  app_domain_added "$domain"
  echo "added $domain"
}

rc_domain() {
  local action="${1:-}"
  if [ "$#" -gt 0 ]; then
    shift
  fi
  case "$action" in
    add) rc_domain_add "$@" ;;
    *) rc_usage ;;
  esac
}
