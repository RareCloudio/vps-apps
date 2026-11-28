#!/usr/bin/env bash
# End-to-end smoke test of a real, fresh Ubuntu 24.04 VPS. Run from a workstation (Git Bash on
# Windows with the Windows OpenSSH client, or any bash). It never creates or deletes a server.
#
# Usage:
#   tests/e2e/vps-smoke.sh --ssh-key <path> --ip <ipv4>
#     --app <docker|n8n|nextcloud|forgejo|wordpress|uptimekuma|grafana|ghrunner|glrunner> [--mode starter|pro] \
#     --version <sha40> --password-file <file> [--checks 1,2,3] [--expect-pw-auth yes|no|auto]
#   For ghrunner and glrunner, E2E_RUNNER_URL and E2E_RUNNER_TOKEN_FILE (both optional) make check 19
#   or 20 register the runner from the page with a real repository or GitLab instance.
#
# One PASS or FAIL line per check, in the form `PASS <n> <name>` or `FAIL <n> <name>: <reason>`.
# Exit 0 only when every selected check passed. Progress goes to stderr. The password is read from
# the file and sent over ssh stdin, through jq stdin, in a curl config on stdin (curl -K -) or read
# by curl from a file in the temp dir; it is never printed and never put on a command line. The
# rendered recipe holds it, so it lives only in a 0700 temp dir that is removed when the script
# ends.
# shellcheck disable=SC2016 # remote commands are single-quoted on purpose: they expand on the VPS
set -euo pipefail
# The Virtualizor tokens are replaced as plain text; an "&" in a password must stay an "&".
shopt -u patsub_replacement 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat >&2 <<'USAGE'
usage: vps-smoke.sh --ssh-key <path> --ip <ipv4>
                    --app <docker|n8n|nextcloud|forgejo|wordpress|uptimekuma|grafana|ghrunner|glrunner>
                    [--mode starter|pro]
                    --version <sha40> --password-file <file> [--checks 1,2,3,...]
                    [--expect-pw-auth yes|no|auto] [--probe-host <ipv4>]
checks:
   1 install        render the recipe, substitute the Virtualizor tokens, run it as root
   2 status         /.well-known/rarecloud-app-status reads installing, then ready
   3 https          https://<ip-dashed>.sslip.io/ answers with a valid certificate
   4 n8n            UTC, Valkey password (pro), login, workflow run, password change, reboot, rc update (n8n only)
   5 docker         whoami over HTTPS, postgres closed/open/closed, IPv4 + IPv6 (docker only)
   6 resume         kill the install after app_up_setup, the timer resumes it (needs a fresh OS)
   7 domain         rc domain add app.<ip-dashed>.sslip.io serves the app on that name too
   8 hub-64         record the IPv6 /64, the pulls of the install and the Docker Hub rate limit
   9 timer          three minutes after ready: still ready, timer inactive, password file gone
  10 docker-info    docker info works with the daemon.json in place
  11 nft-reboot     nft -c passes; no "ordering cycle" in the journal after a reboot
  12 rc-port        rc port open/close leaves DOCKER-USER without a stale rule or a duplicate
  13 ssh            sshd on 22, password login and authorized_keys as the VPS shows them
  14 nextcloud      WebDAV as admin answers 207, a wrong password 401 (nextcloud only)
  15 forgejo        API login as gitadmin, sign-up closed, git SSH on 2222 (forgejo only)
  16 wordpress      wp-login.php as admin, installer closed, registration off, xmlrpc.php 403 (wordpress only)
  17 uptimekuma     setup no longer offered, admin logs in through the proxy (uptimekuma only)
  18 grafana        admin login, signup off, data sources, node metrics, Loki push only with its credential
  19 ghrunner       the registration page: login, CSRF, token checks, host side, the runner installed (ghrunner only)
  20 glrunner       the registration page: login, CSRF, token checks, host side, GitLab Runner running (glrunner only)
Default checks: docker 1 2 3 5 7 8 9 10 11 12 13; n8n 1 2 3 4 7 8 9 10 11 12 13; nextcloud,
forgejo, wordpress, uptimekuma, grafana, ghrunner and glrunner 1 2 3, their own check (14 to 20),
then 7 8 9 10 11 12 13. Check 6 is never a default (it installs by itself, so it cannot follow
check 1). Selected checks run in this order: 1 6 2 3 4 5 14 15 16 17 18 19 20 7 8 10 12 13 9 11.
Checks 19 and 20 register the runner for real only when E2E_RUNNER_URL (the repository,
organization or GitLab address) and E2E_RUNNER_TOKEN_FILE (a file with the registration token)
are set.
USAGE
  exit 2
}

SSH_KEY="" IP="" APP="" MODE="" VERSION="" PWFILE="" CHECKS="" EXPECT_PW="auto" PROBE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-key | --ip | --app | --mode | --version | --password-file | --checks | --expect-pw-auth | --probe-host)
      [ $# -ge 2 ] || usage
      case "$1" in
        --ssh-key) SSH_KEY="$2" ;;
        --ip) IP="$2" ;;
        --app) APP="$2" ;;
        --mode) MODE="$2" ;;
        --version) VERSION="$2" ;;
        --password-file) PWFILE="$2" ;;
        --checks) CHECKS="$2" ;;
        --expect-pw-auth) EXPECT_PW="$2" ;;
        --probe-host) PROBE="$2" ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
[[ "$IP" =~ ^${octet}(\.${octet}){3}$ ]] || { echo "vps-smoke: --ip must be an IPv4 address" >&2; usage; }
case "$APP" in
  docker | n8n | nextcloud | forgejo | wordpress | uptimekuma | grafana | ghrunner | glrunner) ;;
  *)
    echo "vps-smoke: --app must be docker, n8n, nextcloud, forgejo, wordpress, uptimekuma, grafana, ghrunner" \
      "or glrunner" >&2
    usage
    ;;
esac
case "$MODE" in
  "") ;;
  starter | pro) [ "$APP" = n8n ] || { echo "vps-smoke: --mode only goes with --app n8n" >&2; usage; } ;;
  *) echo "vps-smoke: --mode must be starter or pro" >&2; usage ;;
esac
[[ "$VERSION" =~ ^[0-9a-f]{40}$ ]] || { echo "vps-smoke: --version must be 40 lowercase hex characters" >&2; usage; }
[ -f "$SSH_KEY" ] || { echo "vps-smoke: --ssh-key file not found" >&2; usage; }
[ -f "$PWFILE" ] || { echo "vps-smoke: --password-file not found" >&2; usage; }
if [ -n "$PROBE" ]; then
  [[ "$PROBE" =~ ^${octet}(\.${octet}){3}$ ]] || { echo "vps-smoke: --probe-host must be an IPv4 address" >&2; usage; }
  [ "$PROBE" != "$IP" ] || { echo "vps-smoke: --probe-host must be another server than --ip" >&2; usage; }
fi
case "$EXPECT_PW" in yes | no | auto) ;; *) echo "vps-smoke: --expect-pw-auth must be yes, no or auto" >&2; usage ;; esac

ORDER=(1 6 2 3 4 5 14 15 16 17 18 19 20 7 8 10 12 13 9 11)
if [ -z "$CHECKS" ]; then
  case "$APP" in
    docker) CHECKS="1,2,3,5,7,8,9,10,11,12,13" ;;
    n8n) CHECKS="1,2,3,4,7,8,9,10,11,12,13" ;;
    nextcloud) CHECKS="1,2,3,14,7,8,9,10,11,12,13" ;;
    forgejo) CHECKS="1,2,3,15,7,8,9,10,11,12,13" ;;
    wordpress) CHECKS="1,2,3,16,7,8,9,10,11,12,13" ;;
    uptimekuma) CHECKS="1,2,3,17,7,8,9,10,11,12,13" ;;
    grafana) CHECKS="1,2,3,18,7,8,9,10,11,12,13" ;;
    ghrunner) CHECKS="1,2,3,19,7,8,9,10,11,12,13" ;;
    glrunner) CHECKS="1,2,3,20,7,8,9,10,11,12,13" ;;
  esac
fi
SELECTED=" "
IFS=',' read -r -a _picked <<<"$CHECKS"
for n in "${_picked[@]}"; do
  [[ "$n" =~ ^([1-9]|1[0-9]|20)$ ]] || { echo "vps-smoke: --checks takes numbers from 1 to 20" >&2; usage; }
  SELECTED="$SELECTED$n "
done
if [[ "$SELECTED" == *" 1 "* && "$SELECTED" == *" 6 "* ]]; then
  echo "vps-smoke: checks 1 and 6 both install; run 6 alone on a fresh OS" >&2
  exit 2
fi

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "vps-smoke: $tool is required" >&2; exit 2; }
done

if [ -n "${E2E_SSH:-}" ]; then
  SSH_BIN="$E2E_SSH"
elif [ -x /c/Windows/System32/OpenSSH/ssh.exe ]; then
  SSH_BIN=/c/Windows/System32/OpenSSH/ssh.exe
else
  SSH_BIN=ssh
fi
if [ "$SSH_BIN" != ssh ] && [ -x "$(dirname "$SSH_BIN")/ssh-keygen.exe" ]; then
  KEYGEN_BIN="$(dirname "$SSH_BIN")/ssh-keygen.exe"
else
  KEYGEN_BIN=ssh-keygen
fi
if [ "$SSH_BIN" != ssh ] && [ -x "$(dirname "$SSH_BIN")/ssh-keyscan.exe" ]; then
  KEYSCAN_BIN="$(dirname "$SSH_BIN")/ssh-keyscan.exe"
else
  KEYSCAN_BIN=ssh-keyscan
fi

# winpath <path>: the form a native Windows program understands; the path itself elsewhere.
winpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

TMP="$(mktemp -d)"
chmod 700 "$TMP"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

IPD="${IP//./-}"
HOST="$IPD.sslip.io"
# The customer email Virtualizor puts in {{username}}; it becomes the n8n owner login and the
# WordPress admin email.
OWNER_EMAIL="e2e-owner@$HOST"
KNOWN_HOSTS="$TMP/known_hosts"
JAR="$TMP/jar"
BODY="$TMP/body"
APIKEY_HDR="$TMP/apikey.hdr"
: >"$KNOWN_HOSTS"

SSH_OPTS=(-T -i "$(winpath "$SSH_KEY")" -o IdentitiesOnly=yes -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$(winpath "$KNOWN_HOSTS")"
  -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o LogLevel=ERROR)

PW="$(
  cat "$PWFILE"
  printf x
)"
PW="${PW%x}"

READY=unknown # unknown | yes | no
REASON=""
NOTE=""

exec 9>&2 # curl_t logs its retries here, even where a caller sends stderr to /dev/null
say() { printf '[%4ss] %s\n' "$SECONDS" "$*" >&2; }
fail() {
  REASON="$*"
  return 1
}

# Every remote call has a ceiling (120 s by default), so a hung remote command cannot block the run.
# vcmd <command string>: run on the VPS as root, stdin closed.
vcmd() { timeout 120 "$SSH_BIN" "${SSH_OPTS[@]}" "root@$IP" "$1" </dev/null; }
# vcmd_t <seconds> <command string>: the same with another ceiling.
vcmd_t() {
  local secs="$1"
  shift
  timeout "$secs" "$SSH_BIN" "${SSH_OPTS[@]}" "root@$IP" "$1" </dev/null
}
# vscript_t <seconds> [args...]: run the script on stdin with bash on the VPS. Args must be plain tokens.
vscript_t() {
  local secs="$1"
  shift
  timeout "$secs" "$SSH_BIN" "${SSH_OPTS[@]}" "root@$IP" "bash -s -- $*"
}
# vscript [args...]: vscript_t with the default ceiling.
vscript() { vscript_t 120 "$@"; }

wait_ssh() {
  local deadline=$((SECONDS + $1))
  until vcmd true >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# http_code <curl args...>: the HTTP status, 000 when nothing answered.
http_code() {
  curl_t -sS -o /dev/null -w '%{http_code}' --max-time 15 "$@" 2>/dev/null || true
}

status_now() { curl -s --max-time 5 "http://$IP/.well-known/rarecloud-app-status" 2>/dev/null | tr -d '\r\n' || true; }

# curl_t <curl args...>: curl, with a few retries on transport errors (35 TLS, 52, 56, 7, 28). The
# Windows TLS stack (schannel) sometimes fails a handshake for no reason. Only the last attempt's
# stdout is printed, so a -w '%{http_code}' value is never doubled.
curl_t() {
  local try out rc
  for try in 1 2 3 4; do
    rc=0
    out="$(curl "$@")" || rc=$?
    case "$rc" in
      35 | 52 | 56 | 7 | 28) ;;
      *) break ;;
    esac
    [ "$try" -lt 4 ] || break
    say "curl transport error $rc, retry $try of 3" 2>&9
    sleep 2
  done
  printf '%s' "$out"
  return "$rc"
}

# https_has <url> <grep pattern>: the page loads and contains the pattern.
https_has() {
  local out
  out="$(curl_t -fsS --max-time 15 "$1" 2>/dev/null)" || return 1
  grep -q "$2" <<<"$out"
}

# curl_cred <user> <password file> <curl args...>: curl with the basic credential in a config read
# on stdin (curl -K -), so the password is on no command line. In the config's double quotes a
# backslash and a double quote are escaped. Transport errors are retried as in curl_t, and every
# attempt gets the config again.
curl_cred() {
  local cfg pw try out rc bs="\\" q='"'
  pw="$(
    cat "$2"
    printf x
  )"
  pw="${pw%x}"
  # Quoted replacements: an unquoted \\\\ collapses to one backslash in bash 5.3.
  pw="${pw//"$bs"/"$bs$bs"}"
  pw="${pw//"$q"/"$bs$q"}"
  cfg="user = \"$1:$pw\""
  pw=""
  shift 2
  for try in 1 2 3 4; do
    rc=0
    out="$(curl -K - "$@" <<<"$cfg")" || rc=$?
    case "$rc" in
      35 | 52 | 56 | 7 | 28) ;;
      *) break ;;
    esac
    [ "$try" -lt 4 ] || break
    say "curl transport error $rc, retry $try of 3" 2>&9
    sleep 2
  done
  printf '%s' "$out"
  return "$rc"
}

# app_health_path: the page Nextcloud, Forgejo, WordPress and Uptime Kuma answer once they are up
# (the one their ready check reads); nothing for docker and n8n. Uptime Kuma's / only redirects. The
# runner apps' page answers it only behind its login (app_health_ok).
app_health_path() {
  case "$APP" in
    nextcloud) echo /status.php ;;
    forgejo) echo /api/healthz ;;
    wordpress) echo '/?rest_route=/' ;;
    uptimekuma) echo /api/entry-page ;;
    grafana) echo /api/health ;;
    ghrunner | glrunner) echo /healthz ;;
  esac
}

# app_health_ok <name>: https://<name><health path> loads with a valid certificate and says the app
# is up: Nextcloud installed, Forgejo's health check passing, WordPress naming https://<host> as its
# home, Uptime Kuma's entry page. A runner app's page answers ok behind its login (runner_health_ok).
app_health_ok() {
  local out
  if is_runner_app; then
    runner_health_ok "$1"
    return
  fi
  out="$(curl_t -fsS --max-time 15 "https://$1$(app_health_path)" 2>/dev/null)" || return 1
  case "$APP" in
    nextcloud) jq -e '.installed == true' <<<"$out" ;;
    forgejo) jq -e '.status == "pass"' <<<"$out" ;;
    wordpress) jq -e --arg h "https://$HOST" '.home == $h' <<<"$out" ;;
    uptimekuma) jq -e '.type == "entryPage"' <<<"$out" ;;
    grafana) jq -e '.database == "ok"' <<<"$out" ;;
    *) false ;;
  esac >/dev/null 2>&1
}

# app_pw_file <file>: the password the app's admin logs in with, into <file>: the generated one from
# /root/vps-apps-credentials.txt when the install had to make one (NOTE then says so), else the
# install password. The generated one is read over ssh into the private temp dir, never printed.
app_pw_file() {
  local gen
  gen="$(vcmd 'sed -n "s/^Password: //p" /root/vps-apps-credentials.txt 2>/dev/null | head -n 1' 2>/dev/null | tr -d '\r\n')" || gen=""
  if [ -n "$gen" ]; then
    printf '%s' "$gen" >"$1"
    NOTE="the install password was refused: logged in with the generated one from /root/vps-apps-credentials.txt"
  else
    printf '%s' "$PW" >"$1"
  fi
  gen=""
}

# --- the runner apps' page (ghrunner, glrunner) --------------------------------------------------

is_runner_app() { [ "$APP" = ghrunner ] || [ "$APP" = glrunner ]; }

# The page login's password (app_pw_file), read once for the health checks; check 19 and 20 read it
# again so NOTE says when it is a generated one. RUNNER_JAR keeps the page's CSRF cookie.
RUNNER_PW="$TMP/runner.pw"
RUNNER_JAR="$TMP/runner.jar"

# runner_gate_closed <name>: https://<name>/ answers 401 with a Basic challenge over a valid
# certificate: the page asks for its login before it shows anything.
runner_gate_closed() {
  local head
  head="$(curl_t -sS -o /dev/null -D - --max-time 15 "https://$1/" 2>/dev/null)" || return 1
  [[ "$head" =~ ^HTTP/[0-9.]+\ 401 ]] || return 1
  grep -qi '^www-authenticate: *basic' <<<"$head"
}

# runner_health_ok <name>: https://<name>/healthz answers ok with the page login.
runner_health_ok() {
  local out
  [ -s "$RUNNER_PW" ] || app_pw_file "$RUNNER_PW"
  out="$(curl_cred admin "$RUNNER_PW" -fsS --max-time 15 "https://$1/healthz" 2>/dev/null)" || return 1
  [ "$out" = ok ]
}

# runner_get: GET https://<host>/ as admin, the page in BODY and its cookie in RUNNER_JAR; prints the
# HTTP status.
runner_get() {
  local code
  : >"$BODY"
  code="$(curl_cred admin "$RUNNER_PW" -sS -o "$(winpath "$BODY")" -c "$(winpath "$RUNNER_JAR")" \
    -w '%{http_code}' --max-time 30 "https://$HOST/" 2>/dev/null)" || code=000
  printf '%s' "${code:-000}"
}

# runner_post <csrf> <origin> <address> <token file>: the page's form, POSTed as admin with the
# cookie from runner_get. The token is url-encoded by curl from <token file>, never an argument.
# The answer is in BODY; prints the HTTP status.
runner_post() {
  local code
  : >"$BODY"
  code="$(curl_cred admin "$RUNNER_PW" -sS -o "$(winpath "$BODY")" -b "$(winpath "$RUNNER_JAR")" \
    -w '%{http_code}' --max-time 30 -H "Origin: $2" --data-urlencode "csrf=$1" --data-urlencode "url=$3" \
    --data-urlencode "token@$(winpath "$4")" "https://$HOST/" 2>/dev/null)" || code=000
  printf '%s' "${code:-000}"
}

# runner_state_settled: the page, as the customer sees it, shows the registration finished, either
# registered or failed (the page is then in BODY).
runner_state_settled() {
  [ "$(runner_get)" = 200 ] && grep -qE 'class="state-(registered|failed)"' "$BODY"
}

# tcp_open <host> <port>: 0 when a TCP connection is made within 5 seconds. With --probe-host the
# attempt is made from that server over ssh; an ssh failure there is not a "closed" answer, it sets
# PROBE_BROKEN so that a negative probe cannot pass for the wrong reason.
PROBE_BROKEN=no
tcp_open() {
  local out
  if [ -n "$PROBE" ]; then
    out="$(timeout 40 "$SSH_BIN" "${SSH_OPTS[@]}" "root@$PROBE" \
      "if timeout 5 bash -c 'exec 3<>\"/dev/tcp/$1/$2\"' 2>/dev/null; then echo OPEN; else echo CLOSED; fi" </dev/null 2>/dev/null | tr -d '\r\n')" || out=""
    case "$out" in
      OPEN) return 0 ;;
      CLOSED) return 1 ;;
      *) PROBE_BROKEN=yes; return 1 ;;
    esac
  fi
  timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null
}

# retry <seconds> <interval> <command...>: 0 as soon as the command succeeds.
retry() {
  local deadline=$((SECONDS + $1)) interval="$2"
  shift 2
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "$interval"
  done
}

# ---------------------------------------------------------------------------------------------
# The recipe: rendered, filled in like Virtualizor, run as root the way its rc.local hook does.
# ---------------------------------------------------------------------------------------------

# deploy_recipe: sets REASON and returns 1 on failure. Never prints the password.
deploy_recipe() {
  local args=(--app "$APP" --version "$VERSION") content out rc=0 local_sum remote_sum
  [ -z "$MODE" ] || args+=(--mode "$MODE")
  content="$(
    "$ROOT/bin/render-recipe" "${args[@]}"
    printf x
  )" || { fail "bin/render-recipe failed"; return 1; }
  content="${content%x}"
  content="${content//'{{vps_hostname}}'/$HOST}"
  content="${content//'{{ips}}'/$IP}"
  content="${content//'{{username}}'/$OWNER_EMAIL}"
  content="${content//'{{root_pass}}'/$PW}"
  printf '%s' "$content" >"$TMP/recipe.sh"
  content=""
  say "running the recipe on $IP as root (app=$APP mode=${MODE:-default} host=$HOST)"
  out="$(timeout 1800 "$SSH_BIN" "${SSH_OPTS[@]}" "root@$IP" \
    'umask 077; f="$(mktemp)"; cat >"$f"; r=0; sh "$f" || r=$?; rm -f "$f"; exit "$r"' \
    <"$TMP/recipe.sh" 2>&1)" || rc=$?
  rm -f "$TMP/recipe.sh"
  if [[ "$out" == *"$PW"* ]]; then
    fail "the recipe output contains the password"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    fail "the recipe exited $rc: $(printf '%s' "$out" | tail -n 5 | tr '\n' ' ')"
    return 1
  fi
  vcmd 'systemctl is-enabled vps-apps-install.timer >/dev/null && systemctl is-active vps-apps-install.timer >/dev/null' >/dev/null 2>&1 ||
    { fail "vps-apps-install.timer is not enabled and active after the recipe"; return 1; }
  # The password reached the VPS byte for byte (the file is destroyed only at ready, minutes later).
  local_sum="$(printf '%s' "$PW" | sha256sum | cut -d' ' -f1)"
  remote_sum="$(vcmd 'test -f /etc/vps-apps/password && sha256sum /etc/vps-apps/password | cut -d" " -f1 || true' 2>/dev/null | tr -d '\r\n')"
  [ -n "$remote_sum" ] || { fail "/etc/vps-apps/password does not exist right after the recipe"; return 1; }
  if [ "$remote_sum" != "$local_sum" ]; then
    fail "/etc/vps-apps/password is not the password byte for byte"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------
# Waiting for ready
# ---------------------------------------------------------------------------------------------

dump_install_log() {
  say "--- install log tail ---"
  vcmd 'tail -n 40 /var/log/vps-apps-install.log 2>/dev/null; journalctl -u vps-apps-install.service -n 20 --no-pager 2>/dev/null' >&2 2>/dev/null || true
}

# wait_ready: polls the public status until ready. Sets SAW_INSTALLING. A failed:<step> that
# stays for five minutes (the timer retries every minute) is final.
SAW_INSTALLING=no
FAILED_SEEN=""
FACTS=""
# capture_facts: the Docker Hub pull count and rate limit headers, taken the moment the install is
# ready, before any check restarts the daemon or reboots (the event buffer is not durable).
capture_facts() {
  FACTS="$(vscript <<'EOF' 2>/dev/null | tr -d '\r'
pulls="$(docker events --since 24h --until "$(date +%s)" --filter type=image --filter event=pull --format x 2>/dev/null | wc -l)"
tok="$(curl -fsS --max-time 20 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull' 2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
hdr=""
if [ -n "$tok" ]; then
  hdr="$(curl -fsSI --max-time 20 -H "Authorization: Bearer $tok" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest 2>/dev/null | tr -d '\r' | grep -i '^\(ratelimit-limit\|ratelimit-remaining\|docker-ratelimit-source\):' | tr '\n' ' ')"
fi
echo "pulls=$pulls hub: ${hdr:-no rate limit headers}"
EOF
  )" || FACTS=""
}

wait_ready() {
  local deadline=$((SECONDS + 3000)) last="" now failed_since=0
  while :; do
    now="$(status_now)"
    if [ "$now" != "$last" ]; then
      say "status: ${now:-no answer}"
      last="$now"
    fi
    case "$now" in
      installing) SAW_INSTALLING=yes; failed_since=0 ;;
      ready)
        READY=yes
        if [ "$SAW_INSTALLING" = yes ]; then capture_facts; else FACTS="unreliable: ready was not observed being installed in this run"; fi
        return 0
        ;;
      failed:*)
        [[ " $FAILED_SEEN " == *" $now "* ]] || FAILED_SEEN="$FAILED_SEEN $now"
        [ "$failed_since" -ne 0 ] || failed_since=$SECONDS
        if [ $((SECONDS - failed_since)) -ge 300 ]; then
          READY=no
          fail "status stayed $now for five minutes"
          dump_install_log
          return 1
        fi
        ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then
      READY=no
      fail "status never reached ready (last: ${now:-no answer})"
      dump_install_log
      return 1
    fi
    sleep 3
  done
}

ensure_ready() {
  case "$READY" in
    yes) return 0 ;;
    no) fail "the install did not become ready"; return 1 ;;
  esac
  wait_ready
}

# ---------------------------------------------------------------------------------------------
# Checks. A check returns 0 for PASS, or calls fail "<reason>" and returns 1.
# ---------------------------------------------------------------------------------------------

check_1_install() {
  local r
  r="$(vcmd '. /etc/os-release; echo "$ID $VERSION_ID"' 2>&1)" || { fail "cannot ssh to root@$IP: $r"; return 1; }
  [ "$r" = "ubuntu 24.04" ] || { fail "the VPS runs '$r', not ubuntu 24.04"; return 1; }
  vcmd 'test ! -e /etc/vps-apps' >/dev/null 2>&1 || { fail "/etc/vps-apps already exists: this is not a fresh VPS, reinstall the OS first"; return 1; }
  deploy_recipe
}

check_2_status() {
  SAW_INSTALLING=no
  wait_ready || return 1
  [ "$SAW_INSTALLING" = yes ] || { fail "the status never read installing before ready"; return 1; }
  NOTE="attempts=$(vcmd 'cat /var/lib/vps-apps/attempts 2>/dev/null || echo unknown' | tr -d '\r\n') failed-seen=${FAILED_SEEN:-none}"
}

check_3_https() {
  local body="$TMP/https.body" vr
  say "waiting for a valid certificate on https://$HOST/"
  ensure_ready || return 1
  if is_runner_app; then
    # The page answers nothing without its login: the gate closed is the reply to wait for.
    retry 300 5 runner_gate_closed "$HOST" ||
      { fail "https://$HOST/ never asked for the page login over a valid certificate"; return 1; }
  else
    retry 300 5 curl_t -fsS --max-time 15 -o "$body" "https://$HOST/" 2>/dev/null ||
      { fail "curl -fsS https://$HOST/ never passed (certificate or reply)"; return 1; }
  fi
  vr="$(curl_t -sS --max-time 15 -o /dev/null -w '%{ssl_verify_result}' "https://$HOST/" 2>/dev/null || true)"
  [ "$vr" = 0 ] || { fail "certificate verify result is '$vr'"; return 1; }
  if [ "$APP" = docker ] && ! grep -q 'Your Docker server is ready' "$body"; then
    fail "the Docker landing page text is missing"
    return 1
  fi
  if [ -n "$(app_health_path)" ] && ! retry 120 5 app_health_ok "$HOST"; then
    fail "https://$HOST$(app_health_path) does not answer as a running $APP"
    return 1
  fi
}

# --- n8n helpers -------------------------------------------------------------------------------

# n8n_req <method> <path> [json file]: the request body comes from the file when given. Sets CODE, so
# it must never run as a stage of a pipeline (a pipeline stage is a subshell and CODE would be lost).
# The response is in $BODY. APIKEY_HDR is sent when it exists.
CODE=""
n8n_req() {
  local method="$1" path="$2" hdr=()
  [ ! -f "$APIKEY_HDR" ] || hdr=(-H "@$(winpath "$APIKEY_HDR")")
  : >"$BODY"
  if [ $# -ge 3 ]; then
    CODE="$(curl_t -sS --max-time 60 -o "$(winpath "$BODY")" -w '%{http_code}' -X "$method" \
      -H 'Content-Type: application/json' -H 'browser-id: e2e-smoke' "${hdr[@]}" \
      -b "$(winpath "$JAR")" -c "$(winpath "$JAR")" --data-binary "@$(winpath "$3")" "https://$HOST$path" 2>/dev/null)" || CODE=000
  else
    CODE="$(curl_t -sS --max-time 60 -o "$(winpath "$BODY")" -w '%{http_code}' -X "$method" \
      -H 'browser-id: e2e-smoke' "${hdr[@]}" \
      -b "$(winpath "$JAR")" -c "$(winpath "$JAR")" "https://$HOST$path" </dev/null 2>/dev/null)" || CODE=000
  fi
}

# n8n_login <password file> <window seconds>: 0 on 200; 1 at once on 401/400; retries other codes
# (the proxy or n8n may still be starting) until the window ends.
n8n_login() {
  local deadline=$((SECONDS + $2))
  while :; do
    jq -n --arg e "$OWNER_EMAIL" --rawfile p "$(winpath "$1")" '{emailOrLdapLoginId: $e, password: $p}' >"$TMP/login.json"
    n8n_req POST /rest/login "$TMP/login.json"
    rm -f "$TMP/login.json"
    case "$CODE" in
      200) return 0 ;;
      400 | 401) return 1 ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 5
  done
}

n8n_webhook_ok() {
  local out
  out="$(curl_t -sS --max-time 30 "https://$HOST/webhook/$1" 2>/dev/null)" || return 1
  jq -e 'if type == "array" then .[0].smoke == "ok" else .smoke == "ok" end' <<<"$out" >/dev/null 2>&1
}

n8n_api_executions() {
  n8n_req GET "/api/v1/executions?workflowId=$1&limit=5"
  [ "$CODE" = 200 ] && jq -e '(.data | length) >= 1' "$BODY" >/dev/null 2>&1
}

reboot_vps() {
  local before after deadline
  before="$(vcmd 'cat /proc/sys/kernel/random/boot_id' | tr -d '\r\n')"
  [ -n "$before" ] || { REASON="cannot read the boot id before the reboot"; return 1; }
  say "rebooting the VPS"
  vcmd 'systemctl reboot' >/dev/null 2>&1 || true
  deadline=$((SECONDS + 600))
  while :; do
    sleep 10
    after="$(vcmd_t 20 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "$after" ] && [ "$after" != "$before" ]; then
      return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
  done
}

check_4_n8n() {
  local wf_id wf_path key n_all n_utc newpw="$TMP/newpw" oldpw="$TMP/oldpw" wfjson="$TMP/wf.json"
  [ "$APP" = n8n ] || { fail "needs --app n8n"; return 1; }
  ensure_ready || return 1
  : >"$JAR"
  rm -f "$APIKEY_HDR"
  printf '%s' "$PW" >"$oldpw"

  say "n8n: login with the install password"
  n8n_login "$oldpw" 120 || { fail "POST /rest/login with the install password answered HTTP $CODE"; return 1; }

  if [ "$MODE" = pro ]; then
    r="$(vscript <<'EOF'
w=0; v=0
for c in $(docker ps -q); do
  s="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$c")"
  case "$s" in n8n-worker) w=$((w+1)) ;; valkey) v=$((v+1)) ;; esac
done
echo "workers=$w valkey=$v"
EOF
    )" || { fail "cannot inspect the containers"; return 1; }
    [ "$r" = "workers=2 valkey=1" ] || { fail "pro mode expects 2 workers and 1 valkey, found: $r"; return 1; }

    say "n8n: Valkey refuses a client without its password, and the password is on no command line"
    r="$(vscript <<'EOF'
c="$(docker ps -q --filter label=com.docker.compose.service=valkey | head -n1)"
[ -n "$c" ] || { echo "no valkey container"; exit 0; }
anon="$(docker exec "$c" valkey-cli ping 2>&1)"
case "$anon" in *NOAUTH*) anon=NOAUTH ;; esac
auth="$(docker exec "$c" sh -c 'REDISCLI_AUTH="$VALKEY_PASSWORD" valkey-cli ping' 2>&1)"
t="$(mktemp -d)"
sed -n 's/^VALKEY_PASSWORD=//p' /opt/vps-apps-data/n8n/.env >"$t/pw"
ps -eo args >"$t/ps"
seen="$(grep -cF -f "$t/pw" "$t/ps")"
[ -s "$t/pw" ] || seen=no-password
rm -rf "$t"
echo "anon=$anon auth=$auth seen=$seen"
EOF
    )" || { fail "cannot check Valkey"; return 1; }
    [ "$r" = "anon=NOAUTH auth=PONG seen=0" ] || { fail "Valkey: expected anon=NOAUTH auth=PONG seen=0, found: $r"; return 1; }
  fi

  say "n8n: n8n and its workers run on UTC"
  r="$(vscript <<'EOF'
n=0; utc=0
for c in $(docker ps -q); do
  s="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$c")"
  case "$s" in
    n8n | n8n-worker)
      n=$((n+1))
      k="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | grep -cxE 'GENERIC_TIMEZONE=UTC|TZ=UTC')"
      [ "$k" != 2 ] || utc=$((utc+1))
      ;;
  esac
done
echo "$n $utc"
EOF
  )" || { fail "cannot inspect the containers"; return 1; }
  read -r n_all n_utc <<<"$r"
  if ! [[ "${n_all:-}" =~ ^[0-9]+$ ]] || [ "$n_all" -lt 1 ] || [ "$n_all" != "${n_utc:-}" ]; then
    fail "expected every n8n container on GENERIC_TIMEZONE=UTC and TZ=UTC, found $r (containers, on UTC)"
    return 1
  fi

  say "n8n: create an API key and a webhook workflow"
  printf '{"label":"e2e-smoke","scopes":["workflow:create","workflow:read","workflow:delete","workflow:list","workflow:activate","execution:list","execution:read"],"expiresAt":null}' >"$TMP/req.json"
  n8n_req POST /rest/api-keys "$TMP/req.json"
  rm -f "$TMP/req.json"
  [ "$CODE" = 200 ] || { fail "POST /rest/api-keys answered HTTP $CODE: $(head -c 200 "$BODY")"; return 1; }
  key="$(jq -r '.data.rawApiKey // empty' "$BODY")"
  [ -n "$key" ] || { fail "no rawApiKey in the API key response"; return 1; }
  printf 'X-N8N-API-KEY: %s\n' "$key" >"$APIKEY_HDR"
  key=""

  wf_path="e2e-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  jq -n --arg path "$wf_path" '{
    name: "e2e smoke",
    nodes: [
      {id: "11111111-1111-4111-8111-111111111111", name: "Webhook", type: "n8n-nodes-base.webhook", typeVersion: 2, position: [0, 0],
       webhookId: "22222222-2222-4222-8222-222222222222",
       parameters: {path: $path, httpMethod: "GET", responseMode: "lastNode"}},
      {id: "33333333-3333-4333-8333-333333333333", name: "Mark", type: "n8n-nodes-base.set", typeVersion: 3.4, position: [220, 0],
       parameters: {assignments: {assignments: [{id: "44444444-4444-4444-8444-444444444444", name: "smoke", value: "ok", type: "string"}]}, options: {}}}
    ],
    connections: {Webhook: {main: [[{node: "Mark", type: "main", index: 0}]]}},
    settings: {}
  }' >"$wfjson"
  n8n_req POST /api/v1/workflows "$wfjson"
  rm -f "$wfjson"
  [ "$CODE" = 200 ] || { fail "POST /api/v1/workflows answered HTTP $CODE: $(head -c 300 "$BODY")"; return 1; }
  wf_id="$(jq -r '.id // empty' "$BODY")"
  [ -n "$wf_id" ] || { fail "no workflow id in the create response"; return 1; }
  printf '{}' >"$TMP/req.json"
  n8n_req POST "/api/v1/workflows/$wf_id/activate" "$TMP/req.json"
  rm -f "$TMP/req.json"
  [ "$CODE" = 200 ] || { fail "activating the workflow answered HTTP $CODE: $(head -c 300 "$BODY")"; return 1; }

  say "n8n: run the workflow through its production webhook"
  retry 60 3 n8n_webhook_ok "$wf_path" || { fail "the webhook did not return the Set node output"; return 1; }
  retry 60 3 n8n_api_executions "$wf_id" || { fail "no execution of the workflow was recorded (HTTP $CODE)"; return 1; }

  say "n8n: change the owner password"
  newpw_value="Nw9$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s' "$newpw_value" >"$newpw"
  newpw_value=""
  jq -n --rawfile c "$(winpath "$oldpw")" --rawfile n "$(winpath "$newpw")" '{currentPassword: $c, newPassword: $n}' >"$TMP/req.json"
  n8n_req PATCH /rest/me/password "$TMP/req.json"
  rm -f "$TMP/req.json"
  [ "$CODE" = 200 ] || { fail "PATCH /rest/me/password answered HTTP $CODE: $(head -c 200 "$BODY")"; return 1; }
  : >"$JAR"
  if n8n_login "$oldpw" 20; then fail "the old password still works after the change"; return 1; fi
  case "$CODE" in
    401 | 403) ;;
    *) fail "the old password was not explicitly rejected (HTTP $CODE, expected 401 or 403)"; return 1 ;;
  esac
  n8n_login "$newpw" 30 || { fail "the new password does not log in (HTTP $CODE)"; return 1; }

  reboot_vps || { fail "the VPS did not come back after the reboot"; return 1; }
  say "n8n: login with the new password after the reboot"
  : >"$JAR"
  n8n_login "$newpw" 420 || { fail "the new password does not work after reboot (HTTP $CODE)"; return 1; }
  retry 120 5 n8n_webhook_ok "$wf_path" || { fail "the webhook does not answer after the reboot"; return 1; }

  say "n8n: rc update"
  vcmd_t 1500 'rc update' >&2 2>&1 || { fail "rc update failed"; return 1; }
  : >"$JAR"
  n8n_login "$newpw" 420 || { fail "the new password does not work after rc update (HTTP $CODE)"; return 1; }
  retry 120 5 n8n_webhook_ok "$wf_path" || { fail "the webhook does not answer after rc update"; return 1; }

  n8n_req DELETE "/api/v1/workflows/$wf_id" || true
  rm -f "$oldpw" "$newpw" "$APIKEY_HDR"
  return 0
}

# --- docker -----------------------------------------------------------------------------------

TARGETS=()
HAVE_V6=no
V6_ADDR=""
# detect_targets: the targets the reachability probes use. With --probe-host IPv6 is required, from a
# second server that must itself have IPv6; without it IPv6 is tested only when this PC has it.
detect_targets() {
  local pv6=""
  TARGETS=("$IP")
  HAVE_V6=no
  V6_ADDR="$(vscript <<'EOF' | tr -d '\r\n'
ip -6 -o addr show scope global 2>/dev/null | awk '!/deprecated|temporary/ { sub("/.*", "", $4); print $4; exit }'
EOF
  )" || V6_ADDR=""
  if [ -n "$PROBE" ]; then
    [ -n "$V6_ADDR" ] || { REASON="--probe-host needs IPv6: the target VPS has no global IPv6 address"; return 1; }
    pv6="$(timeout 120 "$SSH_BIN" "${SSH_OPTS[@]}" "root@$PROBE" \
      "ip -6 -o addr show scope global 2>/dev/null | awk '!/deprecated|temporary/ { sub(\"/.*\", \"\", \$4); print \$4; exit }'" </dev/null 2>/dev/null | tr -d '\r\n')" || pv6=""
    [ -n "$pv6" ] || { REASON="--probe-host needs IPv6 and $PROBE has no global IPv6 address (or ssh to it failed)"; return 1; }
    HAVE_V6=yes
    TARGETS+=("$V6_ADDR")
  elif [ -z "$V6_ADDR" ]; then
    NOTE="IPv6 NOT TESTED: the VPS has no global IPv6 address"
  elif ! tcp_open 2606:4700:4700::1111 443; then
    NOTE="IPv6 NOT TESTED: this PC has no IPv6 connectivity (use --probe-host)"
  else
    HAVE_V6=yes
    TARGETS+=("$V6_ADDR")
  fi
}

# unreachable <port>: no target answers on the port (two tries each).
unreachable() {
  local t
  for t in "${TARGETS[@]}"; do
    for _ in 1 2; do
      if tcp_open "$t" "$1"; then
        REASON="port $1 answers on $t but should be closed"
        return 1
      fi
      if [ "$PROBE_BROKEN" = yes ]; then
        REASON="the probe host gave no answer over ssh, so port $1 on $t was not really tested"
        return 1
      fi
    done
  done
}
# reachable <port>: every target answers on the port (up to four tries each).
reachable() {
  local t ok
  for t in "${TARGETS[@]}"; do
    ok=no
    for _ in 1 2 3 4; do
      if tcp_open "$t" "$1"; then ok=yes; break; fi
      sleep 2
    done
    [ "$ok" = yes ] || { REASON="port $1 does not answer on $t but should be open"; return 1; }
  done
}

pg_wait() {
  vscript_t 200 <<'EOF' >/dev/null 2>&1
for i in $(seq 60); do
  docker exec smoke-pg pg_isready -U postgres -q && exit 0
  sleep 2
done
exit 1
EOF
}

restart_unit() {
  local unit="$1"
  say "systemctl restart $unit"
  vcmd_t 300 "systemctl restart $unit" >/dev/null 2>&1 || { REASON="systemctl restart $unit failed"; return 1; }
  retry 120 3 vcmd 'docker info >/dev/null 2>&1' || { REASON="docker is not answering after restarting $unit"; return 1; }
  pg_wait || { REASON="the postgres container is not ready after restarting $unit"; return 1; }
  sleep 5
}

c5_cleanup() { vcmd 'docker rm -f smoke-whoami smoke-pg >/dev/null 2>&1 || true' >/dev/null 2>&1 || true; }

# c5_body: the closed/open/closed sequence; REASON says what broke.
c5_body() {
  unreachable 5432 || return 1
  vcmd_t 120 'rc port open 5432' >/dev/null 2>&1 || { REASON="rc port open 5432 failed"; return 1; }
  reachable 5432 || return 1
  restart_unit docker || return 1
  reachable 5432 || return 1
  restart_unit vps-apps-nft || return 1
  reachable 5432 || return 1
  vcmd_t 120 'rc port close 5432' >/dev/null 2>&1 || { REASON="rc port close 5432 failed"; return 1; }
  unreachable 5432 || return 1
  restart_unit docker || return 1
  unreachable 5432 || return 1
  restart_unit vps-apps-nft || return 1
  unreachable 5432 || return 1
  vcmd 'iptables -S FORWARD | grep -q -- "-j DOCKER-USER"' >/dev/null 2>&1 || { REASON="iptables -S FORWARD has no jump to DOCKER-USER"; return 1; }
}

check_5_docker() {
  local body="$TMP/whoami.body" rc=0
  [ "$APP" = docker ] || { fail "needs --app docker"; return 1; }
  ensure_ready || return 1
  detect_targets || return 1
  # Positive control: the probe path reaches every target on port 22 (always open), so a later
  # "closed" answer means the firewall, not a broken path.
  reachable 22 || { REASON="control failed: $REASON"; return 1; }
  c5_cleanup

  say "docker: whoami behind the proxy"
  vscript_t 600 "$IPD" <<'EOF' >/dev/null 2>&1 || { fail "cannot start the whoami container"; return 1; }
set -e
docker run -d --name smoke-whoami --network web \
  --label "caddy=whoami.$1.sslip.io" \
  --label 'caddy.reverse_proxy={{upstreams 80}}' traefik/whoami
EOF
  retry 300 5 https_has "https://whoami.$HOST/" '^Hostname:' ||
    { c5_cleanup; fail "https://whoami.$HOST/ does not answer with the whoami reply"; return 1; }
  rm -f "$body"

  say "docker: postgres published on 5432"
  vscript_t 600 <<'EOF' >/dev/null 2>&1 || { fail "cannot start the postgres container"; return 1; }
set -e
docker run -d --name smoke-pg -e POSTGRES_PASSWORD=x -p 5432:5432 postgres:16-alpine
EOF
  pg_wait || { c5_cleanup; fail "postgres did not become ready"; return 1; }

  c5_body || rc=1
  if [ "$rc" -eq 0 ] && [ "$HAVE_V6" = yes ] && ! vcmd 'ip6tables -S FORWARD 2>/dev/null | grep -q -- "-j DOCKER-USER"' >/dev/null 2>&1; then
    NOTE="${NOTE:+$NOTE; }ip6tables FORWARD has no DOCKER-USER jump (IPv6 filtered by the host firewall only)"
  fi
  c5_cleanup
  [ "$rc" -eq 0 ] || return 1
  return 0
}

check_6_resume() {
  local out sum_before sum_after env_file killed_status
  env_file="/opt/vps-apps-data/$APP/.env"
  r="$(vcmd '. /etc/os-release; echo "$ID $VERSION_ID"' 2>&1)" || { fail "cannot ssh to root@$IP: $r"; return 1; }
  vcmd 'test ! -e /etc/vps-apps' >/dev/null 2>&1 || { fail "/etc/vps-apps already exists: this is not a fresh VPS, reinstall the OS first"; return 1; }
  deploy_recipe || return 1
  say "resume: waiting for app_up_setup, then killing the install"
  out="$(vscript_t 2500 "$env_file" <<'EOF'
marker=/var/lib/vps-apps/steps/app_up_setup.done
end=$((SECONDS + 2400))
until [ -f "$marker" ]; do
  [ "$SECONDS" -lt "$end" ] && sleep 0.2 || { echo "TIMEOUT||"; exit 1; }
done
systemctl kill --signal=SIGKILL vps-apps-install.service || true
sleep 1
st="$(cat /var/lib/vps-apps/public/.well-known/rarecloud-app-status 2>/dev/null || true)"
sum="$(sha256sum "$1" | cut -d' ' -f1)"
echo "KILLED|$sum|$st"
EOF
  )" || { fail "could not kill the install after app_up_setup: $out"; return 1; }
  out="$(printf '%s' "$out" | tr -d '\r\n')"
  case "$out" in KILLED\|*\|*) ;; *) fail "unexpected kill output: $out"; return 1 ;; esac
  IFS='|' read -r _ sum_before killed_status <<<"$out"
  [[ "$sum_before" =~ ^[0-9a-f]{64}$ ]] || { fail "no .env checksum before the kill: $out"; return 1; }
  [ "$killed_status" != ready ] || { fail "the install was already ready when it was killed"; return 1; }
  say "resume: killed (status '$killed_status'); the timer must resume it within a minute"
  SAW_INSTALLING=no
  wait_ready || return 1
  sum_after="$(vcmd "sha256sum $env_file | cut -d' ' -f1" | tr -d '\r\n')"
  [ "$sum_before" = "$sum_after" ] || { fail ".env checksum changed across the resume ($sum_before -> $sum_after)"; return 1; }
  vcmd 'grep -q "step app_up_setup: already done, skipping" /var/log/vps-apps-install.log' >/dev/null 2>&1 ||
    { fail "the install log does not show app_up_setup skipped on the resumed attempt"; return 1; }
  vcmd '[ "$(cat /var/lib/vps-apps/attempts)" -ge 2 ]' >/dev/null 2>&1 || { fail "the timer made fewer than two attempts"; return 1; }
}

check_7_domain() {
  local domain="app.$HOST" body="$TMP/domain.body" r out rc=0
  ensure_ready || return 1
  say "rc domain add $domain"
  if [ "$APP" = docker ]; then
    # Designed refusal: a Docker server takes no extra domain through rc; the landing page shows the
    # caddy labels to use on your own container instead.
    out="$(vcmd_t 900 "rc domain add $domain" 2>&1)" || rc=$?
    [ "$rc" -eq 1 ] || { fail "rc domain add exited $rc, expected the refusal (exit 1): $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"; return 1; }
    grep -q 'caddy labels' <<<"$out" || { fail "rc domain add did not print the caddy labels message: $out"; return 1; }
    vcmd 'test ! -e /etc/vps-apps/domains' >/dev/null 2>&1 || { fail "/etc/vps-apps/domains was created although rc refused"; return 1; }
    retry 120 5 https_has "https://$HOST/" 'Your Docker server is ready' ||
      { fail "the primary name https://$HOST/ stopped serving the landing page"; return 1; }
    NOTE="refusal as designed"
    return 0
  fi
  if [ "$APP" = wordpress ]; then
    # Designed refusal: WordPress keeps one address, since its links are stored in its database.
    out="$(vcmd_t 900 "rc domain add $domain" 2>&1)" || rc=$?
    [ "$rc" -eq 1 ] || { fail "rc domain add exited $rc, expected the refusal (exit 1): $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ')"; return 1; }
    grep -q 'serves one address' <<<"$out" || { fail "rc domain add did not say WordPress serves one address: $out"; return 1; }
    vcmd 'test ! -e /etc/vps-apps/domains' >/dev/null 2>&1 || { fail "/etc/vps-apps/domains was created although rc refused"; return 1; }
    retry 120 5 app_health_ok "$HOST" || { fail "the primary name https://$HOST/ stopped serving WordPress"; return 1; }
    NOTE="refusal as designed"
    return 0
  fi
  if [ "$APP" != n8n ]; then
    check_7_app_domain "$domain"
    return
  fi
  vcmd_t 900 "rc domain add $domain" >&2 2>&1 || { fail "rc domain add $domain failed"; return 1; }
  vcmd "grep -qxF $domain /etc/vps-apps/domains" >/dev/null 2>&1 || { fail "$domain is not in /etc/vps-apps/domains"; return 1; }
  {
    retry 300 5 https_has "https://$domain/healthz/readiness" '"status":"ok"' ||
      { fail "https://$domain/healthz/readiness does not answer"; return 1; }
    r="$(vscript "$HOST" "$domain" <<'EOF'
envf=/opt/vps-apps-data/n8n/.env
grep -qxF "WEBHOOK_URL=https://$2/" "$envf" || { echo "env WEBHOOK_URL"; exit 1; }
grep -qxF "N8N_EDITOR_BASE_URL=https://$2" "$envf" || { echo "env N8N_EDITOR_BASE_URL"; exit 1; }
grep -qxF "N8N_HOST=$2" "$envf" || { echo "env N8N_HOST"; exit 1; }
grep -qxF "VA_SITE_ADDRS=\"$1 $2\"" "$envf" || { echo "env VA_SITE_ADDRS"; exit 1; }
n=0
for c in $(docker ps -q); do
  s="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$c")"
  case "$s" in
    n8n | n8n-worker)
      n=$((n+1))
      e="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c")"
      printf '%s\n' "$e" | grep -qxF "WEBHOOK_URL=https://$2/" || { echo "container $s WEBHOOK_URL"; exit 1; }
      printf '%s\n' "$e" | grep -qxF "N8N_EDITOR_BASE_URL=https://$2" || { echo "container $s N8N_EDITOR_BASE_URL"; exit 1; }
      printf '%s\n' "$e" | grep -qxF "N8N_HOST=$2" || { echo "container $s N8N_HOST"; exit 1; }
      ;;
  esac
done
[ "$n" -ge 1 ] || { echo "no n8n container"; exit 1; }
echo ok
EOF
    )" || { fail "the n8n URL variables do not follow: $r"; return 1; }
  }
  [ "$(http_code "https://$HOST/")" = 200 ] || { fail "the primary name https://$HOST/ stopped answering"; return 1; }
  rm -f "$body"
}

# check_7_app_domain <domain>: check 7 for Nextcloud, Forgejo, Uptime Kuma, Grafana and the runner
# apps. The new name serves the app (a runner app's page behind the same login), the .env and the
# recreated container's caddy label list both names (Grafana's Loki container too), the app's own
# settings follow the newest name (Forgejo's URL variables, Grafana's root URL, Nextcloud's
# overwrite.cli.url and trusted_domains), and the server's own name keeps serving.
check_7_app_domain() {
  local domain="$1" r
  vcmd_t 900 "rc domain add $domain" >&2 2>&1 || { fail "rc domain add $domain failed"; return 1; }
  vcmd "grep -qxF $domain /etc/vps-apps/domains" >/dev/null 2>&1 || { fail "$domain is not in /etc/vps-apps/domains"; return 1; }
  retry 300 5 app_health_ok "$domain" || { fail "https://$domain$(app_health_path) does not answer as a running $APP"; return 1; }
  if is_runner_app && ! runner_gate_closed "$domain"; then
    fail "https://$domain/ answers without asking for the page login"
    return 1
  fi
  r="$(vscript "$APP" "$HOST" "$domain" <<'EOF'
envf="/opt/vps-apps-data/$1/.env"
case "$1" in
  uptimekuma) svc=uptime-kuma ;;
  ghrunner | glrunner) svc=page ;;
  *) svc="$1" ;;
esac
grep -qxF "VA_SITE_ADDRS=\"$2 $3\"" "$envf" || { echo "env VA_SITE_ADDRS"; exit 1; }
c="$(docker ps -q --filter "label=com.docker.compose.project=vps-apps-$1" --filter "label=com.docker.compose.service=$svc" | head -n 1)"
[ -n "$c" ] || { echo "no $svc container"; exit 1; }
[ "$(docker inspect -f '{{index .Config.Labels "caddy"}}' "$c")" = "$2 $3" ] || { echo "container caddy label"; exit 1; }
case "$1" in
  forgejo)
    grep -qxF "FORGEJO_DOMAIN=$3" "$envf" || { echo "env FORGEJO_DOMAIN"; exit 1; }
    grep -qxF "FORGEJO_ROOT_URL=https://$3/" "$envf" || { echo "env FORGEJO_ROOT_URL"; exit 1; }
    e="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c")"
    printf '%s\n' "$e" | grep -qxF "FORGEJO__server__ROOT_URL=https://$3/" || { echo "container ROOT_URL"; exit 1; }
    printf '%s\n' "$e" | grep -qxF "FORGEJO__server__DOMAIN=$3" || { echo "container DOMAIN"; exit 1; }
    ;;
  grafana)
    grep -qxF "GRAFANA_ROOT_URL=https://$3/" "$envf" || { echo "env GRAFANA_ROOT_URL"; exit 1; }
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | grep -qxF "GF_SERVER_ROOT_URL=https://$3/" ||
      { echo "container GF_SERVER_ROOT_URL"; exit 1; }
    l="$(docker ps -q --filter label=com.docker.compose.project=vps-apps-grafana --filter label=com.docker.compose.service=loki | head -n 1)"
    [ "$(docker inspect -f '{{index .Config.Labels "caddy"}}' "$l")" = "$2 $3" ] || { echo "loki caddy label"; exit 1; }
    ;;
  nextcloud)
    occ() { docker exec -u www-data "$c" php occ --no-interaction "$@" </dev/null; }
    [ "$(occ config:system:get overwrite.cli.url)" = "https://$3" ] || { echo "overwrite.cli.url"; exit 1; }
    t="$(occ config:system:get trusted_domains)"
    printf '%s\n' "$t" | grep -qxF "$2" || { echo "trusted_domains without $2"; exit 1; }
    printf '%s\n' "$t" | grep -qxF "$3" || { echo "trusted_domains without $3"; exit 1; }
    ;;
esac
echo ok
EOF
  )" || { fail "the $APP settings do not follow the new name: $r"; return 1; }
  retry 120 5 app_health_ok "$HOST" || { fail "the primary name https://$HOST$(app_health_path) stopped answering"; return 1; }
}

check_8_hub64() {
  local out
  ensure_ready || return 1
  out="$(vscript <<'EOF'
prefix="$(ip -6 route show 2>/dev/null | awk '$1 ~ /\/64$/ && $1 !~ /^fe80/ { print $1; exit }')"
addr="$(ip -6 -o addr show scope global 2>/dev/null | awk '!/deprecated|temporary/ { print $4; exit }')"
echo "v6-prefix=${prefix:-none} v6-addr=${addr:-none}"
EOF
  )" || { fail "cannot read the IPv6 facts over ssh"; return 1; }
  # The pull count and the Hub headers were taken at ready, before any restart or reboot.
  NOTE="$(printf '%s' "$out" | tr -d '\r\n') ${FACTS:-unreliable: not captured in this run}"
}

check_9_timer() {
  local age wait out
  ensure_ready || return 1
  age="$(vcmd 'echo $(( $(date +%s) - $(stat -c %Y /var/lib/vps-apps/public/.well-known/rarecloud-app-status) ))' | tr -d '\r\n')"
  [[ "$age" =~ ^[0-9]+$ ]] || { fail "cannot read the age of the status file"; return 1; }
  if [ "$age" -lt 185 ]; then
    wait=$((185 - age))
    say "timer: waiting $wait s so that ready is three minutes old"
    sleep "$wait"
  fi
  [ "$(status_now)" = ready ] || { fail "the status is not ready three minutes after ready"; return 1; }
  out="$(vcmd 'systemctl is-active vps-apps-install.timer || true' | tr -d '\r\n')"
  [ "$out" = inactive ] || { fail "vps-apps-install.timer is '$out', not inactive"; return 1; }
  out="$(vcmd 'systemctl is-enabled vps-apps-install.timer || true' | tr -d '\r\n')"
  [ "$out" = disabled ] || { fail "vps-apps-install.timer is '$out', not disabled"; return 1; }
  vcmd 'test ! -e /etc/vps-apps/password' >/dev/null 2>&1 || { fail "/etc/vps-apps/password still exists"; return 1; }
}

check_10_docker_info() {
  local out info jump chain
  ensure_ready || return 1
  vcmd 'grep -q "\"firewall-backend\": \"iptables\"" /etc/docker/daemon.json' >/dev/null 2>&1 ||
    { fail "/etc/docker/daemon.json has no firewall-backend iptables"; return 1; }
  vcmd 'systemctl is-active docker' >/dev/null 2>&1 || { fail "the docker service is not active"; return 1; }
  info="$(vcmd 'docker info 2>&1' | tr -d '\r')" || { fail "docker info fails with the daemon.json in place"; return 1; }
  [ -n "$info" ] || { fail "docker info printed nothing"; return 1; }
  out="$(printf '%s\n' "$info" | grep -i 'firewall' || true)"
  chain=no
  jump=no
  vcmd 'iptables -S DOCKER >/dev/null 2>&1 && iptables -S DOCKER-USER >/dev/null 2>&1' >/dev/null 2>&1 && chain=yes
  vcmd 'iptables -S FORWARD | grep -q -- "-j DOCKER-USER"' >/dev/null 2>&1 && jump=yes
  if [ -n "$out" ]; then
    grep -qi iptables <<<"$out" || { fail "docker info reports a different firewall backend: $out"; return 1; }
  elif [ "$chain" = yes ] && [ "$jump" = yes ]; then
    NOTE="docker info has no firewall line; iptables chains DOCKER and DOCKER-USER exist and FORWARD jumps to DOCKER-USER"
  else
    fail "no positive sign of the iptables backend: docker info has no firewall line, DOCKER/DOCKER-USER chains=$chain, FORWARD jump=$jump"
    return 1
  fi
  out="$(vscript <<'EOF'
echo "lines=$(journalctl -u docker -b --no-pager 2>/dev/null | wc -l)"
echo "errors=$(journalctl -u docker -b --no-pager 2>/dev/null | grep -ciE 'unknown (field|option)|failed to start daemon|unable to configure the Docker daemon' || true)"
EOF
  )" || { fail "cannot read the docker journal"; return 1; }
  out="$(printf '%s' "$out" | tr -d '\r')"
  [ "$(printf '%s\n' "$out" | sed -n 's/^lines=//p')" -ge 1 ] 2>/dev/null || { fail "the docker journal is empty, so it proves nothing"; return 1; }
  [ "$(printf '%s\n' "$out" | sed -n 's/^errors=//p')" = 0 ] || { fail "the docker journal reports a configuration error"; return 1; }
  return 0
}

check_11_nft_reboot() {
  local out lines cycles
  ensure_ready || return 1
  vcmd 'nft -c -f /etc/vps-apps/vps-apps.nft' >/dev/null 2>&1 || { fail "nft -c -f /etc/vps-apps/vps-apps.nft fails"; return 1; }
  reboot_vps || { [ -n "$REASON" ] || REASON="the VPS did not come back after the reboot"; return 1; }
  # Positive control first: the boot journal must hold lines, or "no ordering cycle" proves nothing.
  out="$(vscript <<'EOF'
echo "lines=$(journalctl -b --no-pager 2>/dev/null | wc -l)"
echo "cycles=$(journalctl -b --no-pager 2>/dev/null | grep -ci 'ordering cycle' || true)"
EOF
  )" || { fail "cannot read the boot journal after the reboot"; return 1; }
  out="$(printf '%s' "$out" | tr -d '\r')"
  lines="$(printf '%s\n' "$out" | sed -n 's/^lines=//p')"
  cycles="$(printf '%s\n' "$out" | sed -n 's/^cycles=//p')"
  { [[ "$lines" =~ ^[0-9]+$ ]] && [ "$lines" -ge 50 ]; } || { fail "the boot journal has only '$lines' lines, so it proves nothing"; return 1; }
  [ "$cycles" = 0 ] || { fail "$cycles ordering cycle line(s) in the boot journal"; return 1; }
  retry 120 3 vcmd 'systemctl is-active vps-apps-nft docker >/dev/null' >/dev/null 2>&1 ||
    { fail "vps-apps-nft or docker is not active after reboot"; return 1; }
  retry 120 3 vcmd 'nft list table inet vps_apps >/dev/null' >/dev/null 2>&1 ||
    { fail "table inet vps_apps is not loaded after reboot"; return 1; }
  retry 120 3 vcmd 'iptables -S DOCKER-USER | grep -q -- "-j DROP"' >/dev/null 2>&1 ||
    { fail "DOCKER-USER has no drop rule after reboot"; return 1; }
  retry 300 5 bash -c '[ "$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "http://$1/.well-known/rarecloud-app-status")" = 200 ]' _ "$IP" ||
    { fail "the public status does not answer after reboot"; return 1; }
  [ "$(status_now)" = ready ] || { fail "the status is not ready after reboot"; return 1; }
}

check_12_rc_port() {
  local out
  ensure_ready || return 1
  out="$(vscript <<'EOF' 2>&1
set -e
inspect() { # <iptables|ip6tables> <label>
  rules="$($1 -S DOCKER-USER)"
  [ -n "$rules" ] || { echo "$2: DOCKER-USER is empty or missing"; exit 1; }
  if printf '%s\n' "$rules" | grep -q -- '--ctorigdstport 5432 '; then echo "$2: stale 5432 rule"; rc port close 6000 >/dev/null; exit 1; fi
  n="$(printf '%s\n' "$rules" | grep -c -- '--ctorigdstport 6000 ' || true)"
  if [ "$n" -ne 1 ]; then echo "$2: port 6000 has $n rules"; rc port close 6000 >/dev/null; exit 1; fi
  d="$(printf '%s\n' "$rules" | sort | uniq -d)"
  if [ -n "$d" ]; then echo "$2: duplicate rules: $d"; rc port close 6000 >/dev/null; exit 1; fi
}
rc port open 5432 >/dev/null
rc port open 6000 >/dev/null
rc port close 5432 >/dev/null
inspect iptables v4
v6=no
if [ -e /etc/vps-apps/docker-user.v6 ]; then inspect ip6tables v6; v6=yes; fi
if grep -qx '5432/tcp' /etc/vps-apps/open-ports; then echo "5432/tcp still in open-ports"; rc port close 6000 >/dev/null; exit 1; fi
rc port close 6000 >/dev/null
for t in iptables ip6tables; do
  [ "$t" = ip6tables ] && [ "$v6" = no ] && continue
  if $t -S DOCKER-USER | grep -q -- '--ctorigdstport 6000 '; then echo "$t: stale 6000 rule after close"; exit 1; fi
done
echo "ok v6=$v6"
EOF
  )" || { fail "$(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; return 1; }
  case "$out" in *"ok v6="*) ;; *) fail "unexpected output: $out"; return 1 ;; esac
  NOTE="$(printf '%s' "$out" | tail -n 1 | tr -d '\r')"
}

check_13_ssh() {
  local fp keys expect actual out
  ensure_ready || return 1
  fp="$("$KEYGEN_BIN" -y -f "$(winpath "$SSH_KEY")" 2>/dev/null >"$TMP/key.pub" && "$KEYGEN_BIN" -lf "$(winpath "$TMP/key.pub")" 2>/dev/null | awk '{print $2}')" || fp=""
  rm -f "$TMP/key.pub"
  out="$(vscript <<'EOF'
echo "port22=$(ss -H -ltn 'sport = :22' | wc -l)"
echo "pwauth=$(sshd -T | awk '$1 == "passwordauthentication" { print $2 }')"
echo "rootlogin=$(sshd -T | awk '$1 == "permitrootlogin" { print $2 }')"
echo "dropin=$([ -f /etc/ssh/sshd_config.d/10-vps-apps.conf ] && echo yes || echo no)"
echo "keys=$(grep -cE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-[a-z0-9@.-]+) ' /root/.ssh/authorized_keys 2>/dev/null || true)"
echo "fps=$(ssh-keygen -lf /root/.ssh/authorized_keys 2>/dev/null | awk '{print $2}' | tr '\n' ',')"
EOF
  )" || { fail "cannot read the ssh facts"; return 1; }
  out="$(printf '%s' "$out" | tr -d '\r')"
  getv() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -n 1; }
  [ "$(getv port22)" -ge 1 ] 2>/dev/null || { fail "nothing listens on port 22"; return 1; }
  [ "$(getv dropin)" = yes ] || { fail "/etc/ssh/sshd_config.d/10-vps-apps.conf is missing"; return 1; }
  keys="$(getv keys)"
  { [ -n "$fp" ] && [[ "$(getv fps)" == *"$fp"* ]]; } || { fail "the test key is no longer in /root/.ssh/authorized_keys"; return 1; }
  if [ "$EXPECT_PW" = auto ]; then
    if [ "${keys:-0}" -ge 1 ]; then expect=no; else expect=yes; fi
  else
    expect="$EXPECT_PW"
  fi
  actual="$(getv pwauth)"
  [ "$actual" = "$expect" ] || { fail "sshd passwordauthentication is '$actual', expected '$expect' (usable keys: ${keys:-0})"; return 1; }
  if [ "$expect" = no ] && [ "$(getv rootlogin)" != prohibit-password ] && [ "$(getv rootlogin)" != without-password ]; then
    fail "permitrootlogin is '$(getv rootlogin)', expected prohibit-password (or its alias without-password) with a key installed"
    return 1
  fi
  NOTE="pwauth=$actual rootlogin=$(getv rootlogin) keys=${keys:-0}"
}

# --- the apps with an admin login: nextcloud, forgejo, wordpress, uptimekuma ------------------

# nc_propfind <password file>: the HTTP status of a WebDAV PROPFIND on the admin's files as admin,
# retried for up to a minute while nothing or a 5xx answers; 000 when nothing answered.
nc_propfind() {
  local deadline=$((SECONDS + 60)) code
  while :; do
    code="$(curl_cred admin "$1" -sS -o /dev/null -w '%{http_code}' --max-time 30 -X PROPFIND -H 'Depth: 0' \
      "https://$HOST/remote.php/dav/files/admin/" 2>/dev/null)" || code=000
    case "$code" in
      000 | 5??) ;;
      *) break ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 5
  done
  printf '%s' "${code:-000}"
}

check_14_nextcloud() {
  local pwf="$TMP/app.pw" bad="$TMP/bad.pw" code
  [ "$APP" = nextcloud ] || { fail "needs --app nextcloud"; return 1; }
  ensure_ready || return 1
  app_pw_file "$pwf"
  say "nextcloud: WebDAV PROPFIND as admin"
  code="$(nc_propfind "$pwf")"
  rm -f "$pwf"
  [ "$code" = 207 ] || { fail "PROPFIND /remote.php/dav/files/admin/ as admin answered HTTP $code, expected 207"; return 1; }
  say "nextcloud: a wrong password is refused"
  printf 'wrong-%s' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')" >"$bad"
  code="$(nc_propfind "$bad")"
  rm -f "$bad"
  [ "$code" = 401 ] || { fail "PROPFIND with a wrong password answered HTTP $code, expected 401"; return 1; }
}

check_15_forgejo() {
  local pwf="$TMP/app.pw" code out
  [ "$APP" = forgejo ] || { fail "needs --app forgejo"; return 1; }
  ensure_ready || return 1
  app_pw_file "$pwf"
  say "forgejo: API login as gitadmin"
  : >"$BODY"
  code="$(curl_cred gitadmin "$pwf" -sS -o "$(winpath "$BODY")" -w '%{http_code}' --max-time 30 \
    "https://$HOST/api/v1/user" 2>/dev/null)" || code=000
  rm -f "$pwf"
  [ "$code" = 200 ] || { fail "GET /api/v1/user as gitadmin answered HTTP $code"; return 1; }
  jq -e '.login == "gitadmin" and .is_admin == true' "$BODY" >/dev/null 2>&1 ||
    { fail "GET /api/v1/user is not the site admin gitadmin: $(head -c 200 "$BODY")"; return 1; }
  say "forgejo: sign-up is closed"
  out="$(curl_t -fsS --max-time 30 -H 'Accept-Language: en-US' "https://$HOST/user/sign_up" 2>/dev/null)" || out=""
  grep -q 'Registration is disabled' <<<"$out" || { fail "/user/sign_up does not say Registration is disabled"; return 1; }
  say "forgejo: git over SSH answers on port 2222"
  out="$(timeout 60 "$KEYSCAN_BIN" -T 10 -p 2222 "$HOST" 2>/dev/null | tr -d '\r')" || out=""
  grep -qE ' (ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) AAAA' <<<"$out" ||
    { fail "ssh-keyscan -p 2222 $HOST returned no host key"; return 1; }
}

check_16_wordpress() {
  local pwf="$TMP/app.pw" hdrs="$TMP/wp.headers" out path
  [ "$APP" = wordpress ] || { fail "needs --app wordpress"; return 1; }
  ensure_ready || return 1
  app_pw_file "$pwf"
  say "wordpress: log in through wp-login.php as admin"
  : >"$hdrs"
  out="$(curl_t -sS --max-time 30 -o /dev/null -D "$(winpath "$hdrs")" -w '%{http_code} %{redirect_url}' \
    -b 'wordpress_test_cookie=WP%20Cookie%20check' --data-urlencode 'log=admin' \
    --data-urlencode "pwd@$(winpath "$pwf")" --data-urlencode 'testcookie=1' \
    "https://$HOST/wp-login.php" 2>/dev/null)" || out=""
  rm -f "$pwf"
  [ "$out" = "302 https://$HOST/wp-admin/" ] ||
    { fail "POST /wp-login.php as admin answered '$out', expected a 302 to https://$HOST/wp-admin/"; return 1; }
  grep -qi '^set-cookie: wordpress_logged_in_' "$hdrs" || { fail "the login set no wordpress_logged_in_ cookie"; return 1; }
  rm -f "$hdrs"
  say "wordpress: the installer is closed"
  out="$(curl_t -sS --max-time 30 "https://$HOST/wp-admin/install.php" 2>/dev/null)" || out=""
  grep -q 'Already Installed' <<<"$out" || { fail "/wp-admin/install.php does not say Already Installed"; return 1; }
  say "wordpress: registration is off"
  out="$(curl_t -sS --max-time 30 -o /dev/null -w '%{http_code} %{redirect_url}' \
    "https://$HOST/wp-login.php?action=register" 2>/dev/null)" || out=""
  [[ "$out" == 30[0-9]" "*"registration=disabled"* ]] ||
    { fail "/wp-login.php?action=register answered '$out', expected a redirect to registration=disabled"; return 1; }
  # WordPress itself would answer an XML-RPC call with 200; the proxy refuses the path and below it.
  say "wordpress: xmlrpc.php is refused with 403"
  for path in /xmlrpc.php /xmlrpc.php/x; do
    out="$(curl_t -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST -H 'Content-Type: text/xml' \
      --data '<?xml version="1.0"?><methodCall><methodName>system.listMethods</methodName></methodCall>' \
      "https://$HOST$path" 2>/dev/null)" || out=""
    [ "$out" = 403 ] || { fail "POST $path answered HTTP '$out', expected 403"; return 1; }
  done
}

# uk_cmd <mode>: the remote command that runs apps/uptimekuma/admin.js <mode> https://<host> with the
# app container's own node, the way the installer does, so the call goes out through the proxy.
uk_cmd() {
  printf '%s' 'UK=/opt/vps-apps/current/apps/uptimekuma; docker compose -f "$UK/compose.yml" -f "$UK/compose.expose.yml"'
  printf '%s' ' --env-file /opt/vps-apps-data/uptimekuma/.env exec -T uptime-kuma node -e "$(cat "$UK/admin.js")"'
  printf ' %s https://%s' "$1" "$HOST"
}

check_17_uptimekuma() {
  local pwf="$TMP/app.pw" out rc=0
  [ "$APP" = uptimekuma ] || { fail "needs --app uptimekuma"; return 1; }
  ensure_ready || return 1
  say "uptimekuma: the first-run setup is no longer offered"
  out="$(vcmd_t 180 "$(uk_cmd need-setup)" 2>/dev/null | tr -d '\r\n')" || out=""
  [ "$out" = false ] || { fail "admin.js need-setup over https://$HOST printed '$out', expected false"; return 1; }
  app_pw_file "$pwf"
  say "uptimekuma: admin logs in with the password"
  timeout 180 "$SSH_BIN" "${SSH_OPTS[@]}" "root@$IP" "$(uk_cmd login)" <"$pwf" >/dev/null 2>&1 || rc=$?
  rm -f "$pwf"
  [ "$rc" -eq 0 ] || { fail "admin.js login over https://$HOST exited $rc"; return 1; }
}

# --- grafana ------------------------------------------------------------------------------------

# gf_get <user> <password file> <path> [curl args...]: GET https://<host><path> with a basic login
# from a curl config on stdin, the body in BODY; prints the HTTP status, 000 when nothing answered.
gf_get() {
  local user="$1" pwf="$2" path="$3" code
  shift 3
  : >"$BODY"
  code="$(curl_cred "$user" "$pwf" -sS -o "$(winpath "$BODY")" -w '%{http_code}' --max-time 30 "$@" \
    "https://$HOST$path" 2>/dev/null)" || code=000
  printf '%s' "${code:-000}"
}

# gf_prom_one <query>: the Prometheus data source, through Grafana as admin, answers 1 for <query>.
gf_prom_one() {
  [ "$(gf_get admin "$GF_PW" /api/datasources/proxy/uid/vps-apps-prometheus/api/v1/query -G \
    --data-urlencode "query=$1")" = 200 ] && jq -e '.data.result[0].value[1] == "1"' "$BODY" >/dev/null 2>&1
}

# gf_line_back: the line check 18 pushed is in Loki, read through Grafana's Loki data source.
gf_line_back() {
  [ "$(gf_get admin "$GF_PW" /api/datasources/proxy/uid/vps-apps-loki/loki/api/v1/query_range -G \
    --data-urlencode 'query={job="vps-smoke"}' --data-urlencode 'limit=100')" = 200 ] &&
    jq -e --arg l "$GF_LINE" '[.data.result[].values[][1]] | index($l) != null' "$BODY" >/dev/null 2>&1
}

# gf_push <password file or "-"> : POST one line to the push path, as loki with that password ("-":
# no credential); prints the HTTP status.
gf_push() {
  local body
  body="{\"streams\":[{\"stream\":{\"job\":\"vps-smoke\"},\"values\":[[\"$(date +%s)000000000\",\"$GF_LINE\"]]}]}"
  if [ "$1" = - ]; then
    curl_t -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST -H 'Content-Type: application/json' \
      --data "$body" "https://$HOST/loki/api/v1/push" 2>/dev/null || true
  else
    curl_cred loki "$1" -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST \
      -H 'Content-Type: application/json' --data "$body" "https://$HOST/loki/api/v1/push" 2>/dev/null || true
  fi
}

check_18_grafana() {
  local lk="$TMP/loki.pw" bad="$TMP/bad.pw" code out uid path iface p a
  GF_PW="$TMP/app.pw"
  [ "$APP" = grafana ] || { fail "needs --app grafana"; return 1; }
  ensure_ready || return 1
  say "grafana: the login page answers over HTTPS"
  out="$(curl_t -fsS --max-time 30 "https://$HOST/login" 2>/dev/null)" || out=""
  grep -q 'grafanaBootData' <<<"$out" || { fail "https://$HOST/login is not Grafana's login page"; return 1; }
  # One login only: Grafana locks a user for 5 minutes after 5 failed logins, and app_expose spent one.
  say "grafana: API login as admin"
  app_pw_file "$GF_PW"
  code="$(gf_get admin "$GF_PW" /api/user)"
  { [ "$code" = 200 ] && jq -e '.login == "admin" and .isGrafanaAdmin == true' "$BODY" >/dev/null 2>&1; } ||
    { fail "GET /api/user as admin answered HTTP $code: $(head -c 200 "$BODY")"; return 1; }
  say "grafana: sign-up is disabled and nothing answers without a login"
  : >"$BODY"
  code="$(curl_t -sS -o "$(winpath "$BODY")" -w '%{http_code}' --max-time 30 -X POST -H 'Content-Type: application/json' \
    --data '{"email":"vps-smoke-check"}' "https://$HOST/api/user/signup" 2>/dev/null)" || code=000
  { [ "$code" = 401 ] && jq -e '.message == "User signup is disabled"' "$BODY" >/dev/null 2>&1; } ||
    { fail "POST /api/user/signup answered HTTP $code: $(head -c 200 "$BODY")"; return 1; }
  [ "$(http_code "https://$HOST/api/org/")" = 401 ] || { fail "GET /api/org/ without a login is not 401"; return 1; }
  say "grafana: the Prometheus and Loki data sources are healthy"
  for uid in vps-apps-prometheus vps-apps-loki; do
    code="$(gf_get admin "$GF_PW" "/api/datasources/uid/$uid/health")"
    { [ "$code" = 200 ] && jq -e '.status == "OK"' "$BODY" >/dev/null 2>&1; } ||
      { fail "the $uid data source health answered HTTP $code: $(head -c 200 "$BODY")"; return 1; }
  done
  say "grafana: node-exporter's metrics reach Prometheus, with the VPS's own interface"
  retry 180 10 gf_prom_one 'up{job="node"}' || { fail 'up{job="node"} is not 1 in Prometheus'; return 1; }
  # shellcheck disable=SC2016 # awk runs on the VPS
  iface="$(vcmd 'ip -4 route show default | awk '\''{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'\''' 2>/dev/null | tr -d '\r\n')"
  [ -n "$iface" ] || { fail "cannot read the VPS's default interface"; return 1; }
  retry 60 10 gf_prom_one "count(node_network_receive_bytes_total{job=\"node\",device=\"$iface\"})" ||
    { fail "node-exporter has no traffic counter for $iface: it does not see the host's network"; return 1; }
  say "grafana: the Loki push path takes only its credential"
  vcmd 'sed -n "s/^Loki push password: //p" /root/vps-apps-credentials.txt | head -n 1' 2>/dev/null | tr -d '\r\n' >"$lk"
  [ -s "$lk" ] || { fail "no Loki push password in /root/vps-apps-credentials.txt"; return 1; }
  GF_LINE="vps-smoke $(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
  printf 'wrong-%s' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')" >"$bad"
  code="$(gf_push -)"
  [ "$code" = 401 ] || { fail "a push without the credential answered HTTP $code, expected 401"; return 1; }
  code="$(gf_push "$bad")"
  [ "$code" = 401 ] || { fail "a push with a wrong password answered HTTP $code, expected 401"; return 1; }
  code="$(gf_push "$lk")"
  [ "$code" = 204 ] || { fail "a push with the generated credential answered HTTP $code, expected 204"; return 1; }
  retry 60 5 gf_line_back || { fail "the pushed line does not come back through Grafana's Loki data source"; return 1; }
  say "grafana: Loki's query API is not public, not even with the push credential"
  for path in /loki/api/v1/labels '/loki/api/v1/query_range?query=%7Bjob%3D%22vps-smoke%22%7D' \
    /loki/api/v1/push/../labels /loki/api/v1/tail /ready /metrics; do
    for p in - "$lk"; do
      if [ "$p" = - ]; then
        : >"$BODY"
        code="$(curl_t -sS -o "$(winpath "$BODY")" -w '%{http_code}' --max-time 30 "https://$HOST$path" 2>/dev/null)" || code=000
      else
        code="$(gf_get loki "$p" "$path")"
      fi
      if [ "$code" = 200 ] || grep -qF -e "$GF_LINE" -e '"status":"success"' "$BODY"; then
        fail "GET $path answered HTTP $code with Loki's data"
        return 1
      fi
    done
  done
  rm -f "$lk" "$bad" "$GF_PW"
  say "grafana: Grafana, Loki and Prometheus are not reachable from outside, and listen on loopback only"
  for p in 3000 3100 9090 9091 9100; do
    if tcp_open "$IP" "$p"; then
      fail "port $p answers from outside"
      return 1
    fi
  done
  out="$(vcmd "ss -ltnH '( sport = :3000 or sport = :3100 or sport = :9090 or sport = :9091 or sport = :9100 )' | awk '{print \$4}'" 2>/dev/null | tr -d '\r')"
  for a in $out; do
    case "$a" in 127.0.0.1:*) ;; *) fail "$a listens beyond loopback"; return 1 ;; esac
  done
}

# --- ghrunner and glrunner -----------------------------------------------------------------------

# check_runner <app>: check 19 (ghrunner) or 20 (glrunner). The page asks for its login and refuses a
# wrong password; the login opens it, with the status and one form carrying a CSRF value. A form
# without that value, or from another origin, is refused, and so is a personal access token, and
# none of them queues a request. On the server: the register path unit watching the inbox, the
# inbox the page user's and the work directory root's on a tmpfs, the page container read-only, as
# the page user, without the Docker socket and without a published port; for ghrunner the runner
# installed (2.x) and its unit enabled only once registered, for glrunner the gitlab-runner
# container running without a published port. With E2E_RUNNER_URL and E2E_RUNNER_TOKEN_FILE, it
# then registers from the page and waits for the page to show the runner registered, with the
# token in no line of the register unit's journal.
check_runner() {
  local app="$1" title addr bad="$TMP/runner-bad.pw" tok="$TMP/runner.token" code csrf r leak
  [ "$APP" = "$app" ] || { fail "needs --app $app"; return 1; }
  ensure_ready || return 1
  case "$app" in
    ghrunner) title="GitHub Actions runner" addr=https://github.com/octocat/hello-world ;;
    glrunner) title="GitLab Runner" addr=https://gitlab.com ;;
  esac
  say "$app: the page asks for its login, and a wrong password does not open it"
  runner_gate_closed "$HOST" || { fail "https://$HOST/ answers without asking for the page login"; return 1; }
  printf 'wrong-%s' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')" >"$bad"
  code="$(curl_cred admin "$bad" -sS -o /dev/null -w '%{http_code}' --max-time 30 "https://$HOST/" 2>/dev/null)" || code=000
  [ "$code" = 401 ] || { fail "a wrong password answered HTTP $code, expected 401"; return 1; }
  say "$app: the login opens the page, with the status and the form"
  app_pw_file "$RUNNER_PW"
  rm -f "$RUNNER_JAR"
  code="$(runner_get)"
  { [ "$code" = 200 ] && grep -qF "<h1>$title</h1>" "$BODY" && grep -qF '<h2>Status</h2>' "$BODY"; } ||
    { fail "GET / as admin answered HTTP $code without the $title page: $(head -c 200 "$BODY")"; return 1; }
  csrf="$(sed -n 's/.*name="csrf" value="\([A-Za-z0-9_-]*\)".*/\1/p' "$BODY" | head -n 1)"
  [ -n "$csrf" ] || { fail "the page has no CSRF value in its form"; return 1; }
  grep -q 'rc_csrf' "$RUNNER_JAR" || { fail "the page set no CSRF cookie"; return 1; }
  say "$app: forms without the CSRF value, from another origin or with a personal token queue nothing"
  printf 'not-a-token' >"$tok"
  code="$(runner_post "" "https://$HOST" "$addr" "$tok")"
  [ "$code" = 403 ] || { fail "a form without the CSRF value answered HTTP $code, expected 403"; return 1; }
  code="$(runner_post "$csrf" "https://evil.example.com" "$addr" "$tok")"
  [ "$code" = 403 ] || { fail "a form from another origin answered HTTP $code, expected 403"; return 1; }
  case "$app" in
    ghrunner) printf 'ghp_%s' "$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n')" >"$tok" ;;
    glrunner) printf 'glpat-%s' "$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')" >"$tok" ;;
  esac
  code="$(runner_post "$csrf" "https://$HOST" "$addr" "$tok")"
  { [ "$code" = 400 ] && grep -qF 'This is a personal access token' "$BODY"; } ||
    { fail "a personal access token answered HTTP $code: $(head -c 200 "$BODY")"; return 1; }
  if grep -qF -f "$tok" "$BODY"; then
    fail "the page echoed the token it refused"
    return 1
  fi
  rm -f "$tok" "$bad"
  vcmd "test ! -e /run/vps-apps-$app/inbox/request" >/dev/null 2>&1 || { fail "a refused form left a request in the inbox"; return 1; }
  say "$app: the register unit, the inbox and the page container on the server"
  r="$(vscript "$app" <<'EOF'
app="$1"
systemctl is-enabled --quiet "vps-apps-$app-register.path" || { echo "the register path unit is not enabled"; exit 1; }
systemctl is-active --quiet "vps-apps-$app-register.path" || { echo "the register path unit is not active"; exit 1; }
[ "$(stat -f -c %T /run)" = tmpfs ] || { echo "/run is not a tmpfs"; exit 1; }
[ "$(stat -c '%U %a' "/run/vps-apps-$app/inbox")" = "vps-apps-page 700" ] || { echo "inbox owner or mode"; exit 1; }
[ "$(stat -c '%U %a' "/run/vps-apps-$app/work")" = "root 700" ] || { echo "work directory owner or mode"; exit 1; }
c="$(docker ps -q --filter "label=com.docker.compose.project=vps-apps-$app" --filter label=com.docker.compose.service=page | head -n 1)"
[ -n "$c" ] || { echo "no page container"; exit 1; }
[ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$c")" = true ] || { echo "the page's root filesystem is writable"; exit 1; }
[ "$(docker inspect -f '{{.Config.User}}' "$c")" = "$(id -u vps-apps-page):$(id -g vps-apps-page)" ] || { echo "the page does not run as vps-apps-page"; exit 1; }
if docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$c" | grep -q 'docker\.sock'; then
  echo "the page has the Docker socket"
  exit 1
fi
[ -z "$(docker port "$c")" ] || { echo "the page publishes a port"; exit 1; }
case "$app" in
  ghrunner)
    id -nG ghrunner | tr ' ' '\n' | grep -qx docker || { echo "ghrunner is not in the docker group"; exit 1; }
    v="$(HOME=/home/ghrunner setpriv --reuid=ghrunner --regid=ghrunner --init-groups -- \
      /home/ghrunner/actions-runner/bin/Runner.Listener --version </dev/null 2>/dev/null)"
    [[ "$v" =~ ^2\.[0-9]+\.[0-9]+ ]] || { echo "Runner.Listener --version says '$v'"; exit 1; }
    if [ -f /home/ghrunner/actions-runner/.runner ]; then
      systemctl is-active --quiet vps-apps-ghrunner || { echo "the registered runner is not running"; exit 1; }
    elif systemctl is-enabled --quiet vps-apps-ghrunner; then
      echo "the runner's unit is enabled before a registration"
      exit 1
    fi
    ;;
  glrunner)
    g="$(docker ps -q --filter label=com.docker.compose.project=vps-apps-glrunner --filter label=com.docker.compose.service=gitlab-runner | head -n 1)"
    [ -n "$g" ] || { echo "no gitlab-runner container"; exit 1; }
    [ -z "$(docker port "$g")" ] || { echo "gitlab-runner publishes a port"; exit 1; }
    docker exec "$g" gitlab-runner --version </dev/null >/dev/null 2>&1 || { echo "gitlab-runner --version fails"; exit 1; }
    ;;
esac
echo ok
EOF
  )" || { fail "on the server: $r"; return 1; }
  if [ -z "${E2E_RUNNER_URL:-}" ] || [ -z "${E2E_RUNNER_TOKEN_FILE:-}" ]; then
    NOTE="${NOTE:+$NOTE; }registration not exercised: set E2E_RUNNER_URL and E2E_RUNNER_TOKEN_FILE for it"
    return 0
  fi
  say "$app: registering with $E2E_RUNNER_URL from the page"
  tr -d '\r\n' <"$E2E_RUNNER_TOKEN_FILE" >"$tok"
  code="$(runner_post "$csrf" "https://$HOST" "$E2E_RUNNER_URL" "$tok")"
  [ "$code" = 303 ] || { rm -f "$tok"; fail "the form answered HTTP $code: $(head -c 200 "$BODY")"; return 1; }
  if ! retry 600 10 runner_state_settled || ! grep -qF 'class="state-registered"' "$BODY"; then
    rm -f "$tok"
    fail "the page does not show the runner registered: $(sed -n 's/.*<h2>Status<\/h2><p>\([^<]*\)<.*/\1/p' "$BODY" | head -n 1)"
    return 1
  fi
  # The token goes to the server on ssh stdin, as grep's pattern file: on no command line there.
  leak="$(timeout 120 "$SSH_BIN" "${SSH_OPTS[@]}" "root@$IP" \
    "exec 3<&0; journalctl -u vps-apps-$app-register --no-pager 2>/dev/null | grep -qF -f /dev/fd/3 && echo leak || echo clean" \
    <"$tok" 2>/dev/null | tr -d '\r\n')" || leak=""
  rm -f "$tok"
  [ "$leak" = clean ] || { fail "the register unit's journal holds the token (or could not be read: '$leak')"; return 1; }
  NOTE="${NOTE:+$NOTE; }registered with $E2E_RUNNER_URL: remove the runner there when done"
}

check_19_ghrunner() { check_runner ghrunner; }
check_20_glrunner() { check_runner glrunner; }

name_of() {
  case "$1" in
    1) echo install ;; 2) echo status ;; 3) echo https ;; 4) echo n8n ;; 5) echo docker ;;
    6) echo resume ;; 7) echo domain ;; 8) echo hub-64 ;; 9) echo timer ;; 10) echo docker-info ;;
    11) echo nft-reboot ;; 12) echo rc-port ;; 13) echo ssh ;; 14) echo nextcloud ;; 15) echo forgejo ;;
    16) echo wordpress ;; 17) echo uptimekuma ;; 18) echo grafana ;; 19) echo ghrunner ;; 20) echo glrunner ;;
  esac
}
func_of() {
  case "$1" in
    1) echo check_1_install ;; 2) echo check_2_status ;; 3) echo check_3_https ;; 4) echo check_4_n8n ;;
    5) echo check_5_docker ;; 6) echo check_6_resume ;; 7) echo check_7_domain ;; 8) echo check_8_hub64 ;;
    9) echo check_9_timer ;; 10) echo check_10_docker_info ;; 11) echo check_11_nft_reboot ;;
    12) echo check_12_rc_port ;; 13) echo check_13_ssh ;; 14) echo check_14_nextcloud ;;
    15) echo check_15_forgejo ;; 16) echo check_16_wordpress ;; 17) echo check_17_uptimekuma ;;
    18) echo check_18_grafana ;; 19) echo check_19_ghrunner ;; 20) echo check_20_glrunner ;;
  esac
}

# ---------------------------------------------------------------------------------------------

say "target: root@$IP app=$APP mode=${MODE:-default} version=$VERSION"
say "checks: $CHECKS"
code="$(curl_t -sS -o /dev/null -w '%{http_code}' --max-time 180 "https://codeload.github.com/RareCloudio/vps-apps/tar.gz/$VERSION" 2>/dev/null || true)"
if [ "$code" != 200 ]; then
  echo "vps-smoke: codeload answers HTTP $code for $VERSION; push the commit to GitHub first" >&2
  exit 2
fi

passed=0
failed=0
for n in "${ORDER[@]}"; do
  [[ "$SELECTED" == *" $n "* ]] || continue
  REASON=""
  NOTE=""
  FAILED_SEEN=""
  say "check $n $(name_of "$n")"
  if "$(func_of "$n")"; then
    if [ -n "$NOTE" ]; then
      echo "PASS $n $(name_of "$n") ($NOTE)"
    else
      echo "PASS $n $(name_of "$n")"
    fi
    passed=$((passed + 1))
  else
    echo "FAIL $n $(name_of "$n"): ${REASON:-no reason recorded}"
    failed=$((failed + 1))
  fi
done
say "done: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
