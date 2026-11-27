#!/usr/bin/env bash
# rc domain add <domain>. Sourced by bin/rc.

# rc_domain_add <domain>: records one more domain in /etc/vps-apps/domains (one per line) and calls
# the app's app_domain_added, which applies the whole list (the app's caddy label lives in its
# compose.expose.yml). RC_DNS_WAIT is the DNS wait in seconds (default 300).
rc_domain_add() {
  local domain host_re file current
  [ "$#" -eq 1 ] || rc_usage
  domain="${1,,}"
  # The same hostname rule as install.sh, plus the DNS limit of 253 characters.
  host_re='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
  if [ "${#domain}" -gt 253 ] || ! [[ "$domain" =~ $host_re ]]; then
    echo "rc domain: '$1' is not a valid domain name" >&2
    exit 2
  fi
  rc_load_app
  rc_require_serving

  echo "Point an A record for $domain to $VA_IP"
  if ! wait_for_name "$domain" "$VA_IP" "${RC_DNS_WAIT:-300}"; then
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
