#!/usr/bin/env bash
# Container image helpers. Sourced after lib/common.sh, never executed.

# resolve_image_digest <repo:tag>: echo repo@sha256:<64 hex> for the manifest the tag points to
# today. Used at install and by rc update. The ref must not contain a registry port.
resolve_image_digest() {
  local ref="$1" digest
  digest="$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' | jq -r '.digest')"
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    log "cannot resolve a digest for $ref"
    return 1
  fi
  printf '%s@%s\n' "${ref%:*}" "$digest"
}

# Image convention for every .env under /opt/vps-apps-data/<stack>/ (the proxy and each app):
#   <NAME>_IMAGE=repo@sha256:<64 hex>   what compose runs (digest pinned)
#   <NAME>_IMAGE_REF=repo:tag           the tag that digest was resolved from
# Compose files only read <NAME>_IMAGE. The REF line is what lets rc update find the digest the tag
# points to today. App tasks write both lines at install: the IMAGE line from resolve_image_digest,
# the REF line with the tag they resolved it from.

# refresh_image_digests <env-file>: re-resolve every <NAME>_IMAGE_REF and rewrite its <NAME>_IMAGE
# line (appended when missing). All refs are resolved first: when one fails nothing is written.
# Other lines and the file mode are kept; the file is replaced atomically.
refresh_image_digests() {
  local file="$1" line key resolved mode out="" name
  local -A refs=() seen=()
  [ -f "$file" ] || {
    log "refresh_image_digests: $file does not exist"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([A-Za-z0-9_]+_IMAGE)_REF=(.+)$ ]]; then
      refs["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done <"$file"
  [ "${#refs[@]}" -gt 0 ] || return 0

  local -A digest=()
  for name in "${!refs[@]}"; do
    resolved="$(resolve_image_digest "${refs[$name]}")" || return 1
    digest["$name"]="$resolved"
  done

  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    if [[ "$line" == *=* && -n "${digest[$key]+x}" ]]; then
      out+="$key=${digest[$key]}"$'\n'
      seen["$key"]=1
    else
      out+="$line"$'\n'
    fi
  done <"$file"
  for name in "${!digest[@]}"; do
    [ -n "${seen[$name]+x}" ] || out+="$name=${digest[$name]}"$'\n'
  done

  mode="$(stat -c %a "$file")"
  printf '%s' "$out" | write_atomic "$file" "$mode"
}
