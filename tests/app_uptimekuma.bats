#!/usr/bin/env bats
load test_helper

setup() {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  APP_DIR="$ROOT_DIR/apps/uptimekuma"
  # shellcheck source=../lib/common.sh
  . "$ROOT_DIR/lib/common.sh"
  # shellcheck source=../lib/compose.sh
  . "$ROOT_DIR/lib/compose.sh"
  # shellcheck source=../lib/images.sh
  . "$ROOT_DIR/lib/images.sh"
  # shellcheck source=../lib/steps.sh
  . "$ROOT_DIR/lib/steps.sh"
  # shellcheck source=../base/60-proxy.sh
  . "$ROOT_DIR/base/60-proxy.sh"
  # shellcheck source=../apps/uptimekuma/app.sh
  . "$APP_DIR/app.sh"
  VA_HOST=k.example.com
  export VA_HOST
  DATA="$(p /opt/vps-apps-data/uptimekuma)"
  PWF="$BATS_TEST_TMPDIR/password"
  printf '%s' 'Secret123' >"$PWF"
  export VA_UK_WAIT=2 VA_UK_INTERVAL=0
  CURL_ARGV="$BATS_TEST_TMPDIR/curl_argv"
  EXEC_LOG="$BATS_TEST_TMPDIR/exec.log"
  : >"$CURL_ARGV"
  : >"$EXEC_LOG"
}

ENTRY_OK='{"type":"entryPage","entryPage":"dashboard"}'

# A curl that records every argv entry on its own line. The loopback entry page fails as many times
# as the number in $BATS_TEST_TMPDIR/ready_fail (then answers ENTRY_BODY).
stub_curl() {
  curl() {
    local n
    printf '%s\n' "$@" >>"$CURL_ARGV"
    if [[ "$*" == *"http://127.0.0.1:3001/api/entry-page"* ]]; then
      n="$(cat "$BATS_TEST_TMPDIR/ready_fail" 2>/dev/null || echo 0)"
      if [ "$n" -gt 0 ]; then
        echo $((n - 1)) >"$BATS_TEST_TMPDIR/ready_fail"
        return 7
      fi
      printf '%s' "${ENTRY_BODY-$ENTRY_OK}"
    fi
    return 0
  }
}

# A docker that hands every call but "compose ... exec" to the stub on PATH. An exec of the admin
# client is logged as "<mode> <arg>" in EXEC_LOG with the script replaced by <admin.js> (it must be
# apps/uptimekuma/admin.js byte for byte), its stdin is kept in exec_stdin.<n>, and it answers:
#   setup, login   exit with the next code from exec_rcs (one per line), else UK_SETUP_RC (0)
#   need-setup     print UK_NEED_SETUP (false) and exit with UK_NEED_RC (0)
stub_docker() {
  docker() {
    local a prev="" script="" mode="" arg="" i=0 n rc line
    local -a logged=()
    if [ "${1:-}" != compose ] || [[ " $* " != *" exec "* ]]; then
      command docker "$@"
      return
    fi
    for a in "$@"; do
      i=$((i + 1))
      if [ "$prev" = -e ] && [ -z "$script" ]; then
        script="$a"
        logged+=("<admin.js>")
      else
        logged+=("$a")
      fi
      prev="$a"
    done
    printf '%s\n' "${logged[*]}" >>"$STUB_TMP/docker.log"
    [ "$script" = "$(cat "$APP_DIR/admin.js")" ] || {
      echo "the exec did not get admin.js" >&2
      return 99
    }
    # The arguments after the script: mode and its argument.
    prev="" i=0
    for a in "$@"; do
      if [ "$i" = 1 ]; then
        mode="$a" i=2
      elif [ "$i" = 2 ]; then
        arg="$a" i=3
      elif [ "$a" = "$script" ] && [ "$prev" = -e ]; then
        i=1
      fi
      prev="$a"
    done
    n="$(wc -l <"$EXEC_LOG")"
    cat >"$BATS_TEST_TMPDIR/exec_stdin.$n"
    printf '%s %s\n' "$mode" "$arg" >>"$EXEC_LOG"
    case "$mode" in
      need-setup)
        printf '%s\n' "${UK_NEED_SETUP-false}"
        return "${UK_NEED_RC:-0}"
        ;;
      *)
        rc="${UK_SETUP_RC:-0}"
        if [ -s "$BATS_TEST_TMPDIR/exec_rcs" ]; then
          line="$(head -n 1 "$BATS_TEST_TMPDIR/exec_rcs")"
          sed -i 1d "$BATS_TEST_TMPDIR/exec_rcs"
          rc="$line"
        fi
        return "$rc"
        ;;
    esac
  }
}

# exec_stdin_of <mode>: the stdin of the last exec in that mode.
exec_stdin_of() {
  local n
  n="$(grep -n "^$1 " "$EXEC_LOG" | tail -n 1 | cut -d: -f1)"
  [ -n "$n" ] || return 1
  cat "$BATS_TEST_TMPDIR/exec_stdin.$((n - 1))"
}

# The real docker, when the machine has one (the stub is first on PATH): merged config checks.
real_docker() {
  local d
  while IFS= read -r d; do
    [ "$d" = "$BATS_TEST_DIRNAME/stubs" ] && continue
    [ -x "$d/docker" ] && { echo "$d/docker"; return 0; }
  done < <(tr ':' '\n' <<<"$PATH")
  return 1
}

# Docker Desktop reached from WSL is a Windows binary and wants Windows paths; elsewhere a no-op.
native_path() {
  if command -v wslpath >/dev/null; then wslpath -w "$1"; else echo "$1"; fi
}

merged_config() {
  local docker f
  local -a args=()
  docker="$(real_docker)" || skip "no real docker on this machine"
  for f in "$@"; do args+=(-f "$(native_path "$APP_DIR/$f")"); done
  "$docker" compose "${args[@]}" --env-file "$(native_path "$DATA/.env")" config --format json
}

UK_REPO=louislam/uptime-kuma

@test "the .env is mode 600, carries the pinned image and its ref, and a second run keeps it byte-identical" {
  app_prepare
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  want="$(printf '%s' "$UK_REPO:2" | sha256sum | cut -d' ' -f1)"
  grep -qxF "UPTIME_KUMA_IMAGE=$UK_REPO@sha256:$want" "$DATA/.env"
  grep -qxF "UPTIME_KUMA_IMAGE_REF=$UK_REPO:2" "$DATA/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  : >"$STUB_TMP/docker.log"
  app_prepare
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  # A re-run resolves nothing: the pinned digest stays the one installed.
  refute_grep -q imagetools "$STUB_TMP/docker.log"
}

@test "Uptime Kuma is installed from its major tag 2, resolved and pinned by digest, never latest, beta or next" {
  app_prepare
  [ "$VA_UPTIME_KUMA_IMAGE_REF" = "$UK_REPO:2" ]
  grep -qxF "buildx imagetools inspect $UK_REPO:2 --format {{json .Manifest}}" "$STUB_TMP/docker.log"
  grep -qF 'image: ${UPTIME_KUMA_IMAGE:-louislam/uptime-kuma:2}' "$APP_DIR/compose.yml"
  refute_grep -qE 'uptime-kuma:(latest|beta|next|nightly|1|3)' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl" "$APP_DIR/app.sh"
}

@test "an image that cannot be resolved fails app_prepare and leaves no .env" {
  : >"$BATS_TEST_TMPDIR/inspect_fail"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
}

@test "VA_SITE_ADDRS has the host, then the valid extra domains; invalid ones are dropped" {
  mkdir -p "$(p /etc/vps-apps)"
  printf 'www.example.org\nnot a domain\n$(id).example.net\nk.example.com\n' >"$(p /etc/vps-apps/domains)"
  app_prepare
  grep -qxF 'VA_SITE_ADDRS="k.example.com www.example.org"' "$DATA/.env"
}

@test "the template substitution is literal for a value with an ampersand and a backslash" {
  resolve_image_digest() { printf '%s\n' 'x/y&z\w@sha256:abc'; }
  app_prepare
  grep -qxF 'UPTIME_KUMA_IMAGE=x/y&z\w@sha256:abc' "$DATA/.env"
}

@test "the compose files are the base and setup ones, then the base and expose ones once the marker exists" {
  app_prepare
  run app_compose_files
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$APP_DIR/compose.yml" ]
  [ "${lines[1]}" = "$APP_DIR/compose.setup.yml" ]
  : >"$DATA/exposed"
  run app_compose_files
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "$APP_DIR/compose.expose.yml" ]
}

@test "the database is SQLite by env, so Uptime Kuma never shows its database setup page" {
  grep -qE '^\s+UPTIME_KUMA_DB_TYPE: sqlite$' "$APP_DIR/compose.yml"
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services["uptime-kuma"].environment.UPTIME_KUMA_DB_TYPE' <<<"$cfg")" = sqlite ]
  # The websocket origin check stays on (it is Uptime Kuma's default, set so it cannot loosen).
  [ "$(jq -r '.services["uptime-kuma"].environment.UPTIME_KUMA_WS_ORIGIN_CHECK' <<<"$cfg")" = cors-like ]
  [ "$(jq -r '.services["uptime-kuma"].volumes[0] | "\(.source):\(.target)"' <<<"$cfg")" = "uptime_kuma_data:/app/data" ]
}

@test "the setup override publishes 3001 on loopback only, and nothing joins the proxy network before exposure" {
  grep -qF '"127.0.0.1:3001:3001"' "$APP_DIR/compose.setup.yml"
  refute_grep -qi 'caddy' "$APP_DIR/compose.setup.yml" "$APP_DIR/compose.yml"
  refute_grep -qE '^\s+- web$|external: true' "$APP_DIR/compose.setup.yml" "$APP_DIR/compose.yml"
  refute_grep -qE '^\s+ports:' "$APP_DIR/compose.yml" "$APP_DIR/compose.expose.yml"
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services["uptime-kuma"].ports | length' <<<"$cfg")" = 1 ]
  [ "$(jq -r '.services["uptime-kuma"].ports[0] | "\(.host_ip):\(.published):\(.target)"' <<<"$cfg")" = "127.0.0.1:3001:3001" ]
  [ "$(jq -r '.services["uptime-kuma"].labels // {} | length' <<<"$cfg")" = 0 ]
  [ "$(jq -r '.services["uptime-kuma"].networks | keys | join(",")' <<<"$cfg")" = default ]
}

@test "the expose override keeps the default network, joins web, labels the names and publishes no port" {
  mkdir -p "$(p /etc/vps-apps)"
  printf 'status.example.org\n' >"$(p /etc/vps-apps/domains)"
  app_prepare
  cfg="$(merged_config compose.yml compose.expose.yml)"
  [ "$(jq -r '.services["uptime-kuma"].networks | keys | join(",")' <<<"$cfg")" = "default,web" ]
  [ "$(jq -r '.services["uptime-kuma"].labels.caddy' <<<"$cfg")" = "k.example.com status.example.org" ]
  [ "$(jq -r '.services["uptime-kuma"].labels["caddy.reverse_proxy"]' <<<"$cfg")" = "{{upstreams 3001}}" ]
  [ "$(jq -r '.services["uptime-kuma"].ports // [] | length' <<<"$cfg")" = 0 ]
  [ "$(jq -r '.networks.web.external' <<<"$cfg")" = true ]
}

@test "the expose label is exactly the hostnames, with no scheme or port" {
  grep -qF 'caddy: ${VA_SITE_ADDRS:?VA_SITE_ADDRS is not set}' "$APP_DIR/compose.expose.yml"
  grep -qF 'caddy.reverse_proxy: "{{upstreams 3001}}"' "$APP_DIR/compose.expose.yml"
  refute_grep -qE 'https?://|:443' "$APP_DIR/compose.expose.yml"
}

@test "no compose or env file carries a password or an initial admin, and nothing bypasses the origin check" {
  refute_grep -qiE 'password|UK_INITIAL_ADMIN|bcrypt' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl"
  refute_grep -qi 'bypass' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl"
  # The admin client never turns the login off.
  refute_grep -q 'disableAuth' "$APP_DIR/admin.js"
}

@test "app_up_setup starts the stack with the setup file and exposes nothing" {
  app_prepare
  app_up_setup
  grep -qxF "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.setup.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
  [ ! -e "$DATA/exposed" ]
  [ ! -e "$(p /var/lib/vps-apps/site-mode)" ]
}

@test "the admin is created by the app container's own node, on loopback, with the password on stdin only" {
  app_prepare
  stub_curl
  stub_docker
  printf '%s' 'P@ss"w\0rd $x`y;1A' >"$PWF"
  app_create_admin "$PWF"
  grep -qxF "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.setup.yml --env-file $DATA/.env exec -T uptime-kuma node -e <admin.js> setup https://k.example.com" "$STUB_TMP/docker.log"
  [ "$(cat "$EXEC_LOG")" = "setup https://k.example.com" ]
  exec_stdin_of setup >"$BATS_TEST_TMPDIR/sent"
  cmp "$BATS_TEST_TMPDIR/sent" "$PWF"
  refute_grep -qF 'P@ss' "$STUB_TMP/docker.log" "$CURL_ARGV" "$DATA/.env"
  [ ! -e "$(p /root/vps-apps-credentials.txt)" ]
  # No temp password file is left behind.
  [ "$(find "$DATA" -name '.admin-pw.*' | wc -l)" -eq 0 ]
}

@test "the admin client logs in as admin, and admin.js names that user and the loopback server" {
  grep -qF 'const USERNAME = "admin";' "$APP_DIR/admin.js"
  grep -qF 'const LOCAL_URL = "http://127.0.0.1:3001";' "$APP_DIR/admin.js"
  grep -qF 'transports: ["websocket"]' "$APP_DIR/admin.js"
}

@test "the password never lands in the .env, a compose file or a docker argument" {
  app_prepare
  stub_curl
  stub_docker
  app_create_admin "$PWF"
  refute_grep -qF 'Secret123' "$DATA/.env" "$STUB_TMP/docker.log" "$APP_DIR"/compose*.yml
  [ "$(exec_stdin_of setup)" = Secret123 ]
}

@test "app_create_admin waits for the main server on loopback before the admin call" {
  app_prepare
  stub_curl
  stub_docker
  echo 2 >"$BATS_TEST_TMPDIR/ready_fail"
  app_create_admin "$PWF"
  [ "$(grep -cxF 'http://127.0.0.1:3001/api/entry-page' "$CURL_ARGV")" -eq 3 ]
  [ "$(cat "$EXEC_LOG")" = "setup https://k.example.com" ]
}

@test "app_create_admin fails, bounded, when Uptime Kuma never answers, and makes no admin call" {
  app_prepare
  stub_docker
  curl() { printf '%s\n' "$*" >>"$CURL_ARGV"; return 7; }
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  grep -qF -- '--max-time 30 http://127.0.0.1:3001/api/entry-page' "$CURL_ARGV"
  [ ! -s "$EXEC_LOG" ]
}

@test "the database setup page or any other answer is not ready: no admin call is made" {
  app_prepare
  stub_curl
  stub_docker
  for body in '{"type":"setup-database"}' 'Not found' '' '{"type":"statusPageMatchedDomain"}'; do
    ENTRY_BODY="$body" run app_create_admin "$PWF"
    [ "$status" -ne 0 ]
  done
  [ ! -s "$EXEC_LOG" ]
}

@test "a failed admin call fails the step" {
  app_prepare
  stub_curl
  stub_docker
  UK_SETUP_RC=1 run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  # An unexpected exit code is a failure too, never a success.
  UK_SETUP_RC=3 run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
}

@test "a retry of app_create_admin makes the same call with the same password and succeeds" {
  app_prepare
  stub_curl
  stub_docker
  printf '1\n' >"$BATS_TEST_TMPDIR/exec_rcs"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  app_create_admin "$PWF"
  [ "$(grep -c '^setup https://k.example.com$' "$EXEC_LOG")" -eq 2 ]
  [ "$(exec_stdin_of setup)" = Secret123 ]
}

@test "a password that breaks Uptime Kuma's rule falls back to a generated one in the credentials file" {
  app_prepare
  stub_curl
  stub_docker
  for bad in short abcdefgh ABCDEFGH 12345678 '!!!!!!!!' 'Pässword1x' $'Tab\tPass1word' 'Aa 1' '      '; do
    rm -f "$(p /root/vps-apps-credentials.txt)"
    printf '%s' "$bad" >"$PWF"
    app_create_admin "$PWF"
    cred="$(p /root/vps-apps-credentials.txt)"
    [ "$(stat -c %a "$cred")" = 600 ]
    sent="$(exec_stdin_of setup)"
    [ "$sent" != "$bad" ]
    [[ "${#sent}" -ge 8 && "$sent" =~ [A-Z] && "$sent" =~ [a-z] && "$sent" =~ [0-9] ]]
    grep -qxF "Password: $sent" "$cred"
    grep -qxF 'Username: admin' "$cred"
  done
}

@test "passwords Uptime Kuma accepts are sent as they are, including every order-form password" {
  app_prepare
  stub_curl
  stub_docker
  # The e2e password (tests/e2e/README.md) is among them.
  for good in abcde1 'Abcdefg1' 'ab!!!!' $'Ab1$"\x60\x27\\ x' "A1$(printf 'x%.0s' $(seq 62))" '!"#$%&()*+,-./:;<=>?@[\]^_`{|}~1'; do
    printf '%s' "$good" >"$PWF"
    app_create_admin "$PWF"
    [ "$(exec_stdin_of setup)" = "$good" ]
    [ ! -e "$(p /root/vps-apps-credentials.txt)" ]
  done
}

@test "Uptime Kuma rejecting the password (exit 2) triggers the fallback and a second call" {
  app_prepare
  stub_curl
  stub_docker
  printf '2\n0\n' >"$BATS_TEST_TMPDIR/exec_rcs"
  app_create_admin "$PWF"
  cred="$(p /root/vps-apps-credentials.txt)"
  [ -f "$cred" ]
  [ "$(grep -c '^setup ' "$EXEC_LOG")" -eq 2 ]
  sent="$(exec_stdin_of setup)"
  [ "$sent" != Secret123 ]
  grep -qxF "Password: $sent" "$cred"
}

@test "a second rejection of the generated password fails the step" {
  app_prepare
  stub_curl
  stub_docker
  printf '2\n2\n' >"$BATS_TEST_TMPDIR/exec_rcs"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  [ "$(grep -c '^setup ' "$EXEC_LOG")" -eq 2 ]
}

@test "a retry after a fallback keeps the credentials file and uses the password in it" {
  app_prepare
  stub_curl
  stub_docker
  printf '2\n1\n' >"$BATS_TEST_TMPDIR/exec_rcs"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  cp "$(p /root/vps-apps-credentials.txt)" "$BATS_TEST_TMPDIR/cred1"
  first="$(exec_stdin_of setup)"
  # The retry goes straight to the generated password, even though the chosen one passes our check.
  : >"$EXEC_LOG"
  app_create_admin "$PWF"
  cmp "$(p /root/vps-apps-credentials.txt)" "$BATS_TEST_TMPDIR/cred1"
  [ "$(grep -c '^setup ' "$EXEC_LOG")" -eq 1 ]
  [ "$(exec_stdin_of setup)" = "$first" ]
}

@test "app_expose brings the setup stack up, waits, checks that setup is no longer offered, then exposes" {
  app_prepare
  stub_curl
  stub_docker
  : >"$DATA/exposed"
  : >"$STUB_TMP/docker.log"
  app_expose
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
  setup_line="$(grep -n "compose.setup.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log" | head -n1 | cut -d: -f1)"
  check_line="$(grep -n 'exec -T uptime-kuma node -e <admin.js> need-setup' "$STUB_TMP/docker.log" | head -n1 | cut -d: -f1)"
  expose_line="$(grep -n "compose.expose.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log" | head -n1 | cut -d: -f1)"
  [ -n "$setup_line" ] && [ -n "$check_line" ] && [ -n "$expose_line" ]
  [ "$setup_line" -lt "$check_line" ] && [ "$check_line" -lt "$expose_line" ]
  grep -qxF 'http://127.0.0.1:3001/api/entry-page' "$CURL_ARGV"
  # The setup check sends nothing on stdin.
  [ ! -s "$BATS_TEST_TMPDIR/exec_stdin.0" ]
}

@test "app_expose refuses while Uptime Kuma still offers its setup, and changes nothing" {
  app_prepare
  stub_curl
  stub_docker
  : >"$STUB_TMP/docker.log"
  UK_NEED_SETUP=true run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ ! -e "$(p /var/lib/vps-apps/site-mode)" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
}

@test "app_expose refuses when the setup state cannot be read" {
  app_prepare
  stub_curl
  stub_docker
  for answer in '' 'False' 'no' 'false false' '{"needSetup":false}'; do
    UK_NEED_SETUP="$answer" run app_expose
    [ "$status" -ne 0 ]
    [ ! -e "$DATA/exposed" ]
  done
  UK_NEED_RC=1 run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
}

@test "app_expose fails without exposing when Uptime Kuma never answers after the setup stack is up" {
  app_prepare
  stub_curl
  stub_docker
  echo 999 >"$BATS_TEST_TMPDIR/ready_fail"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ ! -s "$EXEC_LOG" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
}

@test "a failed start in app_expose takes the stack down, drops the marker and shows the failed page" {
  app_prepare
  stub_curl
  stub_docker
  docker() {
    printf '%s\n' "$*" >>"$STUB_TMP/docker_calls"
    if [[ " $* " == *" exec "* ]]; then
      cat >/dev/null
      echo false
      return 0
    fi
    [[ "$*" != *compose.expose.yml*" up"* ]]
  }
  run app_expose
  [ "$status" -ne 0 ]
  grep -q ' down' "$STUB_TMP/docker_calls"
  [ ! -e "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
}

@test "a failed expose followed by a retry recovers, and the retry still refuses while setup is offered" {
  app_prepare
  stub_curl
  stub_docker
  real_stub_docker="$(declare -f docker)"
  docker() {
    if [[ "$*" == *compose.expose.yml*" up"* ]] && [ ! -e "$BATS_TEST_TMPDIR/expose_failed_once" ]; then
      : >"$BATS_TEST_TMPDIR/expose_failed_once"
      printf '%s\n' "$*" >>"$STUB_TMP/docker.log"
      return 1
    fi
    uk_docker "$@"
  }
  eval "${real_stub_docker/docker ()/uk_docker ()}"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
  : >"$STUB_TMP/docker.log"
  UK_NEED_SETUP=true run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  grep -q "compose.setup.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
  run app_expose
  [ "$status" -eq 0 ]
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
}

@test "app_ready_check needs Uptime Kuma's main server over HTTPS on the server's own name" {
  curl() { printf '%s\n' "$*" >"$BATS_TEST_TMPDIR/curl_args"; printf '%s' "$ENTRY_OK"; }
  app_ready_check
  grep -qF -- '-fsS --max-time 10 --resolve k.example.com:443:127.0.0.1 https://k.example.com/api/entry-page' "$BATS_TEST_TMPDIR/curl_args"
  # The database setup server, any other answer, and a curl failure (bad certificate) are not ready.
  for body in '{"type":"setup-database"}' 'Your Docker server is ready' ''; do
    curl() { printf '%s' "$body"; }
    run app_ready_check
    [ "$status" -ne 0 ]
  done
  curl() { printf '%s' "$ENTRY_OK"; return 60; }
  run app_ready_check
  [ "$status" -ne 0 ]
}

@test "app_domain_added serves every name, keeps every other line of the .env and recreates the app" {
  app_prepare
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  mkdir -p "$(p /etc/vps-apps)"
  printf 'status.example.org\n' >"$(p /etc/vps-apps/domains)"
  : >"$DATA/exposed"
  : >"$STUB_TMP/docker.log"
  app_domain_added status.example.org
  grep -qxF 'VA_SITE_ADDRS="k.example.com status.example.org"' "$DATA/.env"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  diff <(grep -v '^VA_SITE_ADDRS=' "$BATS_TEST_TMPDIR/before") <(grep -v '^VA_SITE_ADDRS=' "$DATA/.env")
  grep -qxF "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.expose.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
  printf 'status.example.org\ntwo.example.org\n' >"$(p /etc/vps-apps/domains)"
  app_domain_added two.example.org
  grep -qxF 'VA_SITE_ADDRS="k.example.com status.example.org two.example.org"' "$DATA/.env"
}

@test "Uptime Kuma defines no app_domain_check, so rc domain add accepts extra domains" {
  run declare -F app_domain_check
  [ "$status" -ne 0 ]
}

@test "the image tag is the major one, so rc update stays on 2.x through the shared resolver" {
  # No app_update_env: resolve_env_images re-resolves the :2 tag, which only ever points to 2.x.
  run declare -F app_update_env
  [ "$status" -ne 0 ]
  app_prepare
  resolve_env_images "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  grep -qxF "UPTIME_KUMA_IMAGE_REF=$UK_REPO:2" "$BATS_TEST_TMPDIR/out"
  grep -qxF "UPTIME_KUMA_IMAGE=$UK_REPO@sha256:$(printf '%s' "$UK_REPO:2" | sha256sum | cut -d' ' -f1)" "$BATS_TEST_TMPDIR/out"
}

# ---------------------------------------------------------------------------------------------
# admin.js against an in-process stand-in for Uptime Kuma's socket.io API (node only; skipped
# without it). The stand-in is a fake socket.io-client module that answers the events the way
# server/server.js of Uptime Kuma 2.5.12 does, keeps its users and settings in a JSON state file,
# and, like the real server, drops any event sent before it has sent "info".

FAKE_CLIENT='"use strict";
const fs = require("fs");
const STATE = process.env.UK_FAKE_STATE;
const LOG = process.env.UK_FAKE_LOG;
const load = () => JSON.parse(fs.readFileSync(STATE, "utf8"));
const save = (s) => fs.writeFileSync(STATE, JSON.stringify(s));
const note = (line) => fs.appendFileSync(LOG, line + "\n");
// check-password-strength 2.0.10 as server/server.js calls it: "Too weak" below 6 characters or
// below two of lowercase, uppercase, digits and symbols.
function tooWeak(pw) {
    const kinds = [/[a-z]/, /[A-Z]/, /[0-9]/, /[!"#$%&\x27()*+,\-./:;<=>?@[\\\]^_`{|}~]/].filter((r) => r.test(pw)).length;
    return pw.length < 6 || kinds < 2;
}
exports.io = function io(url, opts) {
    note("connect " + url + " " + JSON.stringify(opts.transports) + " reconnection=" + opts.reconnection);
    const listeners = {};
    let ready = false;
    let user = null;
    const fire = (ev, ...a) => (listeners[ev] || []).splice(0).forEach((f) => f(...a));
    const handlers = {
        needSetup: (cb) => cb(Object.keys(load().users).length === 0),
        setup: (username, password, cb) => {
            const s = load();
            if (tooWeak(password)) return cb({ ok: false, msg: "passwordTooWeak", msgi18n: true });
            if (Object.keys(s.users).length !== 0) return cb({ ok: false, msg: "Uptime Kuma has been initialized. If you want to run setup again, please delete the database." });
            s.users[username] = password;
            save(s);
            cb({ ok: true, msg: "successAdded", msgi18n: true });
        },
        login: (data, cb) => {
            const s = load();
            if (s.users[data.username] !== undefined && s.users[data.username] === data.password) {
                user = data.username;
                return cb({ ok: true, token: "jwt" });
            }
            cb({ ok: false, msg: "authIncorrectCreds", msgi18n: true });
        },
        getSettings: (cb) => {
            if (!user) return cb({ ok: false, msg: "You are not logged in." });
            const data = { ...load().settings };
            if (!data.serverTimezone) data.serverTimezone = "UTC";
            cb({ ok: true, data });
        },
        setSettings: (data, currentPassword, cb) => {
            if (!user) return cb({ ok: false, msg: "You are not logged in." });
            const s = load();
            if (s.failSetSettings) return cb({ ok: false, msg: "boom" });
            note("setSettings " + JSON.stringify(data));
            Object.assign(s.settings, data);
            save(s);
            cb({ ok: true, msg: "Saved.", msgi18n: true });
        },
    };
    const socket = {
        on(ev, f) { (listeners[ev] = listeners[ev] || []).push(f); return socket; },
        once(ev, f) { return socket.on(ev, f); },
        emit(ev, ...args) {
            if (!ready) { note("dropped " + ev); return socket; }
            note("event " + ev);
            const cb = args[args.length - 1];
            setImmediate(() => {
                if (load().silent) return;
                handlers[ev](...args.slice(0, -1), cb);
            });
            return socket;
        },
        disconnect() { return socket; },
        close() { return socket; },
    };
    setImmediate(() => {
        const s = load();
        if (s.refuse) return fire("connect_error", new Error("connect ECONNREFUSED 127.0.0.1:3001"));
        fire("connect");
        if (s.silent) return;
        setTimeout(() => { ready = true; fire("info", { primaryBaseURL: s.settings.primaryBaseURL || null }); }, 20);
    });
    return socket;
};
'

# node_setup [state-json]: a working directory with the fake module, and the state file.
node_setup() {
  local empty='{"users":{},"settings":{}}'
  command -v node >/dev/null 2>&1 || skip "no node on this machine"
  NODE_DIR="$BATS_TEST_TMPDIR/node"
  mkdir -p "$NODE_DIR/node_modules/socket.io-client"
  printf '%s' "$FAKE_CLIENT" >"$NODE_DIR/node_modules/socket.io-client/index.js"
  export UK_FAKE_STATE="$NODE_DIR/state.json" UK_FAKE_LOG="$NODE_DIR/log"
  printf '%s' "${1:-$empty}" >"$UK_FAKE_STATE"
  : >"$UK_FAKE_LOG"
}

# admin_js <args...>: run admin.js as the container does (node -e), from the fake's directory.
admin_js() {
  (cd "$NODE_DIR" && node -e "$(cat "$APP_DIR/admin.js")" "$@")
}

state() {
  jq -r "$1" "$UK_FAKE_STATE"
}

@test "admin.js setup creates admin with the exact stdin password, logs in and saves the proxy settings" {
  node_setup
  printf '%s' 'P@ss"w\0rd $x`y;1A' >"$PWF"
  run admin_js setup https://k.example.com <"$PWF"
  [ "$status" -eq 0 ]
  [ "$(jq -j '.users.admin' "$UK_FAKE_STATE")" = "$(cat "$PWF")" ]
  [ "$(state '.users | keys | join(",")')" = admin ]
  [ "$(state .settings.trustProxy)" = true ]
  [ "$(state .settings.primaryBaseURL)" = https://k.example.com ]
  # The settings are saved as the Settings page saves them, with its defaults filled in.
  [ "$(state .settings.nscd)" = true ]
  [ "$(state .settings.entryPage)" = dashboard ]
  [ "$(state .settings.checkUpdate)" = true ]
  [ "$(state .settings.searchEngineIndex)" = false ]
  [ "$(state .settings.keepDataPeriodDays)" = 180 ]
  [ "$(state '.settings.tlsExpiryNotifyDays | join(",")')" = 7,14,21 ]
  [ "$(state '.settings.domainExpiryNotifyDays | join(",")')" = 7,14,21 ]
  # It talks to the loopback server over a websocket, once, and only after the server's info.
  grep -qxF 'connect http://127.0.0.1:3001 ["websocket"] reconnection=false' "$UK_FAKE_LOG"
  refute_grep -q '^dropped' "$UK_FAKE_LOG"
  [ "$(grep '^event ' "$UK_FAKE_LOG" | tr '\n' ' ')" = "event needSetup event setup event login event getSettings event setSettings event getSettings " ]
  # The password is never printed.
  refute_grep -qF 'P@ss' <<<"$output"
  refute_grep -qF 'P@ss' "$UK_FAKE_LOG"
}

@test "admin.js setup on a retry finds admin there, makes no setup call, and succeeds" {
  node_setup '{"users":{"admin":"Secret123"},"settings":{"trustProxy":true,"primaryBaseURL":"https://mine.example.org","nscd":false}}'
  run admin_js setup https://k.example.com <"$PWF"
  [ "$status" -eq 0 ]
  refute_grep -qx 'event setup' "$UK_FAKE_LOG"
  [ "$(state .settings.trustProxy)" = true ]
  # A base URL or a setting the owner chose is kept.
  [ "$(state .settings.primaryBaseURL)" = https://mine.example.org ]
  [ "$(state .settings.nscd)" = false ]
}

@test "admin.js setup fails when an account exists that our password does not open" {
  node_setup '{"users":{"admin":"Other123"},"settings":{}}'
  run admin_js setup https://k.example.com <"$PWF"
  [ "$status" -eq 1 ]
  [ "$(state .settings.trustProxy)" = null ]
  node_setup '{"users":{"someone":"Secret123"},"settings":{}}'
  run admin_js setup https://k.example.com <"$PWF"
  [ "$status" -eq 1 ]
  [ "$(state '.users | keys | join(",")')" = someone ]
}

@test "admin.js setup exits 2 when Uptime Kuma finds the password too weak, and creates nothing" {
  node_setup
  printf '%s' 'abcdefgh' >"$PWF"
  run admin_js setup https://k.example.com <"$PWF"
  [ "$status" -eq 2 ]
  [ "$(state '.users | length')" = 0 ]
}

@test "admin.js setup fails when the settings cannot be saved, or without a password or a valid base URL" {
  node_setup '{"users":{},"settings":{},"failSetSettings":true}'
  run admin_js setup https://k.example.com <"$PWF"
  [ "$status" -eq 1 ]
  node_setup
  run admin_js setup https://k.example.com </dev/null
  [ "$status" -eq 1 ]
  [ "$(state '.users | length')" = 0 ]
  for url in '' http://k.example.com 'https://k.example.com/x' 'javascript:alert(1)'; do
    run admin_js setup "$url" <"$PWF"
    [ "$status" -eq 1 ]
  done
  [ "$(state '.users | length')" = 0 ]
}

@test "admin.js need-setup prints true before the admin exists and false after" {
  node_setup
  run admin_js need-setup </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  node_setup '{"users":{"admin":"Secret123"},"settings":{}}'
  run admin_js need-setup </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = false ]
}

@test "admin.js login succeeds only with the admin password, and takes another server URL" {
  node_setup '{"users":{"admin":"Secret123"},"settings":{}}'
  run admin_js login https://k.example.com <"$PWF"
  [ "$status" -eq 0 ]
  grep -qxF 'connect https://k.example.com ["websocket"] reconnection=false' "$UK_FAKE_LOG"
  printf '%s' 'Wrong123' >"$PWF"
  run admin_js login <"$PWF"
  [ "$status" -eq 1 ]
}

@test "admin.js fails when the server refuses the connection or never answers, and on an unknown mode" {
  node_setup '{"users":{},"settings":{},"refuse":true}'
  run admin_js setup https://k.example.com <"$PWF"
  [ "$status" -eq 1 ]
  node_setup '{"users":{},"settings":{},"silent":true}'
  UK_ADMIN_TIMEOUT_MS=300 run admin_js need-setup </dev/null
  [ "$status" -eq 1 ]
  [ -z "$(grep -v '^uptime-kuma-admin:' <<<"$output")" ]
  node_setup
  run admin_js nonsense </dev/null
  [ "$status" -eq 1 ]
}
