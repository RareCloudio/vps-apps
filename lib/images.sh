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

# resolve_env_images <env-file> <out-file>: write to <out-file> the content <env-file> would have
# with every <NAME>_IMAGE line re-resolved from its <NAME>_IMAGE_REF (the IMAGE line is appended
# when missing). Other lines are kept. Nothing is written to <env-file>; fails when any ref cannot
# be resolved, so a caller can resolve every file first and only then write.
resolve_env_images() {
  local file="$1" out="$2" line key name content=""
  local -A refs=() digest=() seen=()
  [ -f "$file" ] || {
    log "resolve_env_images: $file does not exist"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([A-Za-z0-9_]+_IMAGE)_REF=(.+)$ ]]; then
      refs["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done <"$file"
  for name in "${!refs[@]}"; do
    digest["$name"]="$(resolve_image_digest "${refs[$name]}")" || return 1
  done
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    if [[ "$line" == *=* && -n "${digest[$key]+x}" ]]; then
      content+="$key=${digest[$key]}"$'\n'
      seen["$key"]=1
    else
      content+="$line"$'\n'
    fi
  done <"$file"
  for name in "${!digest[@]}"; do
    [ -n "${seen[$name]+x}" ] || content+="$name=${digest[$name]}"$'\n'
  done
  printf '%s' "$content" >"$out"
}

# apply_env_images <env-file> <resolved-file>: replace <env-file> by the resolved content, keeping
# its mode, by rename.
apply_env_images() {
  write_atomic "$1" "$(stat -c %a "$1")" <"$2"
}

# refresh_image_digests <env-file>: resolve and apply one file.
refresh_image_digests() {
  local tmp rc=0
  tmp="$(mktemp)"
  resolve_env_images "$1" "$tmp" && apply_env_images "$1" "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}
