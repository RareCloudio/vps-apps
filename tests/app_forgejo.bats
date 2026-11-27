#!/usr/bin/env bats
load test_helper

setup() {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  APP_DIR="$ROOT_DIR/apps/forgejo"
  # shellcheck source=../lib/common.sh
  . "$ROOT_DIR/lib/common.sh"
  # shellcheck source=../lib/compose.sh
  . "$ROOT_DIR/lib/compose.sh"
  # shellcheck source=../lib/images.sh
  . "$ROOT_DIR/lib/images.sh"
  # shellcheck source=../lib/steps.sh
  . "$ROOT_DIR/lib/steps.sh"
  # shellcheck source=../base/50-firewall.sh
  . "$ROOT_DIR/base/50-firewall.sh"
  # shellcheck source=../base/60-proxy.sh
  . "$ROOT_DIR/base/60-proxy.sh"
  # shellcheck source=../apps/forgejo/app.sh
  . "$APP_DIR/app.sh"
  VA_HOST=f.example.com
  export VA_HOST
  DATA="$(p /opt/vps-apps-data/forgejo)"
  PWF="$BATS_TEST_TMPDIR/password"
  printf '%s' 'Secret123' >"$PWF"
  export VA_FORGEJO_WAIT=2 VA_FORGEJO_INTERVAL=0
  # The fake Forgejo's state: F/user (the admin exists), F/pw (its password on the server),
  # F/tokens (one "<id> <name> <token>" line per access token), F/events (every call, in order).
  F="$BATS_TEST_TMPDIR/forgejo"
  mkdir -p "$F"
  : >"$F/events"
  CURL_ARGV="$BATS_TEST_TMPDIR/curl_argv"
  DOCKER_ARGV="$BATS_TEST_TMPDIR/docker_argv"
  CURL_STDIN="$BATS_TEST_TMPDIR/curl_stdin"
  : >"$CURL_ARGV"
  : >"$DOCKER_ARGV"
  fake_forgejo
}

SIGNUP_CLOSED='<div class="ui segment"><p>Registration is disabled. Please contact your site administrator.</p></div>'
SIGNUP_OPEN='<form><input id="user_name" type="text" name="user_name" required><input name="password"></form>'

# fake_forgejo: docker and curl as functions that behave like Forgejo 15 does (per its source):
#   - the CLI inside the container (docker compose ... exec -T forgejo forgejo admin user ...):
#     list --admin prints a tabwriter table, create fails for an existing user and prints the random
#     password on stdout, generate-access-token --raw prints a 40 hex token and refuses a used name;
#   - the loopback HTTP API: /api/healthz, /user/sign_up, PATCH /api/v1/admin/users/<name> (token
#     auth only, 400 for a password under 8 characters), GET /api/v1/user and the token list and
#     delete calls (basic auth with the password the server holds).
# Every other docker call goes to the stub on PATH. Failure injection through files in F.
fake_forgejo() {
  docker() {
    printf 'docker %s\n' "$*" >>"$F/events"
    case "$*" in
      *" exec -T forgejo forgejo admin "*) fake_cli "$@" ;;
      *) command docker "$@" ;;
    esac
  }
  curl() {
    local a prev="" out="" method=GET hdr="" body_in=0 url code
    printf '%s\n' "$@" >>"$CURL_ARGV"
    for a in "$@"; do
      case "$prev" in
        -o) out="$a" ;;
        -X) method="$a" ;;
        -H) [[ "$a" != @* ]] || hdr="$(cat "${a#@}")" ;;
      esac
      [ "$a" != @- ] || body_in=1
      prev="$a"
    done
    url="${*: -1}"
    printf 'curl %s %s\n' "$method" "$url" >>"$F/events"
    if [ "$body_in" = 1 ]; then
      cat >"$CURL_STDIN"
    fi
    case "$url" in
      */api/healthz)
        local n
        n="$(cat "$F/ready_fail" 2>/dev/null || echo 0)"
        if [ "$n" -gt 0 ]; then
          echo $((n - 1)) >"$F/ready_fail"
          return 22
        fi
        [ -n "$out" ] || printf '{\n  "status": "pass",\n  "description": "Forgejo"\n}'
        return 0
        ;;
      */user/sign_up)
        [ ! -e "$F/signup_fail" ] || return 22
        printf '%s' "${SIGNUP_BODY-$SIGNUP_CLOSED}"
        return 0
        ;;
    esac
    code="$(fake_api "$method" "${url#http://127.0.0.1:3000}" "$hdr" "$out")"
    printf '%s' "$code"
  }
}

# fake_cli <docker args...>: the Forgejo CLI inside the container.
fake_cli() {
  local a prev="" name="" id tok
  printf '%s\n' "$@" >>"$DOCKER_ARGV"
  printf '%s\n' "$*" >>"$STUB_TMP/docker.log"
  for a in "$@"; do
    [ "$prev" != --token-name ] || name="$a"
    prev="$a"
  done
  case "$*" in
    *" admin user list --admin")
      [ ! -e "$F/list_fail" ] || return 1
      printf 'ID   Username Email                IsActive\n'
      [ ! -e "$F/user" ] || printf '1    gitadmin admin@f.example.com true\n'
      [ ! -e "$F/other_admin" ] || printf '2    someone  someone@f.example.com true\n'
      ;;
    *" admin user create "*)
      [ ! -e "$F/create_fail" ] || {
        echo "Command error: CreateUser: boom" >&2
        return 1
      }
      if [ -e "$F/user" ]; then
        echo "Command error: CreateUser: user already exists [name: gitadmin]" >&2
        return 1
      fi
      : >"$F/user"
      printf 'R4nd0mPw' >"$F/pw"
      printf "generated random password is 'R4nd0mPw'\nNew user 'gitadmin' has been successfully created!\n"
      ;;
    *" admin user generate-access-token "*)
      [ ! -e "$F/token_fail" ] || return 1
      [ -e "$F/user" ] || {
        echo "Command error: user does not exist" >&2
        return 1
      }
      if [ -n "$name" ] && grep -q " $name " "$F/tokens" 2>/dev/null; then
        echo "Command error: access token name has been used already" >&2
        return 1
      fi
      id=$(($(cat "$F/next_id" 2>/dev/null || echo 0) + 1))
      echo "$id" >"$F/next_id"
      tok="$(printf 'token-%s-%s' "$id" "$name" | sha1sum | cut -c1-40)"
      printf '%s %s %s\n' "$id" "${name:-gitea-admin}" "$tok" >>"$F/tokens"
      [ ! -e "$F/token_garbage" ] || tok="not a token"
      printf '%s\n' "$tok"
      ;;
    *) return 1 ;;
  esac
}

# fake_api <method> <path> <header> <out>: prints the HTTP status, writes the body to <out>.
fake_api() {
  local method="$1" path="$2" hdr="$3" out="$4" pw user="" tok id
  if [[ "$hdr" =~ ^Authorization:\ Basic\ (.+)$ ]]; then
    user="$(printf '%s' "${BASH_REMATCH[1]}" | base64 -d)"
    pw="$(cat "$F/pw" 2>/dev/null; printf x)"
    pw="${pw%x}"
    [ -e "$F/user" ] && [ "$user" = "gitadmin:$pw" ] && user=basic || user=""
  elif [[ "$hdr" =~ ^Authorization:\ token\ ([0-9a-f]{40})$ ]]; then
    tok="${BASH_REMATCH[1]}"
    awk -v t="$tok" '$3 == t { found = 1 } END { exit !found }' "$F/tokens" 2>/dev/null && user=token
  fi
  : >"$out"
  case "$method $path" in
    "PATCH /api/v1/admin/users/gitadmin")
      [ "$user" = token ] || { printf 401; return; }
      if [ -e "$F/patch_fail_once" ]; then
        rm -f "$F/patch_fail_once"
        printf '{"message":"boom"}' >"$out"
        printf 500
        return
      fi
      if [ -n "${PATCH_CODE:-}" ]; then
        printf '%s' "${PATCH_BODY:-}" >"$out"
        printf '%s' "$PATCH_CODE"
        return
      fi
      pw="$(jq -j .password "$CURL_STDIN")"
      if [ "${#pw}" -lt 8 ] || [ -e "$F/patch_reject_once" ]; then
        rm -f "$F/patch_reject_once"
        printf '{"message":"password must be at least 8 characters"}' >"$out"
        printf 400
        return
      fi
      [ "$(jq -r .must_change_password "$CURL_STDIN")" = false ] || { printf 422; return; }
      [ -e "$F/patch_ignored" ] || jq -j .password "$CURL_STDIN" >"$F/pw"
      printf '{"id":1,"login":"gitadmin","is_admin":true}' >"$out"
      printf 200
      ;;
    "GET /api/v1/user")
      [ "$user" = basic ] || { printf 401; return; }
      printf '{"id":1,"login":"gitadmin"}' >"$out"
      printf 200
      ;;
    "GET /api/v1/users/gitadmin/tokens"*)
      [ "$user" = basic ] || { printf 401; return; }
      [ ! -e "$F/list_tokens_fail" ] || { printf 500; return; }
      jq -Rn '[inputs | split(" ") | {id: (.[0] | tonumber), name: .[1]}]' <"$F/tokens" >"$out" 2>/dev/null ||
        printf '[]' >"$out"
      printf 200
      ;;
    "DELETE /api/v1/users/gitadmin/tokens/"*)
      [ "$user" = basic ] || { printf 401; return; }
      [ ! -e "$F/delete_fail" ] || { printf 500; return; }
      id="${path##*/}"
      awk -v i="$id" '$1 != i' "$F/tokens" >"$F/tokens.new"
      mv "$F/tokens.new" "$F/tokens"
      printf 204
      ;;
    *) printf 404 ;;
  esac
}

# The real docker, when the machine has one (the stub is first on PATH): merged config checks.
real_docker() {
  local d
  while IFS= read -r d; do
    [ "$d" = "$BATS_TEST_DIRNAME/stubs" ] && continue
    [ -x "$d/docker" ] && {
      echo "$d/docker"
      return 0
    }
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

# line_no <file> <fixed string>: the number of the first line holding the string.
line_no() {
  grep -nF -- "$2" "$1" | head -n1 | cut -d: -f1
}

# tokens_left: how many access tokens the fake server holds.
tokens_left() {
  if [ -s "$F/tokens" ]; then wc -l <"$F/tokens"; else echo 0; fi
}

server_pw() {
  cat "$F/pw"
}

@test "secrets are generated once and a second run keeps them byte-identical" {
  app_prepare
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  grep -Eq '^FORGEJO_SECRET_KEY=[0-9a-f]{64}$' "$DATA/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  app_prepare
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
}

@test "two installs get different secret keys" {
  app_prepare
  first="$(sed -n 's/^FORGEJO_SECRET_KEY=//p' "$DATA/.env")"
  rm -f "$DATA/.env"
  app_prepare
  [ "$(sed -n 's/^FORGEJO_SECRET_KEY=//p' "$DATA/.env")" != "$first" ]
}

@test "Forgejo is installed from the rootless image of the 15 LTS major, pinned by digest, never latest" {
  app_prepare
  [ "$VA_FORGEJO_IMAGE_REF" = codeberg.org/forgejo/forgejo:15-rootless ]
  grep -qxF 'buildx imagetools inspect codeberg.org/forgejo/forgejo:15-rootless --format {{json .Manifest}}' "$STUB_TMP/docker.log"
  want="$(printf '%s' codeberg.org/forgejo/forgejo:15-rootless | sha256sum | cut -d' ' -f1)"
  grep -qxF "FORGEJO_IMAGE=codeberg.org/forgejo/forgejo@sha256:$want" "$DATA/.env"
  grep -qxF 'FORGEJO_IMAGE_REF=codeberg.org/forgejo/forgejo:15-rootless' "$DATA/.env"
  grep -qF 'image: ${FORGEJO_IMAGE:-codeberg.org/forgejo/forgejo:15-rootless}' "$APP_DIR/compose.yml"
  refute_grep -q ':latest' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl" "$APP_DIR/app.sh"
}

@test "the URL variables use the host, and the site address list is the host" {
  app_prepare
  grep -qxF 'FORGEJO_DOMAIN=f.example.com' "$DATA/.env"
  grep -qxF 'FORGEJO_ROOT_URL=https://f.example.com/' "$DATA/.env"
  grep -qxF 'VA_SITE_ADDRS="f.example.com"' "$DATA/.env"
  grep -qxF 'FORGEJO_REQUIRE_SIGNIN_VIEW=true' "$DATA/.env"
}

@test "valid extra domains from /etc/vps-apps/domains follow the host in VA_SITE_ADDRS, invalid ones are dropped" {
  mkdir -p "$(p /etc/vps-apps)"
  printf 'git.example.org\nnot a domain\n$(id).example.net\nf.example.com\n' >"$(p /etc/vps-apps/domains)"
  app_prepare
  grep -qxF 'VA_SITE_ADDRS="f.example.com git.example.org"' "$DATA/.env"
}

@test "an image that cannot be resolved fails app_prepare and leaves no .env" {
  : >"$STUB_TMP/inspect_fail"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
}

@test "the template substitution is literal for a value with an ampersand and a backslash" {
  resolve_image_digest() { printf '%s\n' 'x/y&z\w@sha256:abc'; }
  app_prepare
  grep -qxF 'FORGEJO_IMAGE=x/y&z\w@sha256:abc' "$DATA/.env"
  refute_grep -qE '@[A-Z0-9_]+@' "$DATA/.env"
}

@test "the compose files are base and setup, then base and expose once the marker exists" {
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

@test "the web installer is locked and signup is closed in compose.yml itself, not from the .env" {
  grep -qxF '      FORGEJO__security__INSTALL_LOCK: "true"' "$APP_DIR/compose.yml"
  grep -qxF '      FORGEJO__service__DISABLE_REGISTRATION: "true"' "$APP_DIR/compose.yml"
  refute_grep -qE 'INSTALL_LOCK|DISABLE_REGISTRATION' "$APP_DIR/env.tmpl" "$APP_DIR/compose.setup.yml" "$APP_DIR/compose.expose.yml"
}

@test "the merged config: Forgejo knows its HTTPS name, its SSH port, and that signup and the installer are off" {
  # The shell's own values would win over the .env in compose; keep the test about the .env.
  unset FORGEJO_REQUIRE_SIGNIN_VIEW
  app_prepare
  key="$(sed -n 's/^FORGEJO_SECRET_KEY=//p' "$DATA/.env")"
  for files in "compose.yml compose.setup.yml" "compose.yml compose.expose.yml"; do
    # shellcheck disable=SC2086 # two file names
    cfg="$(merged_config $files)"
    cfg_env() { jq -r --arg k "$1" '.services.forgejo.environment[$k]' <<<"$cfg"; }
    [ "$(cfg_env FORGEJO__security__INSTALL_LOCK)" = true ]
    [ "$(cfg_env FORGEJO__service__DISABLE_REGISTRATION)" = true ]
    [ "$(cfg_env FORGEJO__service__REQUIRE_SIGNIN_VIEW)" = true ]
    [ "$(cfg_env FORGEJO__security__SECRET_KEY)" = "$key" ]
    [ "$(cfg_env FORGEJO__server__ROOT_URL)" = https://f.example.com/ ]
    [ "$(cfg_env FORGEJO__server__DOMAIN)" = f.example.com ]
    [ "$(cfg_env FORGEJO__server__SSH_DOMAIN)" = f.example.com ]
    [ "$(cfg_env FORGEJO__server__HTTP_PORT)" = 3000 ]
    [ "$(cfg_env FORGEJO__server__START_SSH_SERVER)" = true ]
    [ "$(cfg_env FORGEJO__server__SSH_PORT)" = 2222 ]
    [ "$(cfg_env FORGEJO__server__SSH_LISTEN_PORT)" = 2222 ]
    [ "$(cfg_env FORGEJO__database__DB_TYPE)" = sqlite3 ]
    [ "$(cfg_env FORGEJO__service__ENABLE_REVERSE_PROXY_AUTHENTICATION)" = false ]
    [ "$(cfg_env FORGEJO__service__ENABLE_REVERSE_PROXY_AUTHENTICATION_API)" = false ]
    [ "$(cfg_env FORGEJO__security__REVERSE_PROXY_LIMIT)" = 1 ]
    # The image default before 16.0 trusts every peer ("*"); only the Docker networks may be.
    [ "$(cfg_env FORGEJO__security__REVERSE_PROXY_TRUSTED_PROXIES)" = "127.0.0.0/8,::1/128,172.16.0.0/12,192.168.0.0/16" ]
    [ "$(jq -r '.services.forgejo.user' <<<"$cfg")" = 1000:1000 ]
    [ "$(jq -r '.services.forgejo.volumes[0] | "\(.source):\(.target)"' <<<"$cfg")" = forgejo_data:/var/lib/gitea ]
    [ "$(jq -r '.services | keys | join(",")' <<<"$cfg")" = forgejo ]
  done
}

@test "a REQUIRE_SIGNIN_VIEW set to false in the .env is the one Forgejo gets" {
  unset FORGEJO_REQUIRE_SIGNIN_VIEW
  app_prepare
  sed -i 's/^FORGEJO_REQUIRE_SIGNIN_VIEW=true$/FORGEJO_REQUIRE_SIGNIN_VIEW=false/' "$DATA/.env"
  cfg="$(merged_config compose.yml compose.expose.yml)"
  [ "$(jq -r '.services.forgejo.environment.FORGEJO__service__REQUIRE_SIGNIN_VIEW' <<<"$cfg")" = false ]
  # A line removed from the .env means signed-in only, not open.
  sed -i '/^FORGEJO_REQUIRE_SIGNIN_VIEW=/d' "$DATA/.env"
  cfg="$(merged_config compose.yml compose.expose.yml)"
  [ "$(jq -r '.services.forgejo.environment.FORGEJO__service__REQUIRE_SIGNIN_VIEW' <<<"$cfg")" = true ]
}

@test "compose refuses to start Forgejo without the secret key or the URL settings" {
  app_prepare
  for k in FORGEJO_SECRET_KEY FORGEJO_ROOT_URL FORGEJO_DOMAIN; do
    cp "$DATA/.env" "$BATS_TEST_TMPDIR/env.bak"
    sed -i "/^$k=/d" "$DATA/.env"
    run merged_config compose.yml compose.setup.yml
    [ "$status" -ne 0 ]
    [[ "$output" == *"$k"* ]]
    cp "$BATS_TEST_TMPDIR/env.bak" "$DATA/.env"
  done
}

@test "before exposure only loopback 3000 is published: no SSH port, no caddy label, no proxy network" {
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services.forgejo.ports | length' <<<"$cfg")" = 1 ]
  [ "$(jq -r '.services.forgejo.ports[0] | "\(.host_ip):\(.published):\(.target)"' <<<"$cfg")" = "127.0.0.1:3000:3000" ]
  [ "$(jq -r '.services.forgejo.labels // {} | length' <<<"$cfg")" = 0 ]
  [ "$(jq -r '.services.forgejo.networks | keys | join(",")' <<<"$cfg")" = default ]
  grep -qF '"127.0.0.1:3000:3000"' "$APP_DIR/compose.setup.yml"
  refute_grep -qE 'caddy|2222|web' "$APP_DIR/compose.setup.yml"
  refute_grep -qE '^[[:space:]]*ports:' "$APP_DIR/compose.yml"
}

@test "after exposure: the caddy label on the host, the web network, and only the git SSH port published" {
  app_prepare
  cfg="$(merged_config compose.yml compose.expose.yml)"
  [ "$(jq -r '.services.forgejo.labels.caddy' <<<"$cfg")" = f.example.com ]
  [ "$(jq -r '.services.forgejo.labels["caddy.reverse_proxy"]' <<<"$cfg")" = "{{upstreams 3000}}" ]
  [ "$(jq -r '.services.forgejo.networks | keys | join(",")' <<<"$cfg")" = "default,web" ]
  [ "$(jq -r '.services.forgejo.ports | length' <<<"$cfg")" = 1 ]
  [ "$(jq -r '.services.forgejo.ports[0] | "\(.published):\(.target):\(.protocol)"' <<<"$cfg")" = "2222:2222:tcp" ]
  [ "$(jq -r '.services.forgejo.ports[0].host_ip // ""' <<<"$cfg")" = "" ]
  grep -qF 'caddy: ${VA_SITE_ADDRS:?VA_SITE_ADDRS is not set}' "$APP_DIR/compose.expose.yml"
  refute_grep -qE 'https?://|:443|3000:3000' "$APP_DIR/compose.expose.yml"
}

@test "no compose or env file carries an admin password" {
  # Comments aside, no line of them names a password or the admin.
  run bash -c "cat '$APP_DIR'/compose*.yml '$APP_DIR/env.tmpl' | grep -v '^[[:space:]]*#' | grep -iE 'passw|pwd|admin'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "app_up_setup starts the stack with the setup file" {
  app_prepare
  app_up_setup
  grep -qF "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.setup.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
}

@test "the admin is not 'admin' (a reserved Forgejo name) but gitadmin, with admin@<host>" {
  [ "$VA_FORGEJO_ADMIN" = gitadmin ]
  app_prepare
  app_create_admin "$PWF"
  grep -qF 'admin user create --admin --username gitadmin --email admin@f.example.com --random-password --must-change-password=false' "$STUB_TMP/docker.log"
}

@test "app_create_admin: wait, create, a setup token, the password over the API, a login check, the token removed" {
  app_prepare
  app_create_admin "$PWF"
  [ "$(server_pw)" = Secret123 ]
  [ "$(tokens_left)" -eq 0 ]
  ev="$F/events"
  healthz="$(line_no "$ev" 'curl GET http://127.0.0.1:3000/api/healthz')"
  create="$(line_no "$ev" 'admin user create')"
  token="$(line_no "$ev" 'admin user generate-access-token')"
  patch="$(line_no "$ev" 'curl PATCH http://127.0.0.1:3000/api/v1/admin/users/gitadmin')"
  login="$(line_no "$ev" 'curl GET http://127.0.0.1:3000/api/v1/user')"
  delete="$(line_no "$ev" 'curl DELETE http://127.0.0.1:3000/api/v1/users/gitadmin/tokens/')"
  [ "$healthz" -lt "$create" ]
  [ "$create" -lt "$token" ]
  [ "$token" -lt "$patch" ]
  [ "$patch" -lt "$login" ]
  [ "$login" -lt "$delete" ]
  # Nothing is exposed or restarted while the admin is made: only the loopback stack is used.
  refute_grep -qE 'compose.expose.yml| up -d| down' "$ev"
  # The token can only administer; it is named for this install step.
  grep -qE 'generate-access-token --username gitadmin --token-name vps-apps-setup-[0-9a-f]{8} --scopes write:admin --raw$' "$STUB_TMP/docker.log"
  [ "$(jq -r .must_change_password "$CURL_STDIN")" = false ]
}

@test "the password is sent byte for byte on stdin, and neither it nor the token nor the basic credential is in any argv" {
  app_prepare
  printf '%s' 'P@ss"w\0rd $x`y;1A:%' >"$PWF"
  app_create_admin "$PWF"
  jq -j .password "$CURL_STDIN" >"$BATS_TEST_TMPDIR/sent"
  cmp "$BATS_TEST_TMPDIR/sent" "$PWF"
  cmp <(server_pw) "$PWF"
  grep -qxF -- '--data-binary' "$CURL_ARGV"
  grep -qxF -- '@-' "$CURL_ARGV"
  basic="$({ printf 'gitadmin:'; cat "$PWF"; } | base64 -w0)"
  for argv in "$CURL_ARGV" "$DOCKER_ARGV" "$STUB_TMP/docker.log"; do
    refute_grep -qF 'P@ss' "$argv"
    refute_grep -qF "$basic" "$argv"
  done
  # Every curl call that authenticates names its header file, never the value.
  [ "$(grep -c '^Authorization' "$CURL_ARGV" || true)" -eq 0 ]
}

@test "the setup token never reaches an argv" {
  app_prepare
  # Keep the tokens the fake handed out, though the step deletes them.
  fake_cli_orig="$(declare -f fake_cli)"
  eval "${fake_cli_orig/fake_cli/fake_cli_inner}"
  fake_cli() {
    local out rc=0
    out="$(fake_cli_inner "$@")" || rc=$?
    printf '%s\n' "$out"
    [[ "$*" != *generate-access-token* ]] || printf '%s\n' "$out" >>"$F/handed_out"
    return "$rc"
  }
  app_create_admin "$PWF"
  [ -s "$F/handed_out" ]
  while IFS= read -r tok; do
    [[ "$tok" =~ ^[0-9a-f]{40}$ ]]
    refute_grep -qF "$tok" "$CURL_ARGV" "$DOCKER_ARGV" "$STUB_TMP/docker.log"
  done <"$F/handed_out"
}

@test "the password lands in no .env, no log and no file left behind; the random password is never logged" {
  app_prepare
  app_create_admin "$PWF"
  refute_grep -qF 'Secret123' "$STUB_TMP/docker.log"
  # Nothing under the server root holds the password or the random one the CLI printed.
  refute_grep -rqF 'Secret123' "$VPS_APPS_ROOT"
  refute_grep -rqF 'R4nd0mPw' "$VPS_APPS_ROOT"
  [ "$(find "$DATA" -mindepth 1 ! -name .env | wc -l)" -eq 0 ]
  [ ! -e "$(p /root/vps-apps-credentials.txt)" ]
}

@test "a second run is idempotent: no second user, the same password, no token left" {
  app_prepare
  app_create_admin "$PWF"
  app_create_admin "$PWF"
  [ "$(grep -c 'admin user create' "$STUB_TMP/docker.log")" -eq 1 ]
  [ "$(server_pw)" = Secret123 ]
  [ "$(tokens_left)" -eq 0 ]
}

@test "an admin created by a run that failed later is taken over by the retry, and every setup token is removed" {
  app_prepare
  : >"$F/patch_fail_once"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  # The user exists with the random password only; the token of that run is still there.
  [ "$(server_pw)" = R4nd0mPw ]
  [ "$(tokens_left)" -eq 1 ]
  app_create_admin "$PWF"
  [ "$(grep -c 'admin user create' "$STUB_TMP/docker.log")" -eq 1 ]
  [ "$(server_pw)" = Secret123 ]
  [ "$(tokens_left)" -eq 0 ]
  # Each run asked for a token of its own name.
  names="$(grep -oE 'token-name [^ ]+' "$STUB_TMP/docker.log" | sort -u | wc -l)"
  [ "$names" -eq 2 ]
}

@test "a token not made by the setup is kept" {
  app_prepare
  : >"$F/user"
  printf 'x' >"$F/pw"
  printf '1 my-ci-token %s\n' "$(printf 'a%.0s' $(seq 40))" >"$F/tokens"
  echo 1 >"$F/next_id"
  app_create_admin "$PWF"
  [ "$(tokens_left)" -eq 1 ]
  grep -q ' my-ci-token ' "$F/tokens"
}

@test "every failing admin call fails the step" {
  app_prepare
  : >"$F/create_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  refute_grep -q generate-access-token "$STUB_TMP/docker.log"
  rm -f "$F/create_fail"

  : >"$STUB_TMP/docker.log"
  : >"$F/list_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  refute_grep -q 'admin user create' "$STUB_TMP/docker.log"
  rm -f "$F/list_fail"

  : >"$F/events"
  : >"$F/token_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  refute_grep -q 'curl PATCH' "$F/events"
  rm -f "$F/token_fail"

  : >"$F/events"
  : >"$F/token_garbage"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  refute_grep -q 'curl PATCH' "$F/events"
  rm -f "$F/token_garbage"

  PATCH_CODE=500 PATCH_BODY='boom' run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  PATCH_CODE=200 PATCH_BODY='{"login":"someone"}' run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  PATCH_CODE=200 PATCH_BODY='Forgejo is starting' run app_create_admin "$PWF"
  [ "$status" -ne 0 ]

  # The server answers 200 but the password did not change: the login check catches it.
  : >"$F/patch_ignored"
  : >"$F/events"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  grep -qF 'the admin cannot log in with the password just set' "$(p /var/log/vps-apps-install.log)"
  refute_grep -qF '/api/v1/users/gitadmin/tokens' "$F/events"
  rm -f "$F/patch_ignored"

  : >"$F/list_tokens_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  rm -f "$F/list_tokens_fail"

  : >"$F/delete_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  rm -f "$F/delete_fail"

  # Once every call works again, the retry succeeds and leaves no token.
  app_create_admin "$PWF"
  [ "$(server_pw)" = Secret123 ]
  [ "$(tokens_left)" -eq 0 ]
}

@test "a user that exists but is no admin is not taken over" {
  app_prepare
  # The list shows another admin only; the create call finds gitadmin taken.
  : >"$F/other_admin"
  fake_cli_orig="$(declare -f fake_cli)"
  eval "${fake_cli_orig/fake_cli/fake_cli_inner}"
  fake_cli() {
    if [[ "$*" == *" admin user create "* ]]; then
      echo "Command error: CreateUser: user already exists [name: gitadmin]" >&2
      return 1
    fi
    fake_cli_inner "$@"
  }
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  refute_grep -q generate-access-token "$STUB_TMP/docker.log"
}

@test "app_create_admin waits for Forgejo, bounded, and fails when it never answers" {
  app_prepare
  echo 999 >"$F/ready_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  refute_grep -q 'admin user' "$STUB_TMP/docker.log"
  grep -qxF -- '--max-time' "$CURL_ARGV"
  grep -qxF 30 "$CURL_ARGV"
}

@test "the health probe failing twice is waited out before the first CLI call" {
  app_prepare
  echo 2 >"$F/ready_fail"
  app_create_admin "$PWF"
  [ "$(grep -c 'api/healthz' "$F/events")" -eq 3 ]
  [ "$(server_pw)" = Secret123 ]
}

@test "every loopback call has a 30 second cap" {
  app_prepare
  app_create_admin "$PWF"
  [ "$(grep -cxF -- '--max-time' "$CURL_ARGV")" -eq "$(grep -c '^curl ' "$F/events")" ]
  [ "$(grep -cxF 30 "$CURL_ARGV")" -eq "$(grep -c '^curl ' "$F/events")" ]
}

@test "passwords that meet Forgejo's rule are set as they are, from 8 characters up" {
  app_prepare
  for good in Abcdefg1 alllowercase 'A1$(printf x)' "A1$(printf 'x%.0s' $(seq 62))" "$(printf 'y%.0s' $(seq 255))"; do
    printf '%s' "$good" >"$PWF"
    app_create_admin "$PWF"
    [ "$(server_pw)" = "$good" ]
    [ ! -e "$(p /root/vps-apps-credentials.txt)" ]
  done
}

@test "a password that breaks Forgejo's rule is replaced by a generated one in the credentials file" {
  app_prepare
  for bad in short Abc1234 'Pässword1x' $'Tab\tPass1word' $'Pass\nword1X' "$(printf 'z%.0s' $(seq 256))"; do
    rm -f "$(p /root/vps-apps-credentials.txt)"
    printf '%s' "$bad" >"$PWF"
    app_create_admin "$PWF"
    cred="$(p /root/vps-apps-credentials.txt)"
    [ "$(stat -c %a "$cred")" = 600 ]
    sent="$(server_pw)"
    [ "$sent" != "$bad" ]
    [ "${#sent}" -ge 8 ]
    grep -qxF "Password: $sent" "$cred"
    grep -qxF 'Username: gitadmin' "$cred"
  done
}

@test "a 400 from Forgejo on the chosen password triggers the generated one and a second call" {
  app_prepare
  : >"$F/patch_reject_once"
  app_create_admin "$PWF"
  cred="$(p /root/vps-apps-credentials.txt)"
  [ "$(stat -c %a "$cred")" = 600 ]
  [ "$(server_pw)" != Secret123 ]
  grep -qxF "Password: $(server_pw)" "$cred"
  [ "$(grep -c 'curl PATCH' "$F/events")" -eq 2 ]
  [ "$(tokens_left)" -eq 0 ]
}

@test "a retry after the fallback keeps the credentials file and the password in it" {
  app_prepare
  printf '%s' short >"$PWF"
  app_create_admin "$PWF"
  cp "$(p /root/vps-apps-credentials.txt)" "$BATS_TEST_TMPDIR/cred1"
  first="$(server_pw)"
  app_create_admin "$PWF"
  cmp "$(p /root/vps-apps-credentials.txt)" "$BATS_TEST_TMPDIR/cred1"
  [ "$(server_pw)" = "$first" ]
}

@test "app_expose brings the setup stack up, checks the admin and the closed signup, opens 2222, then exposes" {
  app_prepare
  app_create_admin "$PWF"
  : >"$F/events"
  app_expose
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
  ev="$F/events"
  setup="$(line_no "$ev" "compose.setup.yml --env-file $DATA/.env up -d")"
  healthz="$(line_no "$ev" 'curl GET http://127.0.0.1:3000/api/healthz')"
  list="$(line_no "$ev" 'admin user list --admin')"
  signup="$(line_no "$ev" 'curl GET http://127.0.0.1:3000/user/sign_up')"
  expose="$(line_no "$ev" "compose.expose.yml --env-file $DATA/.env up -d")"
  [ "$setup" -lt "$healthz" ]
  [ "$healthz" -lt "$list" ]
  [ "$list" -lt "$signup" ]
  [ "$signup" -lt "$expose" ]
  grep -qxF 2222/tcp "$(p /etc/vps-apps/open-ports)"
}

@test "app_expose refuses while the admin does not exist, and changes nothing" {
  app_prepare
  : >"$STUB_TMP/docker.log"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ ! -e "$(p /var/lib/vps-apps/site-mode)" ]
  [ ! -e "$(p /etc/vps-apps/open-ports)" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
}

@test "app_expose refuses when the admin list cannot be read" {
  app_prepare
  app_create_admin "$PWF"
  : >"$F/list_fail"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
}

@test "app_expose refuses while the signup page offers a form, or cannot be read" {
  app_prepare
  app_create_admin "$PWF"
  SIGNUP_BODY="$SIGNUP_OPEN" run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  SIGNUP_BODY="$SIGNUP_CLOSED$SIGNUP_OPEN" run app_expose
  [ "$status" -ne 0 ]
  SIGNUP_BODY='' run app_expose
  [ "$status" -ne 0 ]
  : >"$F/signup_fail"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ ! -e "$(p /var/lib/vps-apps/site-mode)" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
}

@test "app_expose fails without exposing when Forgejo never becomes ready after the setup stack is up" {
  app_prepare
  app_create_admin "$PWF"
  echo 999 >"$F/ready_fail"
  : >"$STUB_TMP/docker.log"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
}

@test "the SSH port goes through the firewall's open-ports file, with every listed port kept" {
  app_prepare
  app_create_admin "$PWF"
  mkdir -p "$(p /etc/vps-apps)"
  printf '5432/tcp\n' >"$(p /etc/vps-apps/open-ports)"
  app_expose
  [ "$(cat "$(p /etc/vps-apps/open-ports)")" = $'5432/tcp\n2222/tcp' ]
  grep -qxF '    tcp dport 2222 accept' "$(p /etc/vps-apps/vps-apps.nft)"
  grep -qF -- '--ctorigdstport 2222 -j RETURN' "$(p /etc/vps-apps/docker-user.v4)"
}

@test "an SSH port already open is not added twice" {
  app_prepare
  app_create_admin "$PWF"
  mkdir -p "$(p /etc/vps-apps)"
  printf '2222/tcp\n' >"$(p /etc/vps-apps/open-ports)"
  app_expose
  [ "$(cat "$(p /etc/vps-apps/open-ports)")" = 2222/tcp ]
}

@test "a firewall that cannot open the SSH port stops the exposure" {
  app_prepare
  app_create_admin "$PWF"
  : >"$STUB_TMP/fail_nft_check"
  : >"$STUB_TMP/docker.log"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
  refute_grep -qxF 2222/tcp "$(p /etc/vps-apps/open-ports)"
  # No candidate file is left next to open-ports.
  [ "$(find "$(p /etc/vps-apps)" -name '.open-ports.*' | wc -l)" -eq 0 ]
}

@test "a failed start in app_expose takes the stack down, drops the marker and shows the failed page" {
  app_prepare
  app_create_admin "$PWF"
  eval "$(declare -f docker | sed '1s/docker/docker_fake/')"
  docker() {
    if [[ "$*" == *compose.expose.yml*" up"* ]]; then
      printf '%s\n' "$*" >>"$STUB_TMP/docker_calls"
      return 1
    fi
    [[ "$*" != *" down"* ]] || printf '%s\n' "$*" >>"$STUB_TMP/docker_calls"
    docker_fake "$@"
  }
  run app_expose
  [ "$status" -ne 0 ]
  grep -q ' down' "$STUB_TMP/docker_calls"
  [ ! -e "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
}

@test "a failed expose followed by a retry recovers" {
  app_prepare
  app_create_admin "$PWF"
  eval "$(declare -f docker | sed '1s/docker/docker_fake/')"
  docker() {
    if [[ "$*" == *compose.expose.yml*" up"* ]] && [ ! -e "$BATS_TEST_TMPDIR/expose_failed_once" ]; then
      : >"$BATS_TEST_TMPDIR/expose_failed_once"
      return 1
    fi
    docker_fake "$@"
  }
  run app_expose
  [ "$status" -ne 0 ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
  : >"$F/events"
  app_expose
  grep -q "compose.setup.yml --env-file $DATA/.env up -d" "$F/events"
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
  [ "$(grep -c 2222/tcp "$(p /etc/vps-apps/open-ports)")" -eq 1 ]
}

@test "app_ready_check needs a passing health answer over HTTPS on the server's own name" {
  curl() {
    printf '%s\n' "$*" >"$BATS_TEST_TMPDIR/curl_args"
    printf '{\n  "status": "pass",\n  "description": "Forgejo"\n}'
  }
  app_ready_check
  grep -qF -- '--resolve f.example.com:443:127.0.0.1 https://f.example.com/api/healthz' "$BATS_TEST_TMPDIR/curl_args"
  refute_grep -qE -- '(^| )(-k|--insecure)( |$)' "$BATS_TEST_TMPDIR/curl_args"
  curl() { printf '{"status": "fail"}'; }
  run app_ready_check
  [ "$status" -ne 0 ]
  curl() {
    printf '{"status": "pass"}'
    return 60
  }
  run app_ready_check
  [ "$status" -ne 0 ]
  curl() { printf '<html>Bad gateway</html>'; }
  run app_ready_check
  [ "$status" -ne 0 ]
}

# urls_are <host>: the Forgejo URL variables in the .env name this host.
urls_are() {
  grep -qxF "FORGEJO_DOMAIN=$1" "$DATA/.env"
  grep -qxF "FORGEJO_ROOT_URL=https://$1/" "$DATA/.env"
}

@test "app_domain_added serves both names and moves the URL and SSH name to the new domain" {
  app_prepare
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  mkdir -p "$(p /etc/vps-apps)"
  printf 'git.example.org\n' >"$(p /etc/vps-apps/domains)"
  : >"$STUB_TMP/docker.log"
  app_domain_added git.example.org
  grep -qxF 'VA_SITE_ADDRS="f.example.com git.example.org"' "$DATA/.env"
  urls_are git.example.org
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  diff <(grep -vE '^(VA_SITE_ADDRS|FORGEJO_DOMAIN|FORGEJO_ROOT_URL)=' "$BATS_TEST_TMPDIR/before") \
    <(grep -vE '^(VA_SITE_ADDRS|FORGEJO_DOMAIN|FORGEJO_ROOT_URL)=' "$DATA/.env")
  grep -q 'compose .* up -d' "$STUB_TMP/docker.log"
}

@test "each domain added later becomes the main address; the server's own name stays served" {
  app_prepare
  mkdir -p "$(p /etc/vps-apps)"
  printf 'one.example.org\n' >"$(p /etc/vps-apps/domains)"
  app_domain_added one.example.org
  printf 'one.example.org\ntwo.example.org\n' >"$(p /etc/vps-apps/domains)"
  app_domain_added two.example.org
  grep -qxF 'VA_SITE_ADDRS="f.example.com one.example.org two.example.org"' "$DATA/.env"
  urls_are two.example.org
}

@test "an invalid domain given to app_domain_added leaves the URL variables on the host" {
  app_prepare
  app_domain_added 'bad domain;id'
  urls_are f.example.com
}

@test "Forgejo takes extra domains: no app_domain_check" {
  run declare -F app_domain_check
  [ "$status" -ne 0 ]
}

@test "rc update re-resolves the 15-rootless tag, so Forgejo stays on its major, and keeps the secret key" {
  run declare -F app_update_env
  [ "$status" -ne 0 ]
  run declare -F app_fill_env
  [ "$status" -ne 0 ]
  app_prepare
  sed -i "s#^FORGEJO_IMAGE=.*#FORGEJO_IMAGE=codeberg.org/forgejo/forgejo@sha256:$(printf '1%.0s' $(seq 64))#" "$DATA/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  resolve_env_images "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  want="$(printf '%s' codeberg.org/forgejo/forgejo:15-rootless | sha256sum | cut -d' ' -f1)"
  grep -qxF "FORGEJO_IMAGE=codeberg.org/forgejo/forgejo@sha256:$want" "$BATS_TEST_TMPDIR/out"
  diff <(grep -v '^FORGEJO_IMAGE=' "$BATS_TEST_TMPDIR/before") <(grep -v '^FORGEJO_IMAGE=' "$BATS_TEST_TMPDIR/out")
}
