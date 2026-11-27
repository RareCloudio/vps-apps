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
