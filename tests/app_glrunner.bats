#!/usr/bin/env bats
# The glrunner app. The registration page, its login and the root unit it shares with ghrunner are
# covered in tests/app_ghrunner.bats; this file covers GitLab Runner itself and what differs for
# GitLab on the shared parts.
load test_helper

# Token prefixes kept out of the fixtures' text, so the CI gitleaks step does not read a test
# token as a real one: the fixtures that carry a prefix are built from these at run time.
GLRT=glrt- GLPAT=glpat- GRRT=GR1348941

setup() {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  APP_DIR="$ROOT_DIR/apps/glrunner"
  COMMON_DIR="$ROOT_DIR/apps/_runner-common"
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
  # shellcheck source=../apps/glrunner/app.sh
  . "$APP_DIR/app.sh"
  VA_HOST=glrunner-ab12cd.example.com
  export VA_HOST
  DATA="$(p /opt/vps-apps-data/glrunner)"
  RUN="$(p /run/vps-apps-glrunner)"
  F="$BATS_TEST_TMPDIR/f"
  mkdir -p "$F"
  PWF="$BATS_TEST_TMPDIR/password"
  printf '%s' 'Secret123' >"$PWF"
  VA_PASSWORD_FILE="$PWF"
  TOKEN="$(printf '%st1_AbCdEfGhIjKlMnOpQrStUv' "$GLRT")"
  fake_host
  mkdir -p "$(p /opt/vps-apps-data/proxy)"
  printf 'CADDY_IMAGE=lucaslorentz/caddy-docker-proxy@sha256:%s\n' "$(printf 'c%.0s' $(seq 64))" \
    >"$(p /opt/vps-apps-data/proxy/.env)"
  mkdir -p "$(p /proc)"
  printf 'MemTotal:        2014352 kB\nMemFree:          100000 kB\n' >"$(p /proc/meminfo)"
  nproc() { echo 2; }
  TAGS_BODY="$(tags_json alpine-v19.6.1 alpine-v19.4.5 alpine-v19.5.4 alpine-v20.0.0-rc1 alpine3.21-v20.1.0 \
    alpine-v19.6.0 latest alpine)"
  stub_curl
  stub_docker
}

# fake_host: users and ownership as functions, since the tests do not run as root (every user gets
# the test's own uid and gid, so the files a test writes belong to "the page user").
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
}

# tags_json <name...>: Docker Hub's tag list with these names.
tags_json() {
  jq -n '{count: ($ARGS.positional | length), results: [$ARGS.positional[] | {name: .}]}' --args "$@"
}

# stub_curl: Docker Hub's tag list answers TAGS_BODY, or fails when $F/hub_fail exists. Every call
# is logged in $F/curl_calls.
stub_curl() {
  curl() {
    printf '%s\n' "$*" >>"$F/curl_calls"
    case "$*" in
      *hub.docker.com/v2/repositories/gitlab/gitlab-runner/tags*)
        [ ! -e "$F/hub_fail" ] || return 22
        printf '%s' "$TAGS_BODY"
        ;;
    esac
    return 0
  }
}

FAKE_HASH='$2a$14$abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0'

# stub_docker: a docker whose runner container is a directory, $F. "docker run" is the
# hash-password call. "compose ... exec" is logged in docker.log and acts on $F:
#   sh -c "umask 077 && cat >config.new.toml"   stdin into $F/candidate
#   gitlab-runner register ...                  records the CI_SERVER_TOKEN it got from its
#                                               environment (exec -e) in $F/seen_token, appends a
#                                               [[runners]] to the candidate, prints a line with the
#                                               token; fails like GitLab refusing the token when
#                                               $F/register_fail exists, or prints REGISTER_OUT
#   grep -q [[runners]] config.new.toml         on $F/candidate
#   gitlab-runner unregister ...                "unregister" in $F/events; with --config
#                                               config.old.toml, the runners of $F/old in
#                                               $F/unregistered
#   cp -f config.toml config.old.toml           $F/config to $F/old (fails without $F/config)
#   mv -f config.new.toml config.toml           $F/candidate to $F/config; fails when $F/mv_fail
#                                               exists
#   rm -f config.new.toml, config.old.toml      removes $F/candidate, $F/old
# Every other call goes to the stub on PATH.
stub_docker() {
  docker() {
    if [ "${1:-}" = run ]; then
      printf '%s\n' "$*" >>"$STUB_TMP/docker.log"
      cat >"$F/hash_stdin"
      printf '%s\n' "$FAKE_HASH"
      return 0
    fi
    if [[ " $* " != *" exec "* ]]; then
      command docker "$@"
      return
    fi
    printf '%s\n' "$*" >>"$STUB_TMP/docker.log"
    local all="$*"
    printf '%s\n' "${all##* gitlab-runner }" >>"$F/events"
    case "$*" in
      *"sh -c umask 077 && cat >/etc/gitlab-runner/config.new.toml")
        [ ! -e "$F/write_fail" ] || return 1
        cat >"$F/candidate"
        ;;
      *" gitlab-runner register "*)
        if [[ " $* " == *" -e CI_SERVER_TOKEN "* ]]; then printf '%s' "${CI_SERVER_TOKEN-}" >"$F/seen_token"; fi
        if [ -e "$F/register_fail" ]; then
          printf '%s\n' "${REGISTER_OUT-ERROR: Verifying runner... is not valid  runner=${CI_SERVER_TOKEN:5:9}}" \
            'PANIC: Failed to verify the runner.'
          return 1
        fi
        printf '\n[[runners]]\n  name = "glrunner-ab12cd"\n  token = "%s"\n' "$CI_SERVER_TOKEN" >>"$F/candidate"
        echo "Runner registered successfully (token $CI_SERVER_TOKEN)."
        ;;
      *" grep -q "*) grep -q '^\[\[runners\]\]' "$F/candidate" 2>/dev/null ;;
      *" gitlab-runner unregister --all-runners --config /etc/gitlab-runner/config.old.toml")
        grep '^  token = ' "$F/old" >>"$F/unregistered" 2>/dev/null || true
        ;;
      *" cp -f /etc/gitlab-runner/config.toml /etc/gitlab-runner/config.old.toml") cp -f "$F/config" "$F/old" ;;
      *" mv -f /etc/gitlab-runner/config.new.toml /etc/gitlab-runner/config.toml")
        [ ! -e "$F/mv_fail" ] || return 1
        mv -f "$F/candidate" "$F/config"
        ;;
      *" rm -f /etc/gitlab-runner/config.new.toml") rm -f "$F/candidate" ;;
      *" rm -f /etc/gitlab-runner/config.old.toml") rm -f "$F/old" ;;
    esac
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

digest_of() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

@test "app_prepare pins the newest GitLab Runner release by its exact tag and digest, and the page image" {
  app_prepare
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  grep -qxF 'GITLAB_RUNNER_IMAGE_REF=gitlab/gitlab-runner:alpine-v19.6.1' "$DATA/.env"
  grep -qxF "GITLAB_RUNNER_IMAGE=gitlab/gitlab-runner@sha256:$(digest_of gitlab/gitlab-runner:alpine-v19.6.1)" "$DATA/.env"
  grep -qxF "PAGE_IMAGE=python@sha256:$(digest_of python:3.14-alpine)" "$DATA/.env"
  grep -qxF 'PAGE_IMAGE_REF=python:3.14-alpine' "$DATA/.env"
  grep -qxF "PAGE_UID=$ME_UID" "$DATA/.env"
  grep -qxF 'VA_SITE_ADDRS="glrunner-ab12cd.example.com"' "$DATA/.env"
  grep -qF 'https://hub.docker.com/v2/repositories/gitlab/gitlab-runner/tags?page_size=100&ordering=last_updated&name=alpine-v' "$F/curl_calls"
  refute_grep -q '@[A-Z_]*@' "$DATA/.env"
}

@test "the newest release is the highest version, not the latest upload, and never a release candidate or another flavor" {
  TAGS_BODY="$(tags_json alpine-v19.10.0 alpine-v19.9.3 alpine-v20.0.0-rc1 alpine3.21-v21.0.0 ubuntu-v22.0.0 alpine-v19.10)"
  [ "$(glr_newest_release)" = 19.10.0 ]
  TAGS_BODY="$(tags_json alpine-v19.9.3 alpine-v19.10.2 alpine-v20.1.0)"
  [ "$(glr_newest_release 19)" = 19.10.2 ]
  grep -qF 'name=alpine-v19.' "$F/curl_calls"
  for body in "$(tags_json alpine-v20.0.0-rc1 latest alpine)" '{"results":[]}' 'not json' ''; do
    TAGS_BODY="$body" run glr_newest_release
    [ "$status" -ne 0 ]
  done
  TAGS_BODY="$(tags_json alpine-v20.1.0)" run glr_newest_release 19
  [ "$status" -ne 0 ]
}

@test "GitLab Runner is never installed from latest, alpine or another floating tag" {
  app_prepare
  refute_grep -qE '^GITLAB_RUNNER_IMAGE_REF=.*:(latest|alpine|ubuntu|bleeding)$' "$DATA/.env"
  refute_grep -q ':latest' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl" "$APP_DIR/app.sh"
  grep -qxF 'buildx imagetools inspect gitlab/gitlab-runner:alpine-v19.6.1 --format {{json .Manifest}}' "$STUB_TMP/docker.log"
}

@test "no release list, or an image that cannot be resolved, fails app_prepare and leaves no .env" {
  : >"$F/hub_fail"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
  rm -f "$F/hub_fail"
  printf 'gitlab-runner:alpine-v19' >"$STUB_TMP/inspect_fail_match"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
}

@test "a second app_prepare keeps the .env byte for byte and asks Docker Hub nothing" {
  app_prepare
  app_create_admin "$PWF"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  : >"$F/curl_calls"
  app_prepare
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  [ ! -s "$F/curl_calls" ]
}

@test "app_prepare sets up the page user, the inbox and the register units for glrunner, and no runner user" {
  app_prepare
  grep -qxF 'useradd --system --user-group --shell /usr/sbin/nologin --no-create-home --home-dir /nonexistent vps-apps-page' "$STUB_TMP/calls.log"
  refute_grep -q 'ghrunner\|usermod' "$STUB_TMP/calls.log"
  [ "$(stat -c %a "$RUN/inbox")" = 700 ]
  [ "$(stat -c %a "$RUN/work")" = 700 ]
  grep -qxF 'PathExists=/run/vps-apps-glrunner/inbox/request' "$(p /etc/systemd/system/vps-apps-glrunner-register.path)"
  grep -qxF 'ExecStart=/bin/bash /opt/vps-apps/current/apps/_runner-common/register.sh glrunner' \
    "$(p /etc/systemd/system/vps-apps-glrunner-register.service)"
  grep -qxF 'd /run/vps-apps-glrunner/inbox 0700 vps-apps-page vps-apps-page -' "$(p /etc/tmpfiles.d/vps-apps-glrunner.conf)"
  grep -qxF 'enable --now vps-apps-glrunner-register.path' "$STUB_TMP/systemctl.log"
  [ "$(jq -r .state "$DATA/status/status.json")" = none ]
}

@test "the runner container has the Docker socket and its config volume, and publishes nothing" {
  app_prepare
  cfg="$(merged_config compose.yml)"
  [ "$(jq -r '.services | keys | join(",")' <<<"$cfg")" = gitlab-runner,page ]
  [ "$(jq -r '.services["gitlab-runner"].volumes | map("\(.source):\(.target)") | join(" ")' <<<"$cfg")" = \
    "gitlab_runner_config:/etc/gitlab-runner /var/run/docker.sock:/var/run/docker.sock" ]
  [ "$(jq -r '.services["gitlab-runner"].ports // [] | length' <<<"$cfg")" = 0 ]
  [ "$(jq -r '.services["gitlab-runner"].labels // {} | length' <<<"$cfg")" = 0 ]
  [ "$(jq -r '.services["gitlab-runner"].image' <<<"$cfg")" = \
    "gitlab/gitlab-runner@sha256:$(digest_of gitlab/gitlab-runner:alpine-v19.6.1)" ]
  [ "$(jq -r '.services["gitlab-runner"].restart' <<<"$cfg")" = unless-stopped ]
}

@test "the page has no Docker socket and runs unprivileged, as for ghrunner, with the GitLab kind" {
  app_prepare
  cfg="$(merged_config compose.yml)"
  [ "$(jq -r '[.services.page.volumes[].source | select(test("docker"))] | length' <<<"$cfg")" = 0 ]
  [ "$(jq -r .services.page.user <<<"$cfg")" = "$ME_UID:$ME_GID" ]
  [ "$(jq -r .services.page.read_only <<<"$cfg")" = true ]
  [ "$(jq -r '.services.page.cap_drop | join(",")' <<<"$cfg")" = ALL ]
  [ "$(jq -r '.services.page.environment.RUNNER_KIND' <<<"$cfg")" = gitlab ]
  [ "$(jq -r '.services.page.volumes[1].source' <<<"$cfg")" = /run/vps-apps-glrunner/inbox ]
  [ "$(jq -r '.services.page.volumes[2] | "\(.source) \(.read_only)"' <<<"$cfg")" = "/opt/vps-apps-data/glrunner/status true" ]
  [ "$(jq -r '.services.page.ports // [] | length' <<<"$cfg")" = 0 ]
  # The page service is the same as ghrunner's but for the app's own paths and kind.
  diff <(sed -n '/^  page:/,/^volumes:/p' "$APP_DIR/compose.yml" | grep -v '^volumes:' | grep -v '^$' | sed 's/glrunner/APP/g; s/gitlab/KIND/') \
    <(sed -n '/^  page:/,$p' "$ROOT_DIR/apps/ghrunner/compose.yml" | sed 's/ghrunner/APP/g; s/github/KIND/')
  cmp "$APP_DIR/compose.expose.yml" "$ROOT_DIR/apps/ghrunner/compose.expose.yml"
}

@test "after exposure the page alone joins the proxy network behind the login; the runner stays off it" {
  app_prepare
  app_create_admin "$PWF"
  cfg="$(merged_config compose.yml compose.expose.yml)"
  [ "$(jq -r '.services.page.networks | keys | join(",")' <<<"$cfg")" = web ]
  [ "$(jq -r '.services["gitlab-runner"].networks | keys | join(",")' <<<"$cfg")" = default ]
  [ "$(jq -r '.services.page.labels["caddy.basic_auth.admin"] | gsub("\\$\\$"; "$")' <<<"$cfg")" = "$FAKE_HASH" ]
  [ "$(jq -r '.services.page.labels.caddy' <<<"$cfg")" = glrunner-ab12cd.example.com ]
  [ "$(jq -r '.services["gitlab-runner"].labels // {} | length' <<<"$cfg")" = 0 ]
}

@test "app_up_setup starts the runner and the page without exposure" {
  app_prepare
  : >"$STUB_TMP/docker.log"
  app_up_setup
  grep -qxF "compose -f $APP_DIR/compose.yml --env-file $DATA/.env up -d" "$STUB_TMP/docker.log"
  [ ! -e "$DATA/exposed" ]
}

# request <json>: what the page would leave in the inbox, as the page user.
request() {
  (
    umask 077
    printf '%s' "$1" >"$RUN/inbox/request"
  )
}

@test "a valid request registers with gitlab-runner register, the token only through exec -e from the environment" {
  app_prepare
  request "{\"url\":\"https://gitlab.example.com\",\"token\":\"$TOKEN\"}"
  run runner_handle_request
  [ "$status" -eq 0 ]
  [ "$(cat "$F/seen_token")" = "$TOKEN" ]
  c="compose -f $APP_DIR/compose.yml --env-file $DATA/.env"
  grep -qxF "$c up -d gitlab-runner" "$STUB_TMP/docker.log"
  grep -qxF "$c exec -T -e CI_SERVER_TOKEN gitlab-runner gitlab-runner register --non-interactive --config /etc/gitlab-runner/config.new.toml --url https://gitlab.example.com --description glrunner-ab12cd --executor docker --docker-image ubuntu:24.04 --docker-volumes /var/run/docker.sock:/var/run/docker.sock --docker-volumes /cache" "$STUB_TMP/docker.log"
  grep -qxF "$c kill -s SIGHUP gitlab-runner" "$STUB_TMP/docker.log"
  # The new config: the global settings, then the runner; it replaced config.toml. A first
  # registration has no earlier runners to unregister.
  [ "$(head -n 1 "$F/config")" = "concurrent = 1" ]
  grep -qxF '[[runners]]' "$F/config"
  [ ! -e "$F/candidate" ]
  [ ! -e "$F/old" ]
  refute_grep -q '^unregister' "$F/events"
  write="$(grep -n 'umask 077' "$F/events" | cut -d: -f1)"
  reg="$(grep -n '^register ' "$F/events" | cut -d: -f1)"
  mv="$(grep -n 'mv -f' "$F/events" | cut -d: -f1)"
  [ "$write" -lt "$reg" ]
  [ "$reg" -lt "$mv" ]
  st="$DATA/status/status.json"
  [ "$(jq -r .state "$st")" = registered ]
  [ "$(jq -r .url "$st")" = https://gitlab.example.com ]
  [ "$(jq -r .message "$st")" = "Registered with https://gitlab.example.com as glrunner-ab12cd. The runner is waiting for jobs." ]
  # Never on a command line, in a log, in the status or in a file of the server; only in the
  # runner's own config.toml (here $F/config), where it is the runner's credential.
  [[ "$output" == *"Runner registered successfully (token [hidden])."* ]]
  [[ "$output" != *"${TOKEN:5:8}"* ]]
  refute_grep -rqF "$TOKEN" "$STUB_TMP/docker.log" "$STUB_TMP/systemctl.log" "$RUN" "$DATA" "$(p /etc)" "$(p /var/log)" 2>/dev/null
  refute_grep -qF "${TOKEN:5:8}" "$STUB_TMP/docker.log"
  [ ! -e "$RUN/inbox/request" ]
}

@test "a token GitLab refuses leaves config.toml as it was, with a short reason and no token in the output" {
  app_prepare
  printf 'concurrent = 1\n[[runners]]\n  token = "glrt-old"\n' >"$F/config"
  cp "$F/config" "$BATS_TEST_TMPDIR/config.before"
  runner_write_status registered "Registered." https://gitlab.com
  : >"$F/register_fail"
  request "{\"url\":\"https://gitlab.example.com\",\"token\":\"$TOKEN\"}"
  run runner_handle_request
  [ "$status" -ne 0 ]
  cmp "$F/config" "$BATS_TEST_TMPDIR/config.before"
  [ ! -e "$F/candidate" ]
  refute_grep -q '^unregister' "$F/events"
  refute_grep -q 'mv -f' "$F/events"
  st="$DATA/status/status.json"
  [ "$(jq -r .state "$st")" = failed ]
  [ "$(jq -r .message "$st")" = "GitLab did not accept this token. Use the runner authentication token (glrt-) of a runner that still exists in GitLab. The runner stays registered as before." ]
  [ "$(jq -r .url "$st")" = https://gitlab.com ]
  [[ "$output" == *"Failed to verify the runner."* ]]
  [[ "$output" != *"${TOKEN:5:9}"* ]]
}

@test "an address the server cannot reach says so" {
  app_prepare
  : >"$F/register_fail"
  request "{\"url\":\"https://gitlab.example.com\",\"token\":\"$TOKEN\"}"
  REGISTER_OUT='ERROR: Verifying runner... error  error=couldn'"'"'t execute POST against https://gitlab.example.com/api/v4/runners/verify: dial tcp: lookup gitlab.example.com: no such host' \
    run runner_handle_request
  [ "$status" -ne 0 ]
  [ "$(jq -r .message "$DATA/status/status.json")" = "This server could not reach https://gitlab.example.com over HTTPS. Check the address." ]
  [ "$(jq -r .url "$DATA/status/status.json")" = "" ]
}

@test "a config that cannot be written, or a runner that does not start, fails before any register call" {
  app_prepare
  : >"$F/write_fail"
  request "{\"url\":\"https://gitlab.com\",\"token\":\"$TOKEN\"}"
  run runner_handle_request
  [ "$status" -ne 0 ]
  refute_grep -q '^register ' "$F/events"
  rm -f "$F/write_fail"
  eval "$(declare -f docker | sed '1s/docker/docker_fake/')"
  docker() {
    [[ "$*" != *" up -d gitlab-runner" ]] || return 1
    docker_fake "$@"
  }
  request "{\"url\":\"https://gitlab.com\",\"token\":\"$TOKEN\"}"
  run runner_handle_request
  [ "$status" -ne 0 ]
  refute_grep -q '^register ' "$F/events"
  [ "$(jq -r .message "$DATA/status/status.json")" = "GitLab Runner does not start on this server. Details: journalctl -u vps-apps-glrunner-register" ]
}

@test "registering again replaces the runner: the old runners are unregistered and config.toml holds only the new one" {
  app_prepare
  request "{\"url\":\"https://gitlab.com\",\"token\":\"$TOKEN\"}"
  runner_handle_request
  request "{\"url\":\"https://gitlab.example.com\",\"token\":\"${GLRT}ZyXwVuTsRqPoNmLkJiHgFe\"}"
  runner_handle_request
  [ "$(grep -c '^\[\[runners\]\]' "$F/config")" -eq 1 ]
  grep -qF "${GLRT}ZyXwVuTsRqPoNmLkJiHgFe" "$F/config"
  # The old runners are unregistered from a copy of the old config, and only after the new config
  # is saved: a failure on the way never leaves the server without a runner.
  [ "$(grep -c '^unregister' "$F/events")" -eq 1 ]
  grep -qF 'gitlab-runner unregister --all-runners --config /etc/gitlab-runner/config.old.toml' "$STUB_TMP/docker.log"
  [ "$(cat "$F/unregistered")" = "  token = \"$TOKEN\"" ]
  cp_at="$(grep -n 'cp -f' "$F/events" | tail -n 1 | cut -d: -f1)"
  mv_at="$(grep -n 'mv -f' "$F/events" | tail -n 1 | cut -d: -f1)"
  unreg_at="$(grep -n '^unregister' "$F/events" | cut -d: -f1)"
  [ "$cp_at" -lt "$mv_at" ]
  [ "$mv_at" -lt "$unreg_at" ]
  [ ! -e "$F/old" ]
  [ "$(jq -r .url "$DATA/status/status.json")" = https://gitlab.example.com ]
}

@test "a new config that cannot be saved keeps the old runner registered and unregisters nothing" {
  app_prepare
  request "{\"url\":\"https://gitlab.com\",\"token\":\"$TOKEN\"}"
  runner_handle_request
  cp "$F/config" "$BATS_TEST_TMPDIR/config.before"
  : >"$F/mv_fail"
  request "{\"url\":\"https://gitlab.example.com\",\"token\":\"${GLRT}ZyXwVuTsRqPoNmLkJiHgFe\"}"
  run runner_handle_request
  [ "$status" -ne 0 ]
  cmp "$F/config" "$BATS_TEST_TMPDIR/config.before"
  refute_grep -q '^unregister' "$F/events"
  [ ! -e "$F/old" ]
  [ ! -e "$F/candidate" ]
  st="$DATA/status/status.json"
  [ "$(jq -r .state "$st")" = failed ]
  [ "$(jq -r .message "$st")" = "The new registration could not be saved. Details: journalctl -u vps-apps-glrunner-register. The runner stays registered as before." ]
  [ "$(jq -r .url "$st")" = https://gitlab.com ]
}

@test "registration and legacy or personal tokens are refused before any GitLab call" {
  app_prepare
  for t in "${GRRT}abcdefghijklmnopqrst" "${GLPAT}abcdefghijklmnopqrstu" glrt-short "glrt-abc def ghi jkl mno pq"; do
    request "{\"url\":\"https://gitlab.com\",\"token\":\"$t\"}"
    run runner_handle_request
    [ "$status" -ne 0 ]
  done
  refute_grep -q '^register ' "$F/events" 2>/dev/null
}

@test "concurrent is one job per 2 GB of memory, at most one per CPU, at least one" {
  meminfo="$(p /proc/meminfo)"
  check() {
    printf 'MemTotal: %s kB\n' "$1" >"$meminfo"
    nproc() { echo "$CPUS"; }
    CPUS="$2"
    [ "$(glr_concurrent)" = "$3" ]
  }
  check 2014352 2 1
  check 4026844 2 2
  check 8152036 4 4
  check 8152036 2 2
  check 16337932 8 8
  check 524288 1 1
  rm -f "$meminfo"
  [ "$(glr_concurrent)" = 1 ]
  [ "$(glr_global_config 3 | head -n 1)" = "concurrent = 3" ]
  glr_global_config 1 | grep -qxF '  session_timeout = 1800'
}

# update_env <current ref> [current image]: an .env as installed with that ref, for app_update_env.
update_env() {
  app_prepare
  sed -i "s#^GITLAB_RUNNER_IMAGE_REF=.*#GITLAB_RUNNER_IMAGE_REF=$1#" "$DATA/.env"
  sed -i "s#^GITLAB_RUNNER_IMAGE=.*#GITLAB_RUNNER_IMAGE=${2:-gitlab/gitlab-runner@sha256:$(digest_of "$1")}#" "$DATA/.env"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
}

@test "rc update moves GitLab Runner to the newest release of its major version, never to the next" {
  update_env gitlab/gitlab-runner:alpine-v19.4.5
  TAGS_BODY="$(tags_json alpine-v19.6.1 alpine-v19.4.6 alpine-v19.6.0)"
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$output" = "rc update: GitLab Runner moves to 19.6.1, the newest 19.x release" ]
  grep -qxF 'GITLAB_RUNNER_IMAGE_REF=gitlab/gitlab-runner:alpine-v19.6.1' "$BATS_TEST_TMPDIR/out"
  grep -qxF "GITLAB_RUNNER_IMAGE=gitlab/gitlab-runner@sha256:$(digest_of gitlab/gitlab-runner:alpine-v19.6.1)" "$BATS_TEST_TMPDIR/out"
  grep -qF 'name=alpine-v19.' "$F/curl_calls"
  # The .env itself is not written, and every other line is kept.
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/before"
  diff <(grep -v '^GITLAB_RUNNER_IMAGE\|^PAGE_IMAGE=' "$BATS_TEST_TMPDIR/before") \
    <(grep -v '^GITLAB_RUNNER_IMAGE\|^PAGE_IMAGE=' "$BATS_TEST_TMPDIR/out")
}

@test "rc update keeps GitLab Runner when only a new major exists, the list fails, or nothing is newer" {
  update_env gitlab/gitlab-runner:alpine-v19.6.1
  TAGS_BODY="$(tags_json alpine-v20.0.0 alpine-v20.1.0)"
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$output" = "rc update: cannot find a GitLab Runner 19.x release on Docker Hub, so GitLab Runner stays on 19.6.1" ]
  grep -qxF 'GITLAB_RUNNER_IMAGE_REF=gitlab/gitlab-runner:alpine-v19.6.1' "$BATS_TEST_TMPDIR/out"
  TAGS_BODY="$(tags_json alpine-v19.6.1 alpine-v19.5.4 alpine-v20.0.0)"
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$output" = "rc update: GitLab Runner stays on 19.6.1, the newest 19.x release" ]
  : >"$F/hub_fail"
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stays on 19.6.1"* ]]
  # The current tag itself is still re-resolved (a re-pushed patch build).
  grep -qxF "GITLAB_RUNNER_IMAGE=gitlab/gitlab-runner@sha256:$(digest_of gitlab/gitlab-runner:alpine-v19.6.1)" "$BATS_TEST_TMPDIR/out"
}

@test "rc update keeps GitLab Runner when the newer release cannot be resolved, and fails when an image cannot" {
  update_env gitlab/gitlab-runner:alpine-v19.4.5
  TAGS_BODY="$(tags_json alpine-v19.6.1)"
  printf 'alpine-v19.6.1' >"$STUB_TMP/inspect_fail_match"
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$output" = "rc update: cannot resolve GitLab Runner 19.6.1, so GitLab Runner stays on 19.4.5" ]
  grep -qxF 'GITLAB_RUNNER_IMAGE_REF=gitlab/gitlab-runner:alpine-v19.4.5' "$BATS_TEST_TMPDIR/out"
  : >"$STUB_TMP/inspect_fail"
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
}

@test "a tag set by hand is refreshed as it is" {
  update_env gitlab/gitlab-runner:alpine
  run app_update_env "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$output" = "rc update: GITLAB_RUNNER_IMAGE_REF is not a GitLab Runner release tag, so it is refreshed as it is" ]
  grep -qxF 'GITLAB_RUNNER_IMAGE_REF=gitlab/gitlab-runner:alpine' "$BATS_TEST_TMPDIR/out"
}

@test "glrunner takes extra domains and has no app_fill_env" {
  run declare -F app_domain_check
  [ "$status" -ne 0 ]
  run declare -F app_fill_env
  [ "$status" -ne 0 ]
  declare -F app_domain_added >/dev/null
}

# --- The page for GitLab -----------------------------------------------------------------------

real_curl() {
  local d
  while IFS= read -r d; do
    [ "$d" = "$BATS_TEST_DIRNAME/stubs" ] && continue
    [ -x "$d/curl" ] && { "$d/curl" "$@"; return; }
  done < <(tr ':' '\n' <<<"$PATH")
  return 127
}

teardown() {
  if [ -n "${PAGE_PID:-}" ]; then
    kill "$PAGE_PID" 2>/dev/null || true
    wait "$PAGE_PID" 2>/dev/null || true
  fi
}

start_page() {
  command -v python3 >/dev/null || skip "no python3 on this machine"
  PAGE_INBOX="$BATS_TEST_TMPDIR/inbox"
  PAGE_LOG="$BATS_TEST_TMPDIR/page.log"
  mkdir -p "$PAGE_INBOX"
  printf '{"state":"none","message":"Not registered yet.","url":"","updated":""}' >"$BATS_TEST_TMPDIR/status.json"
  RUNNER_KIND=gitlab RUNNER_PAGE_INBOX="$PAGE_INBOX" RUNNER_PAGE_STATUS="$BATS_TEST_TMPDIR/status.json" \
    RUNNER_PAGE_BIND=127.0.0.1 RUNNER_PAGE_PORT=0 python3 -I "$COMMON_DIR/page.py" 2>"$PAGE_LOG" 3>&- &
  PAGE_PID=$!
  for _ in $(seq 100); do
    port="$(sed -n 's/^listening on \([0-9]*\)$/\1/p' "$PAGE_LOG")"
    [ -z "$port" ] || break
    sleep 0.05
  done
  [ -n "$port" ]
  PAGE_URL="http://127.0.0.1:$port"
  real_curl -sS -D "$F/page.head" -o "$F/page.html" "$PAGE_URL/"
  CSRF="$(sed -n 's/.*name="csrf" value="\([^"]*\)".*/\1/p' "$F/page.html")"
}

page_post() {
  real_curl -sS -o "$F/post.html" -w '%{http_code}' -b "rc_csrf=$CSRF" -H "Host: r.example.com" \
    -H "Origin: https://r.example.com" --data-urlencode "csrf=$CSRF" "$@" "$PAGE_URL/"
}

@test "the GitLab page explains where the glrt- token is, and queues a valid request with a normalized address" {
  start_page gitlab
  grep -qF '<title>GitLab Runner</title>' "$F/page.html"
  grep -qF 'Create project runner' "$F/page.html"
  grep -qF '<code>glrt-</code>' "$F/page.html"
  grep -qF 'Each job runs in its own container' "$F/page.html"
  [ "$(page_post --data-urlencode 'url=HTTPS://GitLab.Example.com:8443/ci/' --data-urlencode "token=$TOKEN")" = 303 ]
  [ "$(jq -c . "$PAGE_INBOX/request")" = "{\"url\":\"https://gitlab.example.com:8443/ci\",\"token\":\"$TOKEN\"}" ]
  [ "$(stat -c %a "$PAGE_INBOX/request")" = 600 ]
  refute_grep -qF "$TOKEN" "$PAGE_LOG"
}

@test "the GitLab page names a registration token, a personal token and a bad address for what they are" {
  start_page gitlab
  [ "$(page_post --data-urlencode 'url=https://gitlab.com' --data-urlencode "token=${GRRT}abcdefghijklmnopqrst")" = 400 ]
  grep -qF 'This is a registration token, which GitLab no longer uses by default.' "$F/post.html"
  [ "$(page_post --data-urlencode 'url=https://gitlab.com' --data-urlencode "token=${GLPAT}abcdefghijklmnopqrstu")" = 400 ]
  grep -qF 'This is a personal access token.' "$F/post.html"
  [ "$(page_post --data-urlencode 'url=https://gitlab.com' --data-urlencode 'token=AABBCCDDEEFFGGHHIIJJKK')" = 400 ]
  grep -qF 'It starts with glrt-.' "$F/post.html"
  [ "$(page_post --data-urlencode 'url=gitlab.com' --data-urlencode "token=$TOKEN")" = 400 ]
  grep -qF 'Enter the address of your GitLab, like https://gitlab.com.' "$F/post.html"
  refute_grep -qF "$TOKEN" "$F/post.html"
  [ -z "$(ls -A "$PAGE_INBOX")" ]
}
