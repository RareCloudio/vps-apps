#!/usr/bin/env bash
# Shared by CI and the local runner: shellcheck every shell file at style level, including
# the rendered recipe (sh) and the bootstrap embedded in it (bash).
# Does nothing while there are no matching files.
set -euo pipefail
cd "$(dirname "$0")/.."
files=()
while IFS= read -r f; do files+=("$f"); done < <(
  find . -type f \( -name '*.sh' -o -path './bin/*' -o -path './recipe/*.tmpl' -o -path './tests/stubs/*' \) \
    -not -name '.gitkeep' -not -path './.git/*' -not -path './.superpowers/*' | sort
)
if [ "${#files[@]}" -eq 0 ]; then
  echo "no shell files yet"
  exit 0
fi
shellcheck -S style "${files[@]}"

if [ -f recipe/recipe.sh.tmpl ] && [ -x bin/render-recipe ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  bin/render-recipe --app n8n --mode pro --version 0123456789abcdef0123456789abcdef01234567 >"$tmp/recipe.sh"
  shellcheck -S style -s sh "$tmp/recipe.sh"
  sed -n "/^cat >.*vps-apps-bootstrap\" <<'VPS_APPS_BOOTSTRAP_END_7f3a'\$/,/^VPS_APPS_BOOTSTRAP_END_7f3a\$/p" "$tmp/recipe.sh" |
    sed '1d;$d' >"$tmp/bootstrap.sh"
  if [ ! -s "$tmp/bootstrap.sh" ]; then
    echo "lint: bootstrap not found in the rendered recipe" >&2
    exit 1
  fi
  shellcheck -S style -s bash "$tmp/bootstrap.sh"
fi
