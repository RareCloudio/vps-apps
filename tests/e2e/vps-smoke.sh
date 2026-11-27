#!/usr/bin/env bash
# End-to-end smoke test of a real, fresh Ubuntu 24.04 VPS. Run from a workstation (Git Bash on
# Windows with the Windows OpenSSH client, or any bash). It never creates or deletes a server.
#
# Usage:
#   tests/e2e/vps-smoke.sh --ssh-key <path> --ip <ipv4> --app <docker|n8n> [--mode starter|pro] \
#     --version <sha40> --password-file <file> [--checks 1,2,3] [--expect-pw-auth yes|no|auto]
#
# One PASS or FAIL line per check, in the form `PASS <n> <name>` or `FAIL <n> <name>: <reason>`.
# Exit 0 only when every selected check passed. Progress goes to stderr. The password is read from
# the file and sent over ssh stdin or through jq stdin; it is never printed and never put on a
# command line. The rendered recipe holds it, so it lives only in a 0700 temp dir that is removed
# when the script ends.
# shellcheck disable=SC2016 # remote commands are single-quoted on purpose: they expand on the VPS
set -euo pipefail
# The Virtualizor tokens are replaced as plain text; an "&" in a password must stay an "&".
shopt -u patsub_replacement 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat >&2 <<'USAGE'
usage: vps-smoke.sh --ssh-key <path> --ip <ipv4> --app <docker|n8n> [--mode starter|pro]
                    --version <sha40> --password-file <file> [--checks 1,2,3,...]
                    [--expect-pw-auth yes|no|auto]
checks:
   1 install        render the recipe, substitute the Virtualizor tokens, run it as root
   2 status         /.well-known/rarecloud-app-status reads installing, then ready
   3 https          https://<ip-dashed>.sslip.io/ answers with a valid certificate
   4 n8n            login, workflow run, password change, reboot, rc update (n8n only)
   5 docker         whoami over HTTPS, postgres closed/open/closed on IPv4 (+IPv6) (docker only)
   6 resume         kill the install after app_up_setup, the timer resumes it (needs a fresh OS)
   7 domain         rc domain add app.<ip-dashed>.sslip.io serves the app on that name too
   8 hub-64         record the IPv6 /64, the pulls of the install and the Docker Hub rate limit
   9 timer          three minutes after ready: still ready, timer inactive, password file gone
  10 docker-info    docker info works with the daemon.json in place
  11 nft-reboot     nft -c passes; no "ordering cycle" in the journal after a reboot
  12 rc-port        rc port open/close leaves DOCKER-USER without a stale rule or a duplicate
  13 ssh            sshd on 22, password login and authorized_keys as the VPS shows them
Default checks: docker 1 2 3 5 7 8 9 10 11 12 13; n8n 1 2 3 4 7 8 9 10 11 12 13. Check 6 is never
a default (it installs by itself, so it cannot follow check 1). Selected checks run in this order:
1 6 2 3 4 5 7 8 10 12 13 9 11.
USAGE
  exit 2
}

SSH_KEY="" IP="" APP="" MODE="" VERSION="" PWFILE="" CHECKS="" EXPECT_PW="auto"
while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-key | --ip | --app | --mode | --version | --password-file | --checks | --expect-pw-auth)
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
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done

octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
[[ "$IP" =~ ^${octet}(\.${octet}){3}$ ]] || { echo "vps-smoke: --ip must be an IPv4 address" >&2; usage; }
case "$APP" in docker | n8n) ;; *) echo "vps-smoke: --app must be docker or n8n" >&2; usage ;; esac
case "$MODE" in
  "") ;;
  starter | pro) [ "$APP" = n8n ] || { echo "vps-smoke: --mode only goes with --app n8n" >&2; usage; } ;;
  *) echo "vps-smoke: --mode must be starter or pro" >&2; usage ;;
esac
[[ "$VERSION" =~ ^[0-9a-f]{40}$ ]] || { echo "vps-smoke: --version must be 40 lowercase hex characters" >&2; usage; }
[ -f "$SSH_KEY" ] || { echo "vps-smoke: --ssh-key file not found" >&2; usage; }
[ -f "$PWFILE" ] || { echo "vps-smoke: --password-file not found" >&2; usage; }
case "$EXPECT_PW" in yes | no | auto) ;; *) echo "vps-smoke: --expect-pw-auth must be yes, no or auto" >&2; usage ;; esac

ORDER=(1 6 2 3 4 5 7 8 10 12 13 9 11)
if [ -z "$CHECKS" ]; then
  if [ "$APP" = docker ]; then CHECKS="1,2,3,5,7,8,9,10,11,12,13"; else CHECKS="1,2,3,4,7,8,9,10,11,12,13"; fi
fi
SELECTED=" "
IFS=',' read -r -a _picked <<<"$CHECKS"
for n in "${_picked[@]}"; do
  [[ "$n" =~ ^([1-9]|1[0-3])$ ]] || { echo "vps-smoke: --checks takes numbers from 1 to 13" >&2; usage; }
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

say() { printf '[%4ss] %s\n' "$SECONDS" "$*" >&2; }
fail() {
  REASON="$*"
  return 1
}

# vcmd <command string>: run on the VPS as root, stdin closed.
vcmd() { "$SSH_BIN" "${SSH_OPTS[@]}" "root@$IP" "$1" </dev/null; }
# vcmd_t <seconds> <command string>: the same with a ceiling.
vcmd_t() {
  local secs="$1"
  shift
  timeout "$secs" "$SSH_BIN" "${SSH_OPTS[@]}" "root@$IP" "$1" </dev/null
}
# vscript [args...]: run the script on stdin with bash on the VPS. Args must be plain tokens.
vscript() { "$SSH_BIN" "${SSH_OPTS[@]}" "root@$IP" "bash -s -- $*"; }

wait_ssh() {
  local deadline=$((SECONDS + $1))
  until vcmd true >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 5
  done
}

# http_code <curl args...>: the HTTP status, 000 when nothing answered.
http_code() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$@" 2>/dev/null || true
}

status_now() { curl -s --max-time 5 "http://$IP/.well-known/rarecloud-app-status" 2>/dev/null | tr -d '\r\n' || true; }

# tcp_open <host> <port>: 0 when a TCP connection is made within 5 seconds.
tcp_open() {
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
  content="${content//'{{root_pass}}'/$PW}"
  printf '%s' "$content" >"$TMP/recipe.sh"
  content=""
  say "running the recipe on $IP as root (app=$APP mode=${MODE:-default} host=$HOST)"
  out="$("$SSH_BIN" "${SSH_OPTS[@]}" "root@$IP" \
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
  # The password reached the VPS byte for byte (the file is destroyed at ready; skip if it is gone).
  local_sum="$(printf '%s' "$PW" | sha256sum | cut -d' ' -f1)"
  remote_sum="$(vcmd 'test -f /etc/vps-apps/password && sha256sum /etc/vps-apps/password | cut -d" " -f1 || true' 2>/dev/null | tr -d '\r\n')"
  if [ -n "$remote_sum" ] && [ "$remote_sum" != "$local_sum" ]; then
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
      ready) READY=yes; return 0 ;;
      failed:*)
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
  deploy_recipe
}

check_2_status() {
  SAW_INSTALLING=no
  wait_ready || return 1
  [ "$SAW_INSTALLING" = yes ] || { fail "the status never read installing before ready"; return 1; }
}

check_3_https() {
  local body="$TMP/https.body" vr
  say "waiting for a valid certificate on https://$HOST/"
  ensure_ready || return 1
  retry 300 5 curl -fsS --max-time 15 -o "$body" "https://$HOST/" 2>/dev/null ||
    { fail "curl -fsS https://$HOST/ never passed (certificate or reply)"; return 1; }
  vr="$(curl -sS --max-time 15 -o /dev/null -w '%{ssl_verify_result}' "https://$HOST/" 2>/dev/null || true)"
  [ "$vr" = 0 ] || { fail "certificate verify result is '$vr'"; return 1; }
  if [ "$APP" = docker ] && ! grep -q 'Your Docker server is ready' "$body"; then
    fail "the Docker landing page text is missing"
    return 1
  fi
}

# --- n8n helpers -------------------------------------------------------------------------------

# n8n_req <method> <path> [body]: JSON from stdin when a third argument is given. Sets CODE; the
# response is in $BODY. APIKEY_HDR is sent when it exists.
CODE=""
n8n_req() {
  local method="$1" path="$2" hdr=()
  [ ! -f "$APIKEY_HDR" ] || hdr=(-H "@$(winpath "$APIKEY_HDR")")
  : >"$BODY"
  if [ $# -ge 3 ]; then
    CODE="$(curl -sS --max-time 60 -o "$(winpath "$BODY")" -w '%{http_code}' -X "$method" \
      -H 'Content-Type: application/json' -H 'browser-id: e2e-smoke' "${hdr[@]}" \
      -b "$(winpath "$JAR")" -c "$(winpath "$JAR")" --data-binary @- "https://$HOST$path" 2>/dev/null)" || CODE=000
  else
    CODE="$(curl -sS --max-time 60 -o "$(winpath "$BODY")" -w '%{http_code}' -X "$method" \
      -H 'browser-id: e2e-smoke' "${hdr[@]}" \
      -b "$(winpath "$JAR")" -c "$(winpath "$JAR")" "https://$HOST$path" </dev/null 2>/dev/null)" || CODE=000
  fi
}

# n8n_login <password file> <window seconds>: 0 on 200; 1 at once on 401/400; retries other codes
# (the proxy or n8n may still be starting) until the window ends.
n8n_login() {
  local deadline=$((SECONDS + $2))
  while :; do
    jq -n --arg e "admin@$HOST" --rawfile p "$(winpath "$1")" '{emailOrLdapLoginId: $e, password: $p}' |
      n8n_req POST /rest/login body
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
  out="$(curl -sS --max-time 30 "https://$HOST/webhook/$1" 2>/dev/null)" || return 1
  jq -e 'if type == "array" then .[0].smoke == "ok" else .smoke == "ok" end' <<<"$out" >/dev/null 2>&1
}

n8n_api_executions() {
  n8n_req GET "/api/v1/executions?workflowId=$1&limit=5"
  [ "$CODE" = 200 ] && jq -e '(.data | length) >= 1' "$BODY" >/dev/null 2>&1
}

reboot_vps() {
  local before after deadline
  before="$(vcmd 'cat /proc/sys/kernel/random/boot_id' | tr -d '\r\n')"
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
  local wf_id wf_path key newpw="$TMP/newpw" oldpw="$TMP/oldpw" wfjson="$TMP/wf.json"
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
  fi

  say "n8n: create an API key and a webhook workflow"
  printf '{"label":"e2e-smoke","scopes":["workflow:create","workflow:read","workflow:delete","workflow:list","workflow:activate","execution:list","execution:read"],"expiresAt":null}' |
    n8n_req POST /rest/api-keys body
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
  n8n_req POST /api/v1/workflows body <"$wfjson"
  rm -f "$wfjson"
  [ "$CODE" = 200 ] || { fail "POST /api/v1/workflows answered HTTP $CODE: $(head -c 300 "$BODY")"; return 1; }
  wf_id="$(jq -r '.id // empty' "$BODY")"
  [ -n "$wf_id" ] || { fail "no workflow id in the create response"; return 1; }
  n8n_req POST "/api/v1/workflows/$wf_id/activate" body <<<'{}'
  [ "$CODE" = 200 ] || { fail "activating the workflow answered HTTP $CODE: $(head -c 300 "$BODY")"; return 1; }

  say "n8n: run the workflow through its production webhook"
  retry 60 3 n8n_webhook_ok "$wf_path" || { fail "the webhook did not return the Set node output"; return 1; }
  retry 60 3 n8n_api_executions "$wf_id" || { fail "no execution of the workflow was recorded (HTTP $CODE)"; return 1; }

  say "n8n: change the owner password"
  newpw_value="Nw9$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s' "$newpw_value" >"$newpw"
  newpw_value=""
  jq -n --rawfile c "$(winpath "$oldpw")" --rawfile n "$(winpath "$newpw")" '{currentPassword: $c, newPassword: $n}' |
    n8n_req PATCH /rest/me/password body
  [ "$CODE" = 200 ] || { fail "PATCH /rest/me/password answered HTTP $CODE: $(head -c 200 "$BODY")"; return 1; }
  : >"$JAR"
  n8n_login "$oldpw" 20 && { fail "the old password still works after the change"; return 1; }
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
detect_targets() {
  TARGETS=("$IP")
  HAVE_V6=no
  V6_ADDR="$(vscript <<'EOF' | tr -d '\r\n'
ip -6 -o addr show scope global 2>/dev/null | awk '!/deprecated|temporary/ { sub("/.*", "", $4); print $4; exit }'
EOF
  )" || V6_ADDR=""
  if [ -z "$V6_ADDR" ]; then
    NOTE="IPv6 not tested: the VPS has no global IPv6 address"
  elif ! tcp_open 2606:4700:4700::1111 443; then
    NOTE="IPv6 not tested: this PC has no IPv6 connectivity"
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
  vscript <<'EOF' >/dev/null 2>&1
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
  detect_targets
  c5_cleanup

  say "docker: whoami behind the proxy"
  vscript "$IPD" <<'EOF' >/dev/null 2>&1 || { fail "cannot start the whoami container"; return 1; }
set -e
docker run -d --name smoke-whoami --network web \
  --label "caddy=whoami.$1.sslip.io" \
  --label 'caddy.reverse_proxy={{upstreams 80}}' traefik/whoami
EOF
  retry 300 5 bash -c 'curl -fsS --max-time 15 "https://whoami.$1.sslip.io/" | grep -q "^Hostname:"' _ "$IPD" ||
    { c5_cleanup; fail "https://whoami.$HOST/ does not answer with the whoami reply"; return 1; }
  rm -f "$body"

  say "docker: postgres published on 5432"
  vscript <<'EOF' >/dev/null 2>&1 || { fail "cannot start the postgres container"; return 1; }
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
  local out sum_before sum_after env_file
  env_file="/opt/vps-apps-data/$APP/.env"
  r="$(vcmd '. /etc/os-release; echo "$ID $VERSION_ID"' 2>&1)" || { fail "cannot ssh to root@$IP: $r"; return 1; }
  vcmd 'test ! -e /var/lib/vps-apps/steps' >/dev/null 2>&1 || { fail "this VPS already has install steps; reinstall the OS first"; return 1; }
  deploy_recipe || return 1
  say "resume: waiting for app_up_setup, then killing the install"
  out="$(vscript "$env_file" <<'EOF'
marker=/var/lib/vps-apps/steps/app_up_setup.done
end=$((SECONDS + 2400))
until [ -f "$marker" ]; do
  [ "$SECONDS" -lt "$end" ] && sleep 0.2 || { echo "TIMEOUT"; exit 1; }
done
systemctl kill --signal=SIGKILL vps-apps-install.service || true
sleep 1
st="$(cat /var/lib/vps-apps/public/.well-known/rarecloud-app-status 2>/dev/null || true)"
sum="$(sha256sum "$1" | cut -d' ' -f1)"
echo "KILLED $sum $st"
EOF
  )" || { fail "could not kill the install after app_up_setup: $out"; return 1; }
  case "$out" in KILLED\ *) ;; *) fail "unexpected kill output: $out"; return 1 ;; esac
  sum_before="$(printf '%s' "$out" | tr -d '\r' | awk '{print $2}')"
  [ "$(printf '%s' "$out" | tr -d '\r' | awk '{print $3}')" != ready ] || { fail "the install was already ready when it was killed"; return 1; }
  say "resume: killed ($out); the timer must resume it within a minute"
  SAW_INSTALLING=no
  wait_ready || return 1
  sum_after="$(vcmd "sha256sum $env_file | cut -d' ' -f1" | tr -d '\r\n')"
  [ "$sum_before" = "$sum_after" ] || { fail ".env checksum changed across the resume ($sum_before -> $sum_after)"; return 1; }
  vcmd 'grep -q "step app_up_setup: already done, skipping" /var/log/vps-apps-install.log' >/dev/null 2>&1 ||
    { fail "the install log does not show app_up_setup skipped on the resumed attempt"; return 1; }
  vcmd '[ "$(cat /var/lib/vps-apps/attempts)" -ge 2 ]' >/dev/null 2>&1 || { fail "the timer made fewer than two attempts"; return 1; }
}

check_7_domain() {
  local domain="app.$HOST" body="$TMP/domain.body" r
  ensure_ready || return 1
  say "rc domain add $domain"
  vcmd_t 900 "rc domain add $domain" >&2 2>&1 || { fail "rc domain add $domain failed"; return 1; }
  vcmd "grep -qxF $domain /etc/vps-apps/domains" >/dev/null 2>&1 || { fail "$domain is not in /etc/vps-apps/domains"; return 1; }
  if [ "$APP" = docker ]; then
    retry 300 5 bash -c 'curl -fsS --max-time 15 "https://$1/" | grep -q "Your Docker server is ready"' _ "$domain" ||
      { fail "https://$domain/ does not serve the Docker landing page"; return 1; }
  else
    retry 300 5 bash -c 'curl -fsS --max-time 15 "https://$1/healthz/readiness" | grep -q "\"status\":\"ok\""' _ "$domain" ||
      { fail "https://$domain/healthz/readiness does not answer"; return 1; }
    r="$(vscript "$HOST" "$domain" <<'EOF'
envf=/opt/vps-apps-data/n8n/.env
grep -qxF "WEBHOOK_URL=https://$1/" "$envf" || { echo "env WEBHOOK_URL"; exit 1; }
grep -qxF "N8N_EDITOR_BASE_URL=https://$1" "$envf" || { echo "env N8N_EDITOR_BASE_URL"; exit 1; }
grep -qxF "N8N_HOST=$1" "$envf" || { echo "env N8N_HOST"; exit 1; }
grep -qxF "VA_SITE_ADDRS=\"$1 $2\"" "$envf" || { echo "env VA_SITE_ADDRS"; exit 1; }
n=0
for c in $(docker ps -q); do
  s="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$c")"
  case "$s" in
    n8n | n8n-worker)
      n=$((n+1))
      e="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c")"
      printf '%s\n' "$e" | grep -qxF "WEBHOOK_URL=https://$1/" || { echo "container $s WEBHOOK_URL"; exit 1; }
      printf '%s\n' "$e" | grep -qxF "N8N_EDITOR_BASE_URL=https://$1" || { echo "container $s N8N_EDITOR_BASE_URL"; exit 1; }
      printf '%s\n' "$e" | grep -qxF "N8N_HOST=$1" || { echo "container $s N8N_HOST"; exit 1; }
      ;;
  esac
done
[ "$n" -ge 1 ] || { echo "no n8n container"; exit 1; }
echo ok
EOF
    )" || { fail "the n8n URL variables do not follow: $r"; return 1; }
  fi
  [ "$(http_code "https://$HOST/")" = 200 ] || { fail "the primary name https://$HOST/ stopped answering"; return 1; }
  rm -f "$body"
}

check_8_hub64() {
  local out
  ensure_ready || return 1
  out="$(vscript <<'EOF'
prefix="$(ip -6 route show 2>/dev/null | awk '$1 ~ /\/64$/ && $1 !~ /^fe80/ { print $1; exit }')"
addr="$(ip -6 -o addr show scope global 2>/dev/null | awk '!/deprecated|temporary/ { print $4; exit }')"
pulls="$(docker events --since 24h --until "$(date +%s)" --filter type=image --filter event=pull --format x 2>/dev/null | wc -l)"
tok="$(curl -fsS --max-time 20 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull' 2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
hdr=""
if [ -n "$tok" ]; then
  hdr="$(curl -fsSI --max-time 20 -H "Authorization: Bearer $tok" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest 2>/dev/null | tr -d '\r' | grep -i '^\(ratelimit-limit\|ratelimit-remaining\|docker-ratelimit-source\):' | tr '\n' ' ')"
fi
echo "v6-prefix=${prefix:-none} v6-addr=${addr:-none} pulls=$pulls hub: ${hdr:-no rate limit headers}"
EOF
  )" || { fail "cannot collect the Docker Hub facts over ssh"; return 1; }
  NOTE="$(printf '%s' "$out" | tr -d '\r')"
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
  local out
  ensure_ready || return 1
  vcmd 'grep -q "\"firewall-backend\": \"iptables\"" /etc/docker/daemon.json' >/dev/null 2>&1 ||
    { fail "/etc/docker/daemon.json has no firewall-backend iptables"; return 1; }
  vcmd 'systemctl is-active docker' >/dev/null 2>&1 || { fail "the docker service is not active"; return 1; }
  vcmd 'docker info' >/dev/null 2>&1 || { fail "docker info fails with the daemon.json in place"; return 1; }
  out="$(vcmd 'docker info 2>/dev/null | grep -i "firewall" || true' | tr -d '\r')"
  if [ -n "$out" ] && ! grep -qi iptables <<<"$out"; then
    fail "docker info reports a different firewall backend: $out"
    return 1
  fi
  vcmd 'journalctl -u docker -b --no-pager 2>/dev/null | grep -qiE "unknown (field|option)|failed to start daemon|unable to configure the Docker daemon"' >/dev/null 2>&1 &&
    { fail "the docker journal reports a configuration error"; return 1; }
  return 0
}

check_11_nft_reboot() {
  local out
  ensure_ready || return 1
  vcmd 'nft -c -f /etc/vps-apps/vps-apps.nft' >/dev/null 2>&1 || { fail "nft -c -f /etc/vps-apps/vps-apps.nft fails"; return 1; }
  reboot_vps || { fail "the VPS did not come back after the reboot"; return 1; }
  out="$(vcmd 'journalctl -b --no-pager 2>/dev/null | grep -i "ordering cycle" || true' | tr -d '\r')"
  [ -z "$out" ] || { fail "ordering cycle in the boot journal: $(printf '%s' "$out" | head -n 2 | tr '\n' ' ')"; return 1; }
  vcmd 'systemctl is-active vps-apps-nft docker >/dev/null' >/dev/null 2>&1 || { fail "vps-apps-nft or docker is not active after reboot"; return 1; }
  vcmd 'nft list table inet vps_apps >/dev/null' >/dev/null 2>&1 || { fail "table inet vps_apps is not loaded after reboot"; return 1; }
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
rc port open 5432 >/dev/null
rc port open 6000 >/dev/null
rc port close 5432 >/dev/null
rules="$(iptables -S DOCKER-USER)"
if printf '%s\n' "$rules" | grep -q -- '--ctorigdstport 5432 '; then echo "stale 5432 rule"; rc port close 6000 >/dev/null; exit 1; fi
n="$(printf '%s\n' "$rules" | grep -c -- '--ctorigdstport 6000 ')"
if [ "$n" -ne 1 ]; then echo "port 6000 has $n rules"; rc port close 6000 >/dev/null; exit 1; fi
d="$(printf '%s\n' "$rules" | sort | uniq -d)"
if [ -n "$d" ]; then echo "duplicate rules: $d"; rc port close 6000 >/dev/null; exit 1; fi
if grep -qx '5432/tcp' /etc/vps-apps/open-ports; then echo "5432/tcp still in open-ports"; rc port close 6000 >/dev/null; exit 1; fi
rc port close 6000 >/dev/null
rules="$(iptables -S DOCKER-USER)"
if printf '%s\n' "$rules" | grep -q -- '--ctorigdstport 6000 '; then echo "stale 6000 rule after close"; exit 1; fi
echo ok
EOF
  )" || { fail "$(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; return 1; }
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
  if [ "$expect" = no ] && [ "$(getv rootlogin)" != prohibit-password ]; then
    fail "permitrootlogin is '$(getv rootlogin)', expected prohibit-password with a key installed"
    return 1
  fi
  NOTE="pwauth=$actual rootlogin=$(getv rootlogin) keys=${keys:-0}"
}

name_of() {
  case "$1" in
    1) echo install ;; 2) echo status ;; 3) echo https ;; 4) echo n8n ;; 5) echo docker ;;
    6) echo resume ;; 7) echo domain ;; 8) echo hub-64 ;; 9) echo timer ;; 10) echo docker-info ;;
    11) echo nft-reboot ;; 12) echo rc-port ;; 13) echo ssh ;;
  esac
}
func_of() {
  case "$1" in
    1) echo check_1_install ;; 2) echo check_2_status ;; 3) echo check_3_https ;; 4) echo check_4_n8n ;;
    5) echo check_5_docker ;; 6) echo check_6_resume ;; 7) echo check_7_domain ;; 8) echo check_8_hub64 ;;
    9) echo check_9_timer ;; 10) echo check_10_docker_info ;; 11) echo check_11_nft_reboot ;;
    12) echo check_12_rc_port ;; 13) echo check_13_ssh ;;
  esac
}

# ---------------------------------------------------------------------------------------------

say "target: root@$IP app=$APP mode=${MODE:-default} version=$VERSION"
say "checks: $CHECKS"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 180 "https://codeload.github.com/RareCloudio/vps-apps/tar.gz/$VERSION" 2>/dev/null || true)"
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
