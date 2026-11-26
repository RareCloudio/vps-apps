#!/usr/bin/env bash
# Shared by CI and the local runner: shellcheck every shell file at style level.
# Does nothing while there are no matching files.
set -euo pipefail
cd "$(dirname "$0")/.."
files=()
while IFS= read -r f; do files+=("$f"); done < <(
  find . -type f \( -name '*.sh' -o -path './bin/*' -o -path './recipe/*.tmpl' \) \
    -not -path './.git/*' -not -path './.superpowers/*' | sort
)
if [ "${#files[@]}" -eq 0 ]; then
  echo "no shell files yet"
  exit 0
fi
shellcheck -S style "${files[@]}"
