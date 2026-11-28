#!/usr/bin/env bats
# The ghrunner app, and the parts it shares with glrunner (apps/_runner-common): the registration
# page, its login, and the root unit that registers the runner. tests/app_glrunner.bats covers what
# differs for GitLab.
load test_helper

# Token prefixes kept out of the fixtures' text, so the CI gitleaks step does not read a test
# token as a real one: the fixtures that carry a prefix are built from these at run time.
GLRT=glrt- GLPAT=glpat- GRRT=GR1348941

setup() {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  APP_DIR="$ROOT_DIR/apps/ghrunner"
  COMMON_DIR="$ROOT_DIR/apps/_runner-common"
  # shellcheck source=../lib/common.sh
  . "$ROOT_DIR/lib/common.sh"
  # shellcheck source=../lib/compose.sh
  . "$ROOT_DIR/lib/compose.sh"
  # shellcheck source=../lib/images.sh
  . "$ROOT_DIR/lib/images.sh"
  # shellcheck source=../lib/steps.sh
  . "$ROOT_DIR/lib/steps.sh"
  # shellcheck source=../lib/apt.sh
  . "$ROOT_DIR/lib/apt.sh"
  # shellcheck source=../base/60-proxy.sh
  . "$ROOT_DIR/base/60-proxy.sh"
  # shellcheck source=../apps/ghrunner/app.sh
  . "$APP_DIR/app.sh"
  VA_HOST=ghrunner-ab12cd.example.com
  export VA_HOST
  DATA="$(p /opt/vps-apps-data/ghrunner)"
  RUN="$(p /run/vps-apps-ghrunner)"
  RDIR="$(p /home/ghrunner/actions-runner)"
  F="$BATS_TEST_TMPDIR/f"
  mkdir -p "$F"
  PWF="$BATS_TEST_TMPDIR/password"
  printf '%s' 'Secret123' >"$PWF"
  VA_PASSWORD_FILE="$PWF"
  TOKEN="$(printf '%s%s' AABBCCDDEEFF GGHHIIJJKKLLMM0)"
  OTHER_TOKEN="$(printf '%s%s' ZZYYXXWWVVU UTTSSRRQQPP0)"
  fake_host
  mkdir -p "$(p /opt/vps-apps-data/proxy)"
  CADDY_IMAGE="lucaslorentz/caddy-docker-proxy@sha256:$(printf 'c%.0s' $(seq 64))"
  printf 'CADDY_IMAGE=%s\nCADDY_IMAGE_REF=lucaslorentz/caddy-docker-proxy:2.13.1-alpine\n' "$CADDY_IMAGE" \
    >"$(p /opt/vps-apps-data/proxy/.env)"
}

teardown() {
  if [ -n "${PAGE_PID:-}" ]; then
    kill "$PAGE_PID" 2>/dev/null || true
    wait "$PAGE_PID" 2>/dev/null || true
  fi
}

# fake_host: users, ownership and privilege changes as functions, since the tests do not run as
# root. useradd records a user (all of them get the test's own uid and gid, so the files a test
# writes belong to "the page user"); setpriv logs its argv and runs the command after --.
fake_host() {
  USERS="$BATS_TEST_TMPDIR/users"
  mkdir -p "$USERS"
  ME_UID="$(command id -u)"
  ME_GID="$(command id -g)"
  useradd() {
    printf 'useradd %s\n' "$*" >>"$STUB_TMP/calls.log"
    : >"$USERS/${*: -1}"
  }
  usermod() { printf 'usermod %s\n' "$*" >>"$STUB_TMP/calls.log"; }
  chown() { printf 'chown %s\n' "$*" >>"$STUB_TMP/calls.log"; }
  id() {
    if [ "$#" -eq 2 ] && { [ "$1" = -u ] || [ "$1" = -g ]; }; then
      [ -e "$USERS/$2" ] || return 1
      if [ "$1" = -u ]; then echo "$ME_UID"; else echo "$ME_GID"; fi
      return 0
    fi
    command id "$@"
  }
  setpriv() {
    printf 'setpriv %s\n' "$*" >>"$STUB_TMP/setpriv.log"
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
    shift
    "$@"
  }
}

FAKE_HASH='$2a$14$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0'

# stub_docker: "docker run" (the hash-password call) keeps its stdin in $F/hash_stdin and prints
# HASH_OUT (FAKE_HASH), or fails when $F/hash_fail exists; every other call goes to the stub on
# PATH, which logs it.
stub_docker() {
  docker() {
    if [ "${1:-}" = run ]; then
      printf '%s\n' "$*" >>"$STUB_TMP/docker.log"
      cat >"$F/hash_stdin"
      [ ! -e "$F/hash_fail" ] || return 1
      printf '%s\n' "${HASH_OUT-$FAKE_HASH}"
      return 0
    fi
    command docker "$@"
  }
}

# make_runner_tarball: a fake actions/runner release in $TARBALL, its SHA-256 in RUNNER_SHA. Its
# config.sh records its argv, the token it got from its environment, HOME and TMPDIR in $F, prints
# a line with a piece of the token, and fails like a refused token when $F/config_fail exists.
make_runner_tarball() {
  local src="$BATS_TEST_TMPDIR/runner-src"
  mkdir -p "$src/bin"
  cat >"$src/config.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$F/config_argv"
printf '%s' "\${ACTIONS_RUNNER_INPUT_TOKEN-}" >"$F/config_token"
printf '%s' "\$HOME" >"$F/config_home"
printf '%s' "\${TMPDIR-}" >"$F/config_tmpdir"
cd "\$(dirname "\$0")"
if [ -e "$F/config_fail" ]; then
  echo "Http response code: NotFound from 'POST https://api.github.com/actions/runner-registration' (\${ACTIONS_RUNNER_INPUT_TOKEN:2:12})"
  exit 1
fi
echo "Runner successfully added for \${ACTIONS_RUNNER_INPUT_TOKEN-}"
echo '{"agentName":"x"}' >.runner
: >.credentials
: >.credentials_rsaparams
SH
  printf '#!/bin/sh\n[ ! -e "%s/listener_fail" ] || exit 1\necho 2.338.2\n' "$F" >"$src/bin/Runner.Listener"
  printf '#!/bin/bash\nexit 0\n' >"$src/bin/runsvc.sh"
  chmod +x "$src/config.sh" "$src/bin/Runner.Listener" "$src/bin/runsvc.sh"
  TARBALL="$BATS_TEST_TMPDIR/runner.tar.gz"
  tar -czf "$TARBALL" -C "$src" .
  RUNNER_SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
}

# release_json [version] [asset digest] [listed sha]: GitHub's answer for the latest release.
release_json() {
  jq -n --arg v "${1:-2.338.2}" --arg d "${2-sha256:$RUNNER_SHA}" --arg b "${3-$RUNNER_SHA}" '{
    tag_name: ("v" + $v), draft: false, prerelease: false,
    body: ("## SHA-256 Checksums\n<!-- BEGIN SHA linux-x64 -->" + $b + "<!-- END SHA linux-x64 -->\n"),
    assets: [{name: ("actions-runner-linux-x64-" + $v + ".tar.gz"),
      browser_download_url: ("https://github.com/actions/runner/releases/download/v" + $v + "/actions-runner-linux-x64-" + $v + ".tar.gz"),
      digest: $d}]}
    | if $d == "" then .assets[0] |= del(.digest) else . end'
}

# stub_curl: the GitHub API answers RELEASE_BODY (release_json), the download writes TARBALL to the
# -o target; $F/api_fail and $F/dl_fail make them fail. Every call is logged in $F/curl_calls.
stub_curl() {
  curl() {
    local out="" a prev=""
    printf '%s\n' "$*" >>"$F/curl_calls"
    for a in "$@"; do
      [ "$prev" = -o ] && out="$a"
      prev="$a"
    done
    case "$*" in
      *api.github.com/repos/actions/runner/releases/latest*)
        [ ! -e "$F/api_fail" ] || return 22
        printf '%s' "${RELEASE_BODY-$(release_json)}"
        ;;
      *github.com/actions/runner/releases/download/*)
        [ ! -e "$F/dl_fail" ] || return 22
        cp "$TARBALL" "$out"
        ;;
    esac
    return 0
  }
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

# label <cfg> <name>: a label of the page as Docker gets it (compose config writes $ as $$).
label() {
  jq -r --arg l "$2" '.services.page.labels[$l] // "" | gsub("\\$\\$"; "$")' <<<"$1"
}

# prepared: app_prepare with the stubs in place.
prepared() {
  stub_docker
  app_prepare
}

# with_login: app_prepare and app_create_admin.
with_login() {
  prepared
  app_create_admin "$PWF"
}

@test "app_prepare writes a 0600 .env with the pinned page image, its ref, the page user and the host" {
  prepared
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  want="$(printf '%s' python:3.14-alpine | sha256sum | cut -d' ' -f1)"
  grep -qxF "PAGE_IMAGE=python@sha256:$want" "$DATA/.env"
  grep -qxF 'PAGE_IMAGE_REF=python:3.14-alpine' "$DATA/.env"
  grep -qxF "PAGE_UID=$ME_UID" "$DATA/.env"
  grep -qxF "PAGE_GID=$ME_GID" "$DATA/.env"
  grep -qxF 'VA_SITE_ADDRS="ghrunner-ab12cd.example.com"' "$DATA/.env"
  refute_grep -q '@[A-Z_]*@' "$DATA/.env"
}

@test "a second app_prepare keeps the .env byte for byte, login hash included, and resolves nothing" {
  with_login
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  : >"$STUB_TMP/docker.log"
  app_prepare
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  refute_grep -q imagetools "$STUB_TMP/docker.log"
}

@test "the page image is python 3.14 on Alpine, resolved and pinned by digest, never latest" {
  prepared
  [ "$VA_RUNNER_PAGE_IMAGE_REF" = python:3.14-alpine ]
  grep -qxF 'buildx imagetools inspect python:3.14-alpine --format {{json .Manifest}}' "$STUB_TMP/docker.log"
  grep -qF 'image: ${PAGE_IMAGE:-python:3.14-alpine}' "$APP_DIR/compose.yml"
  refute_grep -qE ':latest|python:3-' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl" "$APP_DIR/app.sh" "$COMMON_DIR/runner.sh"
}

@test "an image that cannot be resolved fails app_prepare and leaves no .env" {
  stub_docker
  : >"$STUB_TMP/inspect_fail"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
}

@test "VA_SITE_ADDRS has the host, then the valid extra domains; invalid ones are dropped" {
  mkdir -p "$(p /etc/vps-apps)"
  printf 'ci.example.org\nnot a domain\n$(id).example.net\nghrunner-ab12cd.example.com\n' >"$(p /etc/vps-apps/domains)"
  prepared
  grep -qxF 'VA_SITE_ADDRS="ghrunner-ab12cd.example.com ci.example.org"' "$DATA/.env"
}

@test "app_prepare makes the page user and the runner user, the runner in the docker group, nobody with a login shell" {
  prepared
  grep -qxF 'useradd --system --user-group --shell /usr/sbin/nologin --no-create-home --home-dir /nonexistent vps-apps-page' "$STUB_TMP/calls.log"
  grep -qxF 'useradd --system --user-group --shell /usr/sbin/nologin --create-home --home-dir /home/ghrunner ghrunner' "$STUB_TMP/calls.log"
  grep -qxF 'usermod -aG docker ghrunner' "$STUB_TMP/calls.log"
  # The page user is not in the docker group.
  refute_grep -q 'usermod.*vps-apps-page' "$STUB_TMP/calls.log"
  # A second run makes no user again.
  : >"$STUB_TMP/calls.log"
  app_prepare
  refute_grep -q useradd "$STUB_TMP/calls.log"
}

@test "the inbox belongs to the page user and the work directory to root, both 0700 on /run, now and at every boot" {
  prepared
  [ "$(stat -c %a "$RUN")" = 755 ]
  [ "$(stat -c %a "$RUN/inbox")" = 700 ]
  [ "$(stat -c %a "$RUN/work")" = 700 ]
  grep -qxF "chown $ME_UID:$ME_GID $RUN/inbox" "$STUB_TMP/calls.log"
  conf="$(p /etc/tmpfiles.d/vps-apps-ghrunner.conf)"
  grep -qxF 'd /run/vps-apps-ghrunner 0755 root root -' "$conf"
  grep -qxF 'd /run/vps-apps-ghrunner/inbox 0700 vps-apps-page vps-apps-page -' "$conf"
  grep -qxF 'd /run/vps-apps-ghrunner/work 0700 root root -' "$conf"
}

@test "the status starts as not registered, readable by the page, and a second run keeps it" {
  prepared
  st="$DATA/status/status.json"
  [ "$(stat -c %a "$DATA/status")" = 755 ]
  [ "$(stat -c %a "$st")" = 644 ]
  [ "$(jq -r .state "$st")" = none ]
  [ "$(jq -r .message "$st")" = "Not registered yet." ]
  [ "$(jq -r .url "$st")" = "" ]
  runner_write_status registered "Registered." https://github.com/octo/repo
  app_prepare
  [ "$(jq -r .state "$st")" = registered ]
}

@test "the path unit watches the inbox request and starts the root register service, enabled at once" {
  prepared
  path="$(p /etc/systemd/system/vps-apps-ghrunner-register.path)"
  svc="$(p /etc/systemd/system/vps-apps-ghrunner-register.service)"
  grep -qxF 'PathExists=/run/vps-apps-ghrunner/inbox/request' "$path"
  grep -qxF 'Unit=vps-apps-ghrunner-register.service' "$path"
  grep -qxF 'Type=oneshot' "$svc"
  grep -qxF 'ExecStart=/bin/bash /opt/vps-apps/current/apps/_runner-common/register.sh ghrunner' "$svc"
  grep -qxF 'Environment=TMPDIR=/run/vps-apps-ghrunner/work' "$svc"
  grep -qxF 'UMask=0077' "$svc"
  # Root: the service names no other user.
  refute_grep -q '^User=' "$svc"
  grep -qxF 'daemon-reload' "$STUB_TMP/systemctl.log"
  grep -qxF 'enable --now vps-apps-ghrunner-register.path' "$STUB_TMP/systemctl.log"
  [ -f "$COMMON_DIR/register.sh" ]
}

@test "the runner's unit is the one svc.sh writes, as ghrunner, and is not enabled before a registration" {
  prepared
  unit="$(p /etc/systemd/system/vps-apps-ghrunner.service)"
  grep -qxF 'ExecStart=/home/ghrunner/actions-runner/runsvc.sh' "$unit"
  grep -qxF 'User=ghrunner' "$unit"
  grep -qxF 'WorkingDirectory=/home/ghrunner/actions-runner' "$unit"
  grep -qxF 'KillMode=process' "$unit"
  grep -qxF 'KillSignal=SIGTERM' "$unit"
  grep -qxF 'TimeoutStopSec=5min' "$unit"
  refute_grep -q 'vps-apps-ghrunner.service' "$STUB_TMP/systemctl.log"
}

@test "the compose files are the base one, then the base and expose ones once the marker exists" {
  prepared
  run app_compose_files
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "$APP_DIR/compose.yml" ]
  : >"$DATA/exposed"
  run app_compose_files
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "$APP_DIR/compose.expose.yml" ]
}

@test "before exposure the page publishes nothing, has no label and is not on the proxy network" {
  prepared
  refute_grep -qi 'caddy' "$APP_DIR/compose.yml"
  refute_grep -qE '^\s+ports:|external: true|^\s+- web$' "$APP_DIR/compose.yml"
  cfg="$(merged_config compose.yml)"
  [ "$(jq -r '.services | keys | join(",")' <<<"$cfg")" = page ]
  [ "$(jq -r '.services.page.ports // [] | length' <<<"$cfg")" = 0 ]
  [ "$(jq -r '.services.page.labels // {} | length' <<<"$cfg")" = 0 ]
  [ "$(jq -r '.services.page.networks | keys | join(",")' <<<"$cfg")" = default ]
}

@test "the page runs unprivileged: the page user, read-only root, no capabilities, no new privileges, small limits" {
  prepared
  cfg="$(merged_config compose.yml)"
  [ "$(jq -r .services.page.user <<<"$cfg")" = "$ME_UID:$ME_GID" ]
  [ "$(jq -r .services.page.read_only <<<"$cfg")" = true ]
  [ "$(jq -r '.services.page.cap_drop | join(",")' <<<"$cfg")" = ALL ]
  [ "$(jq -r '.services.page.security_opt | join(",")' <<<"$cfg")" = no-new-privileges:true ]
  [ "$(jq -r .services.page.mem_limit <<<"$cfg")" = 67108864 ]
  [ "$(jq -r .services.page.pids_limit <<<"$cfg")" = 32 ]
  [ "$(jq -r '.services.page.privileged // false' <<<"$cfg")" = false ]
  [ "$(jq -r '.services.page.environment.RUNNER_KIND' <<<"$cfg")" = github ]
  [ "$(jq -r '.services.page.command | join(" ")' <<<"$cfg")" = "python3 -I /app/page.py" ]
}

@test "the page has no Docker socket: its only mounts are page.py and the status read-only, and the inbox" {
  prepared
  refute_grep -q 'docker.sock' "$APP_DIR/compose.yml" "$APP_DIR/compose.expose.yml"
  cfg="$(merged_config compose.yml)"
  [ "$(jq -r '.services.page.volumes | length' <<<"$cfg")" = 3 ]
  src="$(jq -r '.services.page.volumes[0].source' <<<"$cfg")"
  [[ "${src//\\//}" == */apps/_runner-common/page.py ]]
  [ "$(jq -r '.services.page.volumes[0] | "\(.target) \(.read_only)"' <<<"$cfg")" = "/app/page.py true" ]
  [ "$(jq -r '.services.page.volumes[1] | "\(.source) \(.target) \(.read_only // false)"' <<<"$cfg")" = \
    "/run/vps-apps-ghrunner/inbox /inbox false" ]
  [ "$(jq -r '.services.page.volumes[2] | "\(.source) \(.target) \(.read_only)"' <<<"$cfg")" = \
    "/opt/vps-apps-data/ghrunner/status /status true" ]
  # A missing host path fails the start instead of being made as root.
  [ "$(jq -r '[.services.page.volumes[].bind.create_host_path] | unique | join(",")' <<<"$cfg")" = false ]
  [ "$(jq -r '[.services.page.volumes[].source | select(test("docker"))] | length' <<<"$cfg")" = 0 ]
}

@test "after exposure the page is on the proxy network only, behind basic auth as admin, and publishes no port" {
  mkdir -p "$(p /etc/vps-apps)"
  printf 'ci.example.org\n' >"$(p /etc/vps-apps/domains)"
  with_login
  cfg="$(merged_config compose.yml compose.expose.yml)"
  [ "$(jq -r '.services.page.networks | keys | join(",")' <<<"$cfg")" = web ]
  [ "$(jq -r '.networks.web.external' <<<"$cfg")" = true ]
  [ "$(label "$cfg" caddy)" = "ghrunner-ab12cd.example.com ci.example.org" ]
  [ "$(label "$cfg" caddy.basic_auth.admin)" = "$FAKE_HASH" ]
  [ "$(label "$cfg" caddy.reverse_proxy)" = "{{upstreams 8080}}" ]
  # The login stops at Caddy: the page never sees the password.
  [ "$(label "$cfg" caddy.reverse_proxy.header_up)" = "-Authorization" ]
  [ "$(jq -r '.services.page.labels | keys | join(",")' <<<"$cfg")" = \
    "caddy,caddy.basic_auth.admin,caddy.reverse_proxy,caddy.reverse_proxy.header_up" ]
  [ "$(jq -r '.services.page.ports // [] | length' <<<"$cfg")" = 0 ]
}

@test "compose refuses to expose the page without the login hash" {
  prepared
  grep -qF 'caddy.basic_auth.admin: ${RUNNER_PAGE_AUTH_HASH:?RUNNER_PAGE_AUTH_HASH is not set}' "$APP_DIR/compose.expose.yml"
  grep -qF 'caddy: ${VA_SITE_ADDRS:?VA_SITE_ADDRS is not set}' "$APP_DIR/compose.expose.yml"
  refute_grep -qE 'https?://|:443' "$APP_DIR/compose.expose.yml"
  run merged_config compose.yml compose.expose.yml
  [ "$status" -ne 0 ]
  [[ "$output" == *RUNNER_PAGE_AUTH_HASH* ]]
}

@test "the login is hashed by the proxy's pinned Caddy image, offline, with the password on stdin and one newline" {
  prepared
  printf '%s' 'P@ss"w\0rd $x`y;1A' >"$PWF"
  app_create_admin "$PWF"
  grep -qxF "run --rm -i --network none --entrypoint caddy $CADDY_IMAGE hash-password --algorithm bcrypt --bcrypt-cost 10" "$STUB_TMP/docker.log"
  { cat "$PWF"; printf '\n'; } >"$BATS_TEST_TMPDIR/want"
  cmp "$F/hash_stdin" "$BATS_TEST_TMPDIR/want"
  grep -qxF "RUNNER_PAGE_AUTH_HASH='$FAKE_HASH'" "$DATA/.env"
  [ "$(grep -c '^RUNNER_PAGE_AUTH_HASH=' "$DATA/.env")" -eq 1 ]
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  [ ! -e "$(p /root/vps-apps-credentials.txt)" ]
  [ "$(find "$DATA" -name '.login-pw.*' | wc -l)" -eq 0 ]
}

@test "the password lands in no .env, compose file, docker argument or status" {
  with_login
  refute_grep -qF 'Secret123' "$DATA/.env" "$STUB_TMP/docker.log" "$APP_DIR"/compose*.yml "$DATA/status/status.json"
  [ "$(head -c -1 "$F/hash_stdin")" = Secret123 ]
}

@test "the rest of the .env is kept when the login is added" {
  prepared
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  app_create_admin "$PWF"
  diff "$BATS_TEST_TMPDIR/before" <(grep -v '^RUNNER_PAGE_AUTH_HASH=' "$DATA/.env")
}

@test "a hashing call that fails, or answers anything but a bcrypt hash, fails the step and writes no hash" {
  prepared
  : >"$F/hash_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  rm -f "$F/hash_fail"
  for bad in '' 'Error: something' '$2a$14$short' "${FAKE_HASH}x" '$argon2id$v=19$m=47104,t=1,p=1$abc'; do
    HASH_OUT="$bad" run app_create_admin "$PWF"
    [ "$status" -ne 0 ]
  done
  refute_grep -q '^RUNNER_PAGE_AUTH_HASH=' "$DATA/.env"
}

@test "a missing or unpinned Caddy image in the proxy .env fails the step without a docker call" {
  prepared
  : >"$STUB_TMP/docker.log"
  printf 'CADDY_IMAGE=lucaslorentz/caddy-docker-proxy:2.13.1-alpine\n' >"$(p /opt/vps-apps-data/proxy/.env)"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  rm -f "$(p /opt/vps-apps-data/proxy/.env)"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  refute_grep -q '^run ' "$STUB_TMP/docker.log"
}

@test "a retry hashes again and keeps one hash line" {
  prepared
  HASH_OUT='$2b$14$0000000000000000000000000000000000000000000000000000a' app_create_admin "$PWF"
  app_create_admin "$PWF"
  [ "$(grep -c '^RUNNER_PAGE_AUTH_HASH=' "$DATA/.env")" -eq 1 ]
  grep -qxF "RUNNER_PAGE_AUTH_HASH='$FAKE_HASH'" "$DATA/.env"
}

@test "every order-form password is used as it is, from 8 to 64 characters" {
  prepared
  for pw in Abcdefg1 'Zz9!@#$%^&*()_+-=[]{};:,.<>/?~' "$(printf 'A1%.0s' $(seq 32))"; do
    printf '%s' "$pw" >"$PWF"
    app_create_admin "$PWF"
    [ "$(head -c -1 "$F/hash_stdin")" = "$pw" ]
  done
  [ ! -e "$(p /root/vps-apps-credentials.txt)" ]
}

@test "a password the login cannot take falls back to a generated one in the credentials file, reused on a retry" {
  prepared
  for bad in "$(printf 'A1%.0s' $(seq 37))" 'Pässword1' $'Tab\tPass1' ''; do
    rm -f "$(p /root/vps-apps-credentials.txt)"
    printf '%s' "$bad" >"$PWF"
    app_create_admin "$PWF"
    cred="$(p /root/vps-apps-credentials.txt)"
    [ "$(stat -c %a "$cred")" = 600 ]
    sent="$(head -c -1 "$F/hash_stdin")"
    [ "$sent" != "$bad" ]
    [[ "$sent" =~ ^Rc9[0-9a-f]{32}$ ]]
    grep -qxF "Password: $sent" "$cred"
    grep -qxF 'Username: admin' "$cred"
  done
  app_create_admin "$PWF"
  [ "$(head -c -1 "$F/hash_stdin")" = "$sent" ]
}

@test "app_expose refuses without the login, and changes nothing" {
  prepared
  : >"$STUB_TMP/docker.log"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ ! -e "$(p /var/lib/vps-apps/site-mode)" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
  # A hash that is not single-quoted, or not a bcrypt hash, is no login either.
  printf 'RUNNER_PAGE_AUTH_HASH=%s\n' "$FAKE_HASH" >>"$DATA/.env"
  run app_expose
  [ "$status" -ne 0 ]
  sed -i '/^RUNNER_PAGE_AUTH_HASH=/d' "$DATA/.env"
  printf "RUNNER_PAGE_AUTH_HASH='plain'\n" >>"$DATA/.env"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  refute_grep -q compose.expose.yml "$STUB_TMP/docker.log"
}

@test "app_expose brings the setup stack up, checks the login, then exposes with the labels" {
  with_login
  : >"$STUB_TMP/docker.log"
  app_expose
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
  setup="$(grep -nxF "compose -f $APP_DIR/compose.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log" | cut -d: -f1)"
  expose="$(grep -nxF "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.expose.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log" | cut -d: -f1)"
  [ -n "$setup" ]
  [ -n "$expose" ]
  [ "$setup" -lt "$expose" ]
}

@test "app_up_setup installs the runner and starts the page without exposure" {
  make_runner_tarball
  stub_curl
  prepared
  : >"$STUB_TMP/docker.log"
  app_up_setup
  grep -qxF "compose -f $APP_DIR/compose.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
  [ ! -e "$DATA/exposed" ]
  [ ! -e "$(p /var/lib/vps-apps/site-mode)" ]
  [ -x "$RDIR/config.sh" ]
}

@test "a failed start in app_expose takes the stack down, drops the marker and shows the failed page" {
  with_login
  docker() {
    if [[ "$*" == *compose.expose.yml*" up"* ]]; then
      return 1
    fi
    [[ "$*" != *" down"* ]] || printf '%s\n' "$*" >>"$F/docker_down"
    command docker "$@"
  }
  run app_expose
  [ "$status" -ne 0 ]
  [ -s "$F/docker_down" ]
  [ ! -e "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
  unset -f docker
  stub_docker
  app_expose
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
}

# ready_curl: a curl for app_ready_check. The unauthenticated call answers READY_HEAD (a 401 with a
# Basic challenge); the authenticated one checks the header file's credential against admin and the
# password file and answers READY_BODY (ok). Every argv goes to $F/ready_argv, every header file the
# call read to $F/ready_headers.
ready_curl() {
  curl() {
    local a prev="" hdr=""
    printf '%s\n' "$*" >>"$F/ready_argv"
    for a in "$@"; do
      if [ "$prev" = -H ] && [[ "$a" == @* ]]; then hdr="${a#@}"; fi
      prev="$a"
    done
    [ -z "${READY_RC:-}" ] || return "$READY_RC"
    if [ -z "$hdr" ]; then
      printf '%s' "${READY_HEAD-$'HTTP/2 401 \r\nwww-authenticate: Basic realm="restricted"\r\n\r\n'}"
      return 0
    fi
    cat "$hdr" >>"$F/ready_headers"
    want="Authorization: Basic $(printf 'admin:%s' "$(cat "$PWF")" | base64 -w0)"
    [ "$(cat "$hdr")" = "$want" ] || return 22
    printf '%s' "${READY_BODY-ok}"
  }
}

@test "app_ready_check needs the login gate closed and the login opening it, over HTTPS with a valid certificate" {
  prepared
  ready_curl
  app_ready_check
  grep -qF -- "--resolve ghrunner-ab12cd.example.com:443:127.0.0.1 https://ghrunner-ab12cd.example.com/" "$F/ready_argv"
  grep -qF -- "https://ghrunner-ab12cd.example.com/healthz" "$F/ready_argv"
  refute_grep -qE -- '(^| )(-k|--insecure)( |$)' "$F/ready_argv"
  # The credential is in a header file, on no argv, and the file is gone afterwards.
  refute_grep -qF 'Secret123' "$F/ready_argv"
  refute_grep -qF "$(printf 'admin:Secret123' | base64 -w0)" "$F/ready_argv"
  [ -s "$F/ready_headers" ]
  [ "$(find "$DATA" -name '.ready.*' | wc -l)" -eq 0 ]
}

@test "app_ready_check fails when the page answers without the login, the login fails, or TLS fails" {
  prepared
  ready_curl
  # Served without the gate: never ready.
  READY_HEAD=$'HTTP/2 200 \r\ncontent-type: text/html\r\n\r\n' run app_ready_check
  [ "$status" -ne 0 ]
  # A 401 without a Basic challenge is not Caddy's gate.
  READY_HEAD=$'HTTP/2 401 \r\n\r\n' run app_ready_check
  [ "$status" -ne 0 ]
  READY_HEAD=$'HTTP/2 502 \r\n\r\n' run app_ready_check
  [ "$status" -ne 0 ]
  READY_BODY='not found' run app_ready_check
  [ "$status" -ne 0 ]
  READY_RC=60 run app_ready_check
  [ "$status" -ne 0 ]
  # The wrong password does not open it.
  printf '%s' 'Other123' >"$BATS_TEST_TMPDIR/other"
  VA_PASSWORD_FILE="$BATS_TEST_TMPDIR/other" run app_ready_check
  [ "$status" -ne 0 ]
  VA_PASSWORD_FILE="" run app_ready_check
  [ "$status" -ne 0 ]
}

@test "app_ready_check logs in with the generated password when there is one" {
  prepared
  ready_curl
  mkdir -p "$(p /root)"
  printf 'Runner page login\nUsername: admin\nPassword: Rc9abc\n' >"$(p /root/vps-apps-credentials.txt)"
  printf '%s' 'Rc9abc' >"$BATS_TEST_TMPDIR/generated"
  PWF="$BATS_TEST_TMPDIR/generated" VA_PASSWORD_FILE=/nonexistent app_ready_check
}

@test "app_domain_added serves every name, keeps every other line of the .env and recreates the page" {
  with_login
  : >"$STUB_TMP/docker.log"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  mkdir -p "$(p /etc/vps-apps)"
  printf 'ci.example.org\n' >"$(p /etc/vps-apps/domains)"
  : >"$DATA/exposed"
  app_domain_added ci.example.org
  grep -qxF 'VA_SITE_ADDRS="ghrunner-ab12cd.example.com ci.example.org"' "$DATA/.env"
  diff <(grep -v '^VA_SITE_ADDRS=' "$BATS_TEST_TMPDIR/before") <(grep -v '^VA_SITE_ADDRS=' "$DATA/.env")
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  grep -qxF "compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.expose.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
  run declare -F app_domain_check
  [ "$status" -ne 0 ]
}

@test "rc update re-resolves the page's 3.14-alpine tag and keeps the login; the runner updates itself" {
  run declare -F app_update_env
  [ "$status" -ne 0 ]
  run declare -F app_fill_env
  [ "$status" -ne 0 ]
  with_login
  sed -i "s#^PAGE_IMAGE=.*#PAGE_IMAGE=python@sha256:$(printf '1%.0s' $(seq 64))#" "$DATA/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  resolve_env_images "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  want="$(printf '%s' python:3.14-alpine | sha256sum | cut -d' ' -f1)"
  grep -qxF "PAGE_IMAGE=python@sha256:$want" "$BATS_TEST_TMPDIR/out"
  diff <(grep -v '^PAGE_IMAGE=' "$BATS_TEST_TMPDIR/before") <(grep -v '^PAGE_IMAGE=' "$BATS_TEST_TMPDIR/out")
}

# --- The runner install ----------------------------------------------------------------------

@test "the runner is the newest release, checked against GitHub's SHA-256, unpacked by ghrunner and checked to start" {
  make_runner_tarball
  stub_curl
  prepared
  gh_install_runner
  grep -qF 'https://api.github.com/repos/actions/runner/releases/latest' "$F/curl_calls"
  grep -qF -- '-o '"$RDIR"'.tar.gz https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-x64-2.338.2.tar.gz' "$F/curl_calls"
  [ -x "$RDIR/config.sh" ]
  [ -x "$RDIR/runsvc.sh" ]
  cmp "$RDIR/runsvc.sh" "$RDIR/bin/runsvc.sh"
  grep -qxF "setpriv --reuid=ghrunner --regid=ghrunner --init-groups -- tar -xzf $RDIR.tar.gz -C $RDIR.new" "$STUB_TMP/setpriv.log"
  grep -qxF "setpriv --reuid=ghrunner --regid=ghrunner --init-groups -- $RDIR.new/bin/Runner.Listener --version" "$STUB_TMP/setpriv.log"
  grep -qxF "chown ghrunner:ghrunner $RDIR.new $RDIR.tar.gz" "$STUB_TMP/calls.log"
  # The libraries the runner needs, then no download left behind.
  grep -qF 'install libkrb5-3 zlib1g liblttng-ust1t64 libssl3t64 libicu74' "$STUB_TMP/calls.log"
  [ ! -e "$RDIR.tar.gz" ]
  [ ! -e "$RDIR.new" ]
}

@test "an installed runner is kept: no second download, even after it updated itself" {
  make_runner_tarball
  stub_curl
  prepared
  gh_install_runner
  printf 'self-updated\n' >"$RDIR/bin/marker"
  : >"$F/curl_calls"
  gh_install_runner
  [ ! -s "$F/curl_calls" ]
  [ -f "$RDIR/bin/marker" ]
}

@test "a download that does not match its SHA-256 is refused and nothing is unpacked" {
  make_runner_tarball
  stub_curl
  prepared
  RELEASE_BODY="$(release_json 2.338.2 "sha256:$(printf 'd%.0s' $(seq 64))" "$(printf 'd%.0s' $(seq 64))")" run gh_install_runner
  [ "$status" -ne 0 ]
  [ ! -e "$RDIR" ]
  [ ! -e "$RDIR.tar.gz" ]
  refute_grep -q 'tar -xzf' "$STUB_TMP/setpriv.log" 2>/dev/null
}

@test "the SHA-256 comes from the asset digest, or the release notes when there is no digest; both must agree" {
  make_runner_tarball
  stub_curl
  prepared
  # Notes only.
  RELEASE_BODY="$(release_json 2.338.2 '' "$RUNNER_SHA")" gh_install_runner
  [ -x "$RDIR/config.sh" ]
  rm -rf "$RDIR"
  # A digest and notes that disagree.
  RELEASE_BODY="$(release_json 2.338.2 "sha256:$RUNNER_SHA" "$(printf 'e%.0s' $(seq 64))")" run gh_install_runner
  [ "$status" -ne 0 ]
  # Neither.
  RELEASE_BODY="$(release_json 2.338.2 '' 'none')" run gh_install_runner
  [ "$status" -ne 0 ]
  [ ! -e "$RDIR" ]
}

@test "a release that is not 2.x, a prerelease, or an asset from anywhere else is refused before any download" {
  make_runner_tarball
  stub_curl
  prepared
  for body in "$(release_json 3.0.0)" "$(release_json 2.338)" "$(release_json | jq '.prerelease = true')" \
    "$(release_json | jq '.assets[0].browser_download_url = "https://evil.example.com/actions-runner-linux-x64-2.338.2.tar.gz"')" \
    "$(release_json | jq '.assets = []')" 'not json' ''; do
    : >"$F/curl_calls"
    RELEASE_BODY="$body" run gh_install_runner
    [ "$status" -ne 0 ]
    refute_grep -q 'releases/download' "$F/curl_calls"
  done
  : >"$F/api_fail"
  run gh_install_runner
  [ "$status" -ne 0 ]
  [ ! -e "$RDIR" ]
}

@test "a runner that does not start, or a failed download, fails the step and a retry installs it" {
  make_runner_tarball
  stub_curl
  prepared
  : >"$F/dl_fail"
  run gh_install_runner
  [ "$status" -ne 0 ]
  rm -f "$F/dl_fail"
  : >"$F/listener_fail"
  run gh_install_runner
  [ "$status" -ne 0 ]
  [ ! -e "$RDIR" ]
  [ ! -e "$RDIR.new" ]
  rm -f "$F/listener_fail"
  gh_install_runner
  [ -x "$RDIR/config.sh" ]
}

@test "the runner's architecture comes from dpkg; anything but amd64 and arm64 is refused" {
  [ "$(gh_arch)" = x64 ]
  dpkg() { echo arm64; }
  [ "$(gh_arch)" = arm64 ]
  dpkg() { echo riscv64; }
  run gh_arch
  [ "$status" -ne 0 ]
}

# --- The registration request (the root unit) -------------------------------------------------

# installed: app_prepare, the login and the runner installed.
installed() {
  make_runner_tarball
  stub_curl
  with_login
  gh_install_runner
}

# request <json>: what the page would leave in the inbox, as the page user (the test's own uid).
request() {
  (
    umask 077
    printf '%s' "$1" >"$RUN/inbox/request"
  )
}

# no_token_anywhere <token>: the token is in no file the register run leaves behind, no log and no
# argv.
no_token_anywhere() {
  refute_grep -rqF "$1" "$RUN" "$DATA" "$(p /etc)" "$STUB_TMP/systemctl.log" "$STUB_TMP/docker.log" \
    "$STUB_TMP/calls.log" "$STUB_TMP/setpriv.log" "$(p /var/log)" 2>/dev/null
  if [ -d "$RDIR" ]; then refute_grep -rqF "$1" "$RDIR"; fi
}

@test "no request: nothing happens and the status stays" {
  installed
  cp "$DATA/status/status.json" "$BATS_TEST_TMPDIR/before"
  : >"$STUB_TMP/systemctl.log"
  runner_handle_request
  cmp "$DATA/status/status.json" "$BATS_TEST_TMPDIR/before"
  [ ! -s "$STUB_TMP/systemctl.log" ]
}

@test "a valid request registers the runner with config.sh as ghrunner, the token only in its environment" {
  installed
  request "{\"url\":\"https://github.com/octo/repo\",\"token\":\"$TOKEN\"}"
  : >"$STUB_TMP/setpriv.log"
  run runner_handle_request
  [ "$status" -eq 0 ]
  [ "$(cat "$F/config_token")" = "$TOKEN" ]
  [ "$(cat "$F/config_home")" = /home/ghrunner ]
  # Not the register unit's root-only TMPDIR: a folder of ghrunner's own, 0700.
  [ "$(cat "$F/config_tmpdir")" = /home/ghrunner/tmp ]
  [ "$(stat -c %a "$(p /home/ghrunner/tmp)")" = 700 ]
  # Made by ghrunner itself, so root never writes where the runner's jobs can plant a link.
  grep -qxF "setpriv --reuid=ghrunner --regid=ghrunner --init-groups -- mkdir -p -m 0700 $(p /home/ghrunner/tmp)" "$STUB_TMP/setpriv.log"
  refute_grep -qF "chown ghrunner:ghrunner $(p /home/ghrunner/tmp)" "$STUB_TMP/calls.log"
  [ "$(cat "$F/config_argv")" = "$(printf '%s\n' --unattended --url https://github.com/octo/repo --name ghrunner-ab12cd --work _work --replace)" ]
  grep -qxF "setpriv --reuid=ghrunner --regid=ghrunner --init-groups -- $RDIR/config.sh --unattended --url https://github.com/octo/repo --name ghrunner-ab12cd --work _work --replace" "$STUB_TMP/setpriv.log"
  grep -qxF 'stop vps-apps-ghrunner.service' "$STUB_TMP/systemctl.log"
  grep -qxF 'enable vps-apps-ghrunner.service' "$STUB_TMP/systemctl.log"
  grep -qxF 'restart vps-apps-ghrunner.service' "$STUB_TMP/systemctl.log"
  st="$DATA/status/status.json"
  [ "$(jq -r .state "$st")" = registered ]
  [ "$(jq -r .url "$st")" = https://github.com/octo/repo ]
  [ "$(jq -r .message "$st")" = "Registered with https://github.com/octo/repo as ghrunner-ab12cd. The runner is waiting for jobs." ]
  # The request is gone from the inbox and the work directory, and config.sh's output reached the
  # journal (stdout) without the token or any piece of it.
  [ ! -e "$RUN/inbox/request" ]
  [ -z "$(ls -A "$RUN/work" | grep -v '^\.lock$')" ]
  [[ "$output" == *"Runner successfully added for [hidden]"* ]]
  [[ "$output" != *"${TOKEN:0:8}"* ]]
  [ ! -e "$RDIR/.vps-apps-previous" ]
  no_token_anywhere "$TOKEN"
}

@test "a token GitHub refuses fails with a short reason, and the token is in no log, file or status" {
  installed
  : >"$F/config_fail"
  request "{\"url\":\"https://github.com/octo/repo\",\"token\":\"$TOKEN\"}"
  run runner_handle_request
  [ "$status" -ne 0 ]
  st="$DATA/status/status.json"
  [ "$(jq -r .state "$st")" = failed ]
  [ "$(jq -r .message "$st")" = "GitHub did not accept this address and token. A token is valid for one hour: get a new one in GitHub and send the form again." ]
  [ "$(jq -r .url "$st")" = "" ]
  [[ "$output" == *"Http response code: NotFound"* ]]
  [[ "$output" != *"${TOKEN:2:8}"* ]]
  refute_grep -q 'enable vps-apps-ghrunner.service' "$STUB_TMP/systemctl.log"
  [ ! -e "$RDIR/.runner" ]
  no_token_anywhere "$TOKEN"
}

@test "registering again replaces the runner; a failed attempt puts the earlier registration back and starts it" {
  installed
  request "{\"url\":\"https://github.com/octo/repo\",\"token\":\"$TOKEN\"}"
  runner_handle_request
  printf 'first\n' >"$RDIR/.credentials"
  # A second, failing attempt with another repository.
  : >"$F/config_fail"
  : >"$STUB_TMP/systemctl.log"
  request "{\"url\":\"https://github.com/octo/other\",\"token\":\"$OTHER_TOKEN\"}"
  run runner_handle_request
  [ "$status" -ne 0 ]
  [ "$(cat "$RDIR/.credentials")" = first ]
  [ -f "$RDIR/.runner" ]
  [ ! -e "$RDIR/.vps-apps-previous" ]
  grep -qxF 'start vps-apps-ghrunner.service' "$STUB_TMP/systemctl.log"
  st="$DATA/status/status.json"
  [ "$(jq -r .state "$st")" = failed ]
  [ "$(jq -r .url "$st")" = https://github.com/octo/repo ]
  [[ "$(jq -r .message "$st")" == *"The runner stays registered as before." ]]
  # A third attempt that works replaces it, with --replace, and leaves no copy of the old one.
  rm -f "$F/config_fail"
  request "{\"url\":\"https://github.com/octo/other\",\"token\":\"$OTHER_TOKEN\"}"
  runner_handle_request
  [ ! -s "$RDIR/.credentials" ]
  [ ! -e "$RDIR/.vps-apps-previous" ]
  [ "$(jq -r .url "$st")" = https://github.com/octo/other ]
  grep -qx -- --replace "$F/config_argv"
}

@test "a registration set aside by a run that died is put back before the next attempt" {
  installed
  mkdir -m 0700 "$RDIR/.vps-apps-previous"
  printf 'old\n' >"$RDIR/.vps-apps-previous/.credentials"
  : >"$RDIR/.vps-apps-previous/.runner"
  : >"$F/config_fail"
  request "{\"url\":\"https://github.com/octo/repo\",\"token\":\"$TOKEN\"}"
  run runner_handle_request
  [ "$status" -ne 0 ]
  [ "$(cat "$RDIR/.credentials")" = old ]
  [ ! -e "$RDIR/.vps-apps-previous" ]
}

@test "requests that are not what the page writes are dropped without a registration" {
  installed
  for body in 'not json' '[]' '{"url":"https://github.com/octo/repo"}' \
    "{\"url\":\"https://github.com/octo/repo\",\"token\":\"$TOKEN\",\"extra\":1}" \
    "{\"url\":\"http://github.com/octo/repo\",\"token\":\"$TOKEN\"}" \
    "{\"url\":\"https://github.com/octo/repo\",\"token\":\"ghp_$TOKEN\"}" \
    "{\"url\":\"https://github.com/octo/repo\",\"token\":\"$TOKEN\\n--pat x\"}" \
    "{\"url\":\"https://github.com/octo/repo --pat x\",\"token\":\"$TOKEN\"}" \
    "{\"url\":[\"https://github.com/octo/repo\"],\"token\":\"$TOKEN\"}" \
    "{\"url\":\"https://github.com/octo/repo\",\"token\":\"$TOKEN\"}{\"url\":\"https://github.com/a/b\",\"token\":\"$TOKEN\"}"; do
    rm -f "$F/config_argv"
    request "$body"
    run runner_handle_request
    [ "$status" -ne 0 ]
    [ ! -e "$F/config_argv" ]
    [ ! -e "$RUN/inbox/request" ]
    [ "$(jq -r .state "$DATA/status/status.json")" = failed ]
    [ "$(jq -r .message "$DATA/status/status.json")" = "The address or the token is not valid. Send the form again." ]
  done
}

@test "a symlink, a hard link, a directory, an empty or an oversized request is dropped and never followed" {
  installed
  printf 'secret-of-root\n' >"$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$RUN/inbox/request"
  run runner_handle_request
  [ "$status" -ne 0 ]
  [ ! -L "$RUN/inbox/request" ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = secret-of-root ]
  [ "$(jq -r .message "$DATA/status/status.json")" = "The request could not be read. Send the form again." ]
  ln "$BATS_TEST_TMPDIR/target" "$RUN/inbox/request"
  run runner_handle_request
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = secret-of-root ]
  mkdir "$RUN/inbox/request"
  run runner_handle_request
  [ "$status" -ne 0 ]
  : >"$RUN/inbox/request"
  run runner_handle_request
  [ "$status" -ne 0 ]
  head -c 5000 /dev/zero | tr '\0' a >"$RUN/inbox/request"
  run runner_handle_request
  [ "$status" -ne 0 ]
  [ ! -e "$RUN/inbox/request" ]
  [ ! -e "$F/config_argv" ]
  [ -z "$(ls -A "$RUN/work" | grep -v '^\.lock$')" ]
}

@test "a request from any other user than the page's is dropped" {
  installed
  sed -i "s/^PAGE_UID=.*/PAGE_UID=$((ME_UID + 1))/" "$DATA/.env"
  request "{\"url\":\"https://github.com/octo/repo\",\"token\":\"$TOKEN\"}"
  run runner_handle_request
  [ "$status" -ne 0 ]
  [ ! -e "$F/config_argv" ]
}

@test "a run that dies while registering leaves the status failed, not working" {
  installed
  runner_write_status working "Registering with https://github.com/octo/repo." ""
  runner_finish_interrupted
  [ "$(jq -r .state "$DATA/status/status.json")" = failed ]
  [ "$(jq -r .message "$DATA/status/status.json")" = "The registration was interrupted. Send the form again." ]
  runner_write_status registered "Registered." https://github.com/octo/repo
  runner_finish_interrupted
  [ "$(jq -r .state "$DATA/status/status.json")" = registered ]
}

@test "runner_redact hides the token and every 8-character piece of it, and any glrt- token" {
  out="$(printf 'a %s b %s c %s d %sabcdefghijklmnopqrstuvwx e\n' "$TOKEN" "${TOKEN:3:10}" "${TOKEN:19:8}" "$GLRT" | runner_redact "$TOKEN")"
  [[ "$out" != *"${TOKEN:3:8}"* ]]
  [[ "$out" != *"${TOKEN:19:8}"* ]]
  [[ "$out" != *abcdefghijkl* ]]
  [[ "$out" == "a [hidden] b [hidden]"*" c [hidden] d glrt-[hidden] e" ]]
  [ "$(head -c 20000 /dev/zero | tr '\0' x | runner_redact "$TOKEN" | wc -c)" -le 4001 ]
}

@test "register.sh refuses an app that is not the installed one, or not a runner app" {
  run bash "$COMMON_DIR/register.sh" n8n
  [ "$status" -eq 2 ]
  run bash "$COMMON_DIR/register.sh"
  [ "$status" -eq 2 ]
  mkdir -p "$(p /etc/vps-apps)"
  printf 'APP=glrunner\nMODE=\nVA_HOST=x.example.com\nVA_IP=203.0.113.9\nADMIN_EMAIL=\n' >"$(p /etc/vps-apps/app.env)"
  run bash "$COMMON_DIR/register.sh" ghrunner
  [ "$status" -eq 2 ]
}

@test "register.sh with no request exits 0 and changes nothing" {
  prepared
  mkdir -p "$(p /etc/vps-apps)"
  printf 'APP=ghrunner\nMODE=\nVA_HOST=%s\nVA_IP=203.0.113.9\nADMIN_EMAIL=\n' "$VA_HOST" >"$(p /etc/vps-apps/app.env)"
  cp "$DATA/status/status.json" "$BATS_TEST_TMPDIR/before"
  run bash "$COMMON_DIR/register.sh" ghrunner
  [ "$status" -eq 0 ]
  cmp "$DATA/status/status.json" "$BATS_TEST_TMPDIR/before"
}

# --- The validation rules: page.py and runner.sh agree ---------------------------------------

# A table of cases: kind, address, token, then whether each is valid.
CASES='github	https://github.com/octo	AABBCCDDEEFFGGHHIIJJKKLLMM0	1	1
github	https://github.com/octo-org/my.repo_1-x	A1B2C3D4E5F6G7H8I9J0	1	1
github	https://github.com/A/R	abc_def-ghi_jkl-mno_pq	1	1
github	http://github.com/octo/repo	A1B2C3D4E5F6G7H8I9J	0	0
github	https://github.com/	ghp_AABBCCDDEEFFGGHHIIJJKK	0	0
github	https://github.com/-octo	github_pat_AABBCCDDEEFFGGHH	0	0
github	https://github.com/octo-	gho_AABBCCDDEEFFGGHHIIJJKK	0	0
github	https://github.com/octo/repo/extra	AABB CCDDEEFFGGHHIIJJKK	0	0
github	https://github.com/octo/..	AABBCCDDEEFFGGHHIIJJ$K	0	0
github	https://github.com/octo/.	AABBCCDDEEFFGGHHIIJJÄK	0	0
github	https://github.com/octo/repo.git	ghs_AABBCCDDEEFFGGHHIIJJKK	0	0
github	https://github.com/octo/repo?x=1	ghu_AABBCCDDEEFFGGHHIIJJKK	0	0
github	https://github.com/octo/repo#x	ghr_AABBCCDDEEFFGGHHIIJJKK	0	0
github	https://github.com.evil.example/octo	AABBCCDDEEFFGGHHIIJJKK;x	0	0
github	https://user@github.com/octo	AABBCCDDEEFFGGHHIIJJKK/x	0	0
github	https://evil.example/github.com/octo	AABBCCDDEEFFGGHHIIJJKK.x	0	0
github	https://github.com/octo/repo	AABBCCDDEEFFGGHHIIJJ-_ab	1	1
gitlab	https://gitlab.com	@glrt@abcdefghijklmnopqrst	1	1
gitlab	https://gitlab.example.com:8443	@glrt@t1_AbC.dEf-1234567890123	1	1
gitlab	https://example.com/gitlab/ci	@glrt@ABCDEFGHIJKLMNOPQRSTUVWXYZ	1	1
gitlab	https://10.0.0.5	@glrt@abcdefghijklmnopqrst	1	1
gitlab	http://gitlab.com	@glrt@short	0	0
gitlab	https://gitlab	@gr@abcdefghijklmnopqrst	0	0
gitlab	https://GitLab.com	@glpat@abcdefghijklmnopqrstu	0	0
gitlab	https://gitlab.com:0	@glrt@abcdefghij klmnopqrst	0	0
gitlab	https://gitlab.com:70000	@glrt@abcdefghijklmnopqrsé	0	0
gitlab	https://gitlab.com/../x	@glrt@abcdefghijklmnopqrst$	0	0
gitlab	https://gitlab.com/a/./b	AABBCCDDEEFFGGHHIIJJKKLLMM0	0	0
gitlab	https://gitlab.com/?x=1	@glrt@abcdefghijklmnopqrst;x	0	0
gitlab	https://user:pw@gitlab.com	@glrt@abcdefghijklmnopqrst/x	0	0
gitlab	https://-a.example.com	@glrt@	0	0
gitlab	https://a-.example.com	@glrt@abcdefghijklmnopqrst	0	1
gitlab	https://gitlab.com//x	@glrt@abcdefghijklmnopqrst	0	1
gitlab	https://gitlab.com/a%20b	@glrt@abcdefghijklmnopqrst	0	1
gitlab	https://gitlab.com/x#y	@glrt@abcdefghijklmnopqrst	0	1'

# py_results <cases-file>: page.py's valid_url and valid_token on every case, "<url> <token>" per line.
py_results() {
  python3 -I -B - "$COMMON_DIR/page.py" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("page", sys.argv[1])
page = importlib.util.module_from_spec(spec)
spec.loader.exec_module(page)
with open(sys.argv[2], encoding="utf-8") as f:
    for line in f.read().splitlines():
        kind, url, token = line.split("\t")[:3]
        print(int(page.valid_url(kind, url)), int(page.valid_token(kind, token)))
PY
}

@test "page.py and runner.sh judge every address and token the same, and as the table says" {
  command -v python3 >/dev/null || skip "no python3 on this machine"
  {
    cases="${CASES//@glrt@/$GLRT}"
    cases="${cases//@glpat@/$GLPAT}"
    printf '%s\n' "${cases//@gr@/$GRRT}"
    # The length limits: an owner of 39 and 40 characters, a repository of 100 and 101, a token of
    # 255 and 256, a GitLab label of 63 and 64.
    printf 'github\thttps://github.com/%s\tAABBCCDDEEFFGGHHIIJJKK\t1\t1\n' "$(printf 'a%.0s' $(seq 39))"
    printf 'github\thttps://github.com/%s\tAABBCCDDEEFFGGHHIIJJKK\t0\t1\n' "$(printf 'a%.0s' $(seq 40))"
    printf 'github\thttps://github.com/o/%s\t%s\t1\t1\n' "$(printf 'r%.0s' $(seq 100))" "$(printf 'T%.0s' $(seq 255))"
    printf 'github\thttps://github.com/o/%s\t%s\t0\t0\n' "$(printf 'r%.0s' $(seq 101))" "$(printf 'T%.0s' $(seq 256))"
    printf 'gitlab\thttps://%s.example.com\t%sabcdefghijklmnopqrst\t1\t1\n' "$(printf 'g%.0s' $(seq 63))" "$GLRT"
    printf 'gitlab\thttps://%s.example.com\t%sabcdefghijklmnopqrst\t0\t1\n' "$(printf 'g%.0s' $(seq 64))" "$GLRT"
  } >"$BATS_TEST_TMPDIR/cases"
  py_results "$BATS_TEST_TMPDIR/cases" >"$BATS_TEST_TMPDIR/py"
  n=0
  while IFS=$'\t' read -r kind url token want_url want_token; do
    n=$((n + 1))
    VA_RUNNER_KIND="$kind"
    got_url=0 got_token=0
    if runner_valid_url "$url"; then got_url=1; fi
    if runner_valid_token "$token"; then got_token=1; fi
    py="$(sed -n "${n}p" "$BATS_TEST_TMPDIR/py")"
    echo "case $n: $kind $url $token: bash $got_url $got_token, python $py, want $want_url $want_token"
    [ "$got_url $got_token" = "$want_url $want_token" ]
    [ "$py" = "$want_url $want_token" ]
  done <"$BATS_TEST_TMPDIR/cases"
  [ "$n" -eq "$(wc -l <"$BATS_TEST_TMPDIR/cases")" ]
}

@test "an address or token with a newline is invalid on both sides" {
  command -v python3 >/dev/null || skip "no python3 on this machine"
  VA_RUNNER_KIND=github
  run runner_valid_url $'https://github.com/octo\n'
  [ "$status" -ne 0 ]
  run runner_valid_token "$TOKEN"$'\n'
  [ "$status" -ne 0 ]
  run python3 -I -B - "$COMMON_DIR/page.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("page", sys.argv[1])
page = importlib.util.module_from_spec(spec)
spec.loader.exec_module(page)
assert not page.valid_url("github", "https://github.com/octo\n")
assert not page.valid_token("github", "AABBCCDDEEFFGGHHIIJJKKLLMM0\n")
assert not page.valid_url("gitlab", "https://gitlab.com\n")
PY
  [ "$status" -eq 0 ]
}

# --- The page (page.py) ------------------------------------------------------------------------

# real_curl: the system curl (the stub is first on PATH).
real_curl() {
  local d
  while IFS= read -r d; do
    [ "$d" = "$BATS_TEST_DIRNAME/stubs" ] && continue
    [ -x "$d/curl" ] && { "$d/curl" "$@"; return; }
  done < <(tr ':' '\n' <<<"$PATH")
  return 127
}

# start_page <kind>: page.py on a free loopback port, with its inbox and status in the test dir.
# PAGE_URL is its address. The process closes fd 3, which bats waits on.
start_page() {
  command -v python3 >/dev/null || skip "no python3 on this machine"
  PAGE_INBOX="$BATS_TEST_TMPDIR/inbox"
  PAGE_STATUS="$BATS_TEST_TMPDIR/status.json"
  PAGE_LOG="$BATS_TEST_TMPDIR/page.log"
  mkdir -p "$PAGE_INBOX"
  [ -f "$PAGE_STATUS" ] || printf '{"state":"none","message":"Not registered yet.","url":"","updated":""}' >"$PAGE_STATUS"
  RUNNER_KIND="$1" RUNNER_PAGE_INBOX="$PAGE_INBOX" RUNNER_PAGE_STATUS="$PAGE_STATUS" RUNNER_PAGE_BIND=127.0.0.1 \
    RUNNER_PAGE_PORT=0 python3 -I "$COMMON_DIR/page.py" 2>"$PAGE_LOG" 3>&- &
  PAGE_PID=$!
  for _ in $(seq 100); do
    port="$(sed -n 's/^listening on \([0-9]*\)$/\1/p' "$PAGE_LOG")"
    [ -z "$port" ] || break
    sleep 0.05
  done
  [ -n "$port" ]
  PAGE_URL="http://127.0.0.1:$port"
}

# csrf_of <html-file>: the form's CSRF value.
csrf_of() {
  sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$1"
}

# page_get: GET / into $F/page.html, headers into $F/page.head, and the cookie the page set into
# COOKIE (name=value). The tests talk plain HTTP to the page, where curl never sends a Secure
# cookie from its jar, so it is passed by value.
page_get() {
  real_curl -sS -D "$F/page.head" -o "$F/page.html" "$PAGE_URL/"
  COOKIE="$(sed -n 's/^[Ss]et-[Cc]ookie: \(rc_csrf=[^;]*\);.*/\1/p' "$F/page.head")"
}

# page_post <curl args...>: POST / with the page's cookie and its own Origin (or ORIGIN), plus the
# arguments; prints the HTTP status. The body is in $F/post.html.
page_post() {
  real_curl -sS -o "$F/post.html" -w '%{http_code}' -b "$COOKIE" -H "Host: runner.example.com" \
    -H "Origin: ${ORIGIN:-https://runner.example.com}" "$@" "$PAGE_URL/"
}

@test "the page shows the status, one form with a CSRF value and a strict cookie, and the GitHub help" {
  start_page github
  page_get
  grep -qi '^HTTP/1.0 200' "$F/page.head"
  grep -qF '<form method="post" action="/">' "$F/page.html"
  [ "$(grep -c '<form' "$F/page.html")" -eq 1 ]
  [ -n "$(csrf_of "$F/page.html")" ]
  grep -qi "^set-cookie: rc_csrf=$(csrf_of "$F/page.html"); Path=/; Secure; HttpOnly; SameSite=Strict" "$F/page.head"
  grep -qF 'Not registered yet.' "$F/page.html"
  grep -qF 'New self-hosted runner' "$F/page.html"
  grep -qF 'runs-on: self-hosted' "$F/page.html"
  grep -qF 'GitHub advises against self-hosted runners on public repositories' "$F/page.html"
  grep -qF 'type="password"' "$F/page.html"
  # No script at all, and the headers forbid one, framing and caching.
  refute_grep -qi '<script' "$F/page.html"
  grep -qi "^content-security-policy: default-src 'none'; style-src 'sha256-" "$F/page.head"
  grep -qi "frame-ancestors 'none'" "$F/page.head"
  grep -qi '^x-frame-options: DENY' "$F/page.head"
  grep -qi '^cache-control: no-store' "$F/page.head"
  grep -qi '^x-content-type-options: nosniff' "$F/page.head"
  # same-origin, not no-referrer: under no-referrer a browser sends "Origin: null" with the form's
  # POST (Fetch standard, "append a request Origin header"), and the Origin check refuses that.
  grep -qi '^referrer-policy: same-origin' "$F/page.head"
  [ "$(grep -ci '^referrer-policy:' "$F/page.head")" -eq 1 ]
  # The style the policy allows is the one on the page.
  style="$(sed -n 's/.*<style>\(.*\)<\/style>.*/\1/p' "$F/page.html")"
  want="$(printf '%s' "$style" | openssl dgst -sha256 -binary | base64)"
  grep -qiF "style-src 'sha256-$want'" "$F/page.head"
  [ "$(real_curl -sS "$PAGE_URL/healthz")" = ok ]
}

@test "a valid form writes one 0600 request with the exact URL and token, then redirects to the page" {
  start_page github
  page_get
  code="$(page_post --data-urlencode "csrf=$(csrf_of "$F/page.html")" \
    --data-urlencode 'url= https://GitHub.com/octo/repo/ ' --data-urlencode "token= $TOKEN ")"
  [ "$code" = 303 ]
  [ "$(stat -c %a "$PAGE_INBOX/request")" = 600 ]
  [ "$(jq -c . "$PAGE_INBOX/request")" = "{\"url\":\"https://github.com/octo/repo\",\"token\":\"$TOKEN\"}" ]
  [ "$(ls -A "$PAGE_INBOX")" = request ]
  # While it waits, the page says so and reloads itself.
  page_get
  grep -qF 'Your request is waiting to be processed.' "$F/page.html"
  grep -qF '<meta http-equiv="refresh" content="5">' "$F/page.html"
  # One request at a time.
  code="$(page_post --data-urlencode "csrf=$(csrf_of "$F/page.html")" \
    --data-urlencode 'url=https://github.com/octo/other' --data-urlencode "token=$TOKEN")"
  [ "$code" = 409 ]
  [ "$(jq -r .url "$PAGE_INBOX/request")" = https://github.com/octo/repo ]
  # The token is in no log line.
  refute_grep -qF "$TOKEN" "$PAGE_LOG"
  grep -qxF 'POST / 303' "$PAGE_LOG"
}

@test "a form without the CSRF value and cookie, or from another origin, is refused and writes nothing" {
  start_page github
  page_get
  csrf="$(csrf_of "$F/page.html")"
  form=(--data-urlencode 'url=https://github.com/octo/repo' --data-urlencode "token=$TOKEN")
  [ "$(page_post "${form[@]}")" = 403 ]
  [ "$(page_post --data-urlencode "csrf=x$csrf" "${form[@]}")" = 403 ]
  [ "$(real_curl -sS -o /dev/null -w '%{http_code}' -H 'Host: runner.example.com' -H 'Origin: https://runner.example.com' \
    --data-urlencode "csrf=$csrf" "${form[@]}" "$PAGE_URL/")" = 403 ]
  [ "$(real_curl -sS -o /dev/null -w '%{http_code}' -b "rc_csrf=x$csrf" -H 'Host: runner.example.com' \
    -H 'Origin: https://runner.example.com' --data-urlencode "csrf=$csrf" "${form[@]}" "$PAGE_URL/")" = 403 ]
  [ "$(ORIGIN=https://evil.example.com page_post --data-urlencode "csrf=$csrf" "${form[@]}")" = 403 ]
  [ "$(ORIGIN=null page_post --data-urlencode "csrf=$csrf" "${form[@]}")" = 403 ]
  # A second Origin or Sec-Fetch-Site header is refused, whatever the first says.
  [ "$(page_post -H 'Origin: https://evil.example.com' --data-urlencode "csrf=$csrf" "${form[@]}")" = 403 ]
  [ "$(page_post -H 'Sec-Fetch-Site: same-origin' -H 'Sec-Fetch-Site: cross-site' --data-urlencode "csrf=$csrf" "${form[@]}")" = 403 ]
  [ "$(page_post -H 'Sec-Fetch-Site: cross-site' --data-urlencode "csrf=$csrf" "${form[@]}")" = 403 ]
  [ "$(page_post --data-urlencode "csrf=$csrf" --data-urlencode "csrf=$csrf" "${form[@]}")" = 400 ]
  [ "$(page_post --data-urlencode 'csrf=é' "${form[@]}")" = 400 ]
  [ -z "$(ls -A "$PAGE_INBOX")" ]
  # The same form with everything in place goes through.
  [ "$(page_post -H 'Sec-Fetch-Site: same-origin' --data-urlencode "csrf=$csrf" "${form[@]}")" = 303 ]
}

@test "a same-origin form POST with the headers a browser sends passes the check" {
  start_page github
  page_get
  csrf="$(csrf_of "$F/page.html")"
  # What Chrome, Firefox and Safari send when the customer clicks Register on the page served with
  # Referrer-Policy: same-origin: the page's own Origin and Referer and the fetch metadata of a
  # same-origin navigation.
  code="$(real_curl -sS -o "$F/post.html" -w '%{http_code}' -b "$COOKIE" -H 'Host: runner.example.com' \
    -H 'Origin: https://runner.example.com' -H 'Referer: https://runner.example.com/' \
    -H 'Sec-Fetch-Site: same-origin' -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Dest: document' \
    -H 'Sec-Fetch-User: ?1' -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "csrf=$csrf" --data-urlencode 'url=https://github.com/octo/repo' \
    --data-urlencode "token=$TOKEN" "$PAGE_URL/")"
  [ "$code" = 303 ]
  [ "$(jq -r .url "$PAGE_INBOX/request")" = https://github.com/octo/repo ]
}

@test "an invalid address or token is refused with a message, the address kept, the token never echoed" {
  start_page github
  page_get
  csrf="$(csrf_of "$F/page.html")"
  code="$(page_post --data-urlencode "csrf=$csrf" --data-urlencode 'url=https://gitlab.com/octo' --data-urlencode "token=$TOKEN")"
  [ "$code" = 400 ]
  grep -qF 'Enter the address of your repository or organization' "$F/post.html"
  grep -qF 'value="https://gitlab.com/octo"' "$F/post.html"
  refute_grep -qF "$TOKEN" "$F/post.html"
  code="$(page_post --data-urlencode "csrf=$csrf" --data-urlencode 'url=https://github.com/octo' --data-urlencode 'token=ghp_AABBCCDDEEFFGGHHIIJJKKLL')"
  [ "$code" = 400 ]
  grep -qF 'This is a personal access token.' "$F/post.html"
  refute_grep -qF 'ghp_AABB' "$F/post.html"
  code="$(page_post --data-urlencode "csrf=$csrf" --data-urlencode 'url=https://github.com/octo' --data-urlencode 'token=short')"
  [ "$code" = 400 ]
  grep -qF 'This is not a runner registration token.' "$F/post.html"
  # An address that tries to break out of the attribute is shown escaped.
  code="$(page_post --data-urlencode "csrf=$csrf" --data-urlencode 'url="><b>x' --data-urlencode "token=$TOKEN")"
  [ "$code" = 400 ]
  grep -qF 'value="&quot;&gt;&lt;b&gt;x"' "$F/post.html"
  [ -z "$(ls -A "$PAGE_INBOX")" ]
}

@test "a body that is too large, not a form, or of unknown length is refused before it is read" {
  start_page github
  page_get
  csrf="$(csrf_of "$F/page.html")"
  big="$(head -c 5000 /dev/zero | tr '\0' a)"
  [ "$(page_post --data-urlencode "csrf=$csrf" --data-urlencode "url=$big" --data-urlencode "token=$TOKEN")" = 413 ]
  [ "$(page_post -H 'Content-Type: application/json' --data "{\"csrf\":\"$csrf\"}")" = 415 ]
  [ "$(page_post -H 'Transfer-Encoding: chunked' --data-urlencode "csrf=$csrf")" = 411 ]
  # A length that is a Unicode digit (byte 0xB2, a superscript two in Latin-1) is no length.
  exec 9<>"/dev/tcp/127.0.0.1/${PAGE_URL##*:}"
  printf 'POST / HTTP/1.1\r\nHost: runner.example.com\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \xb2\r\n\r\n' >&9
  line="$(timeout 5 head -n 1 <&9 || true)"
  exec 9>&-
  [[ "$line" == "HTTP/1.0 411 "* ]]
  [ "$(real_curl -sS -o /dev/null -w '%{http_code}' -X POST --data x "$PAGE_URL/other")" = 404 ]
  [ "$(real_curl -sS -o /dev/null -w '%{http_code}' -X POST --data x "$PAGE_URL/?x=1")" = 404 ]
  [ "$(real_curl -sS -o /dev/null -w '%{http_code}' "$PAGE_URL/anything")" = 404 ]
  [ -z "$(ls -A "$PAGE_INBOX")" ]
}

@test "the page shows each status the root unit writes, escaped, and tolerates a broken status file" {
  printf '{"state":"registered","message":"Registered with <b>x</b>.","url":"https://github.com/octo/repo","updated":"2026-11-28T01:00:00Z"}' \
    >"$BATS_TEST_TMPDIR/status.json"
  start_page github
  page_get
  grep -qF 'Registered with &lt;b&gt;x&lt;/b&gt;.' "$F/page.html"
  grep -qF 'Registered with <code>https://github.com/octo/repo</code>.' "$F/page.html"
  grep -qF 'class="state-registered"' "$F/page.html"
  refute_grep -qF 'http-equiv="refresh"' "$F/page.html"
  printf '{"state":"failed","message":"GitHub did not accept this address and token.","url":"","updated":""}' >"$PAGE_STATUS"
  page_get
  grep -qF 'Registration failed: GitHub did not accept this address and token.' "$F/page.html"
  printf '{"state":"working","message":"Registering with https://github.com/octo/repo.","url":"","updated":""}' >"$PAGE_STATUS"
  page_get
  grep -qF '<meta http-equiv="refresh" content="5">' "$F/page.html"
  printf 'not json' >"$PAGE_STATUS"
  page_get
  grep -qF 'The status cannot be read right now.' "$F/page.html"
  rm -f "$PAGE_STATUS"
  page_get
  grep -qF 'The status cannot be read right now.' "$F/page.html"
}

@test "the page logs method, path and status only: no query, header or body" {
  start_page github
  page_get
  real_curl -sS -o /dev/null "$PAGE_URL/?token=$TOKEN" -H "X-Token: $TOKEN"
  page_post --data-urlencode "csrf=$(csrf_of "$F/page.html")" --data-urlencode 'url=https://github.com/octo' \
    --data-urlencode "token=$TOKEN" >/dev/null
  refute_grep -qF "$TOKEN" "$PAGE_LOG"
  grep -qxF 'GET / 200' "$PAGE_LOG"
}

@test "the page refuses to start without a known kind" {
  command -v python3 >/dev/null || skip "no python3 on this machine"
  run env RUNNER_KIND=other python3 -I "$COMMON_DIR/page.py"
  [ "$status" -ne 0 ]
  [[ "$output" == *"RUNNER_KIND must be github or gitlab"* ]]
}
