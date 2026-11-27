# Shared setup for every bats file: an isolated root and stub commands first on PATH.
VPS_APPS_ROOT="$BATS_TEST_TMPDIR/root"
export VPS_APPS_ROOT
mkdir -p "$VPS_APPS_ROOT"
PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stubs:$PATH"
export PATH
export STUB_TMP="$BATS_TEST_TMPDIR"

# refute_grep <grep args>: fails the test when grep finds a match (a bare ! mid-test asserts nothing).
refute_grep() {
  if grep "$@"; then return 1; fi
}
