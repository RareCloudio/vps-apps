#!/usr/bin/env bash
# register.sh <ghrunner|glrunner>: run as root by vps-apps-<app>-register.service when the
# registration page queues a request (runner.sh, runner_handle_request). The app named must be the
# one installed here (/etc/vps-apps/app.env). Exits 0 when there was nothing to do or the runner
# registered, 1 otherwise; the page shows the outcome from the status file either way.
set -euo pipefail

VA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/common.sh
. "$VA_ROOT/lib/common.sh"
# shellcheck source=lib/images.sh
. "$VA_ROOT/lib/images.sh"
# shellcheck source=lib/compose.sh
. "$VA_ROOT/lib/compose.sh"

case "${1:-}" in
  ghrunner | glrunner) ;;
  *)
    echo "register.sh: usage: register.sh <ghrunner|glrunner>" >&2
    exit 2
    ;;
esac
if ! read_app_env || [ "$VA_APP" != "$1" ] || ! valid_hostname "$VA_HOST"; then
  echo "register.sh: $1 is not the app installed on this server" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$VA_ROOT/apps/$1/app.sh"

trap runner_finish_interrupted EXIT
# In a condition, so errexit is off inside: every step checks its own result, and a failed
# registration still puts the earlier one back and writes its status.
runner_handle_request || exit 1
