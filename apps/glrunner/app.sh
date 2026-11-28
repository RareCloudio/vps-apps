#!/usr/bin/env bash
# The "glrunner" app: GitLab Runner with the Docker executor, registered from a page on the server.
# Sourced by install.sh, by rc and by the register unit, never executed. It implements the hook
# contract described in apps/docker/app.sh. The registration page, its login and the register unit
# are shared with ghrunner: apps/_runner-common/runner.sh explains that flow.
#
# The runner is the official gitlab/gitlab-runner image (the Alpine flavor), run as GitLab
# documents it in a container, with the host's Docker socket for the Docker executor
# (https://docs.gitlab.com/runner/install/docker/). Every job runs in containers of its own, and
# jobs get the Docker socket too, so they can build and run images (a job image such as docker:cli
# uses it). The runner is registered with a runner authentication token (glrt-), GitLab's runner
# creation flow since 16.0; registration tokens are deprecated (https://docs.gitlab.com/runner/register/).
#
# Versions: GitLab Runner has no tag per major version, only floating ones (latest, alpine) and one
# per release (alpine-vX.Y.Z). The install takes the newest release and pins both: the exact tag in
# GITLAB_RUNNER_IMAGE_REF and its digest. rc update then moves to the newest release of the same
# major version (app_update_env), never to the next major, whose removals and changed defaults need
# a look first (https://docs.gitlab.com/update/deprecations/).

VA_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VA_RUNNER_APP=glrunner
VA_RUNNER_KIND=gitlab
# shellcheck source=apps/_runner-common/runner.sh
. "$VA_APP_DIR/../_runner-common/runner.sh"

VA_GLR_REPO="gitlab/gitlab-runner"
# Docker Hub's tag list, newest first; the name filter is a substring match.
VA_GLR_TAGS_URL="https://hub.docker.com/v2/repositories/gitlab/gitlab-runner/tags?page_size=100&ordering=last_updated&name="
# The image a job runs in when its .gitlab-ci.yml names none.
VA_GLR_JOB_IMAGE="ubuntu:24.04"
VA_GLR_CONFIG=/etc/gitlab-runner/config.toml
VA_GLR_CANDIDATE=/etc/gitlab-runner/config.new.toml
VA_GLR_PREVIOUS=/etc/gitlab-runner/config.old.toml

# glr_newest_release [major]: the highest X.Y.Z (of that major, when given) among the alpine-vX.Y.Z
# tags Docker Hub lists for gitlab/gitlab-runner. Release candidates and other flavors do not count.
# Fails when there is none or the answer cannot be read.
glr_newest_release() {
  local body v
  body="$(curl -fsS --max-time 30 "${VA_GLR_TAGS_URL}alpine-v${1:+$1.}")" || return 1
  v="$(jq -r --arg m "${1:-[0-9]+}" '[.results[]? | .name | strings
    | select(test("^alpine-v" + $m + "\\.[0-9]+\\.[0-9]+$")) | ltrimstr("alpine-v")]
    | sort_by(split(".") | map(tonumber)) | last // empty' <<<"$body" 2>/dev/null)" || return 1
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  if [ -n "${1:-}" ] && [ "${v%%.*}" != "$1" ]; then
    return 1
  fi
  printf '%s\n' "$v"
}

# glr_version_gt <a> <b>: version a is newer than b.
glr_version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

# app_prepare: the page's user and host side (runner.sh), then the .env, created once with the
# newest GitLab Runner release and the page image, each pinned by digest. An existing .env is kept
# as it is.
# shellcheck disable=SC2034 # vars is filled and read through namerefs (runner.sh)
app_prepare() {
  local data version image
  data="$(app_data_dir)"
  mkdir -p "$data" || return 1
  runner_prepare_page || return 1
  [ ! -f "$data/.env" ] || return 0
  if ! version="$(glr_newest_release)"; then
    log "glrunner: cannot read the GitLab Runner releases from Docker Hub"
    return 1
  fi
  image="$(resolve_image_digest "$VA_GLR_REPO:alpine-v$version")" || return 1
  local -A vars=()
  runner_page_env_vars vars || return 1
  vars[GITLAB_RUNNER_IMAGE]="$image"
  vars[GITLAB_RUNNER_IMAGE_REF]="$VA_GLR_REPO:alpine-v$version"
  runner_render_env vars | write_atomic "$data/.env" 0600
}

# app_up_setup: the runner (unregistered: it waits for a config.toml with a runner) and the page,
# without exposure.
app_up_setup() {
  app_compose up -d
}

# app_update_env <env-file> <out-file>: rc update's hook. Every image re-resolved from its tag
# (lib/images.sh), then GitLab Runner moved to the newest release of the major version it runs
# (glr_hold_major). <env-file> itself is not written. Fails when an image cannot be resolved.
app_update_env() {
  resolve_env_images "$1" "$2" || return 1
  glr_hold_major "$2"
}

# glr_hold_major <out-file>: when Docker Hub lists a newer alpine-vX.Y.Z of the major version in
# <out-file>'s GITLAB_RUNNER_IMAGE_REF, both GitLab Runner lines move to it. Says what it did on
# stdout, which rc update prints once the files are written. Any doubt keeps GitLab Runner where it
# is; it fails only when <out-file> cannot be written.
glr_hold_major() {
  local ref have major newest pinned
  ref="$(runner_env_get "$1" GITLAB_RUNNER_IMAGE_REF)"
  if [[ ! "$ref" =~ ^gitlab/gitlab-runner:alpine-v([0-9]+)\.[0-9]+\.[0-9]+$ ]]; then
    echo "rc update: GITLAB_RUNNER_IMAGE_REF is not a GitLab Runner release tag, so it is refreshed as it is"
    return 0
  fi
  major="${BASH_REMATCH[1]}"
  have="${ref#gitlab/gitlab-runner:alpine-v}"
  if ! newest="$(glr_newest_release "$major")"; then
    echo "rc update: cannot find a GitLab Runner $major.x release on Docker Hub, so GitLab Runner stays on $have"
    return 0
  fi
  if ! glr_version_gt "$newest" "$have"; then
    echo "rc update: GitLab Runner stays on $have, the newest $major.x release"
    return 0
  fi
  if ! pinned="$(resolve_image_digest "$VA_GLR_REPO:alpine-v$newest")"; then
    echo "rc update: cannot resolve GitLab Runner $newest, so GitLab Runner stays on $have"
    return 0
  fi
  runner_env_put "$1" GITLAB_RUNNER_IMAGE "$pinned" || return 1
  runner_env_put "$1" GITLAB_RUNNER_IMAGE_REF "$VA_GLR_REPO:alpine-v$newest" || return 1
  echo "rc update: GitLab Runner moves to $newest, the newest $major.x release"
}

# glr_concurrent: how many jobs run at once: one for every 2 GB of memory, at most one per CPU, at
# least one. On the 2 GB minimum plan that is one, so a job has the memory to itself.
glr_concurrent() {
  local kib cpus n
  kib="$(awk '$1 == "MemTotal:" { print $2; exit }' "$(p /proc/meminfo)" 2>/dev/null)"
  cpus="$(nproc 2>/dev/null)"
  [[ "$kib" =~ ^[0-9]+$ ]] || kib=0
  [[ "$cpus" =~ ^[0-9]+$ ]] || cpus=1
  n=$(((kib / 1024 + 512) / 2048))
  [ "$n" -le "$cpus" ] || n="$cpus"
  [ "$n" -ge 1 ] || n=1
  printf '%s\n' "$n"
}

# glr_global_config <concurrent>: the global part of config.toml, the values gitlab-runner writes
# itself for a new file, with our concurrent
# (https://docs.gitlab.com/runner/configuration/advanced-configuration/).
glr_global_config() {
  printf 'concurrent = %s\ncheck_interval = 0\nshutdown_timeout = 0\n\n[session_server]\n  session_timeout = 1800\n' "$1"
}

# glr_exec <command...>: a command in the runner container, as its root.
glr_exec() {
  app_compose exec -T gitlab-runner "$@"
}

# glr_failure <output-file> <url>: the short reason the page shows for a failed register.
glr_failure() {
  local text
  text="$(cat "$1" 2>/dev/null)"
  # A failed verification ends with "Failed to verify the runner." whatever the cause, so the
  # network errors are looked for first.
  case "$text" in
    *"no such host"* | *"connection refused"* | *"i/o timeout"* | *x509* | *certificate* | *"dial tcp"*)
      echo "This server could not reach $2 over HTTPS. Check the address."
      ;;
    *"Failed to verify"* | *"is not valid"* | *"403 Forbidden"* | *"401 Unauthorized"* | *"410 Gone"*)
      echo "GitLab did not accept this token. Use the runner authentication token (glrt-) of a runner that still exists in GitLab."
      ;;
    *)
      echo "The registration failed. Details: journalctl -u vps-apps-glrunner-register"
      ;;
  esac
}

# runner_register <url>: the runner registered with GitLab from the token in RUNNER_TOKEN, with
# gitlab-runner register in the runner container. The token reaches it as CI_SERVER_TOKEN, the
# environment variable of --token (RunnerCredentials in common/config.go): docker compose exec -e
# CI_SERVER_TOKEN takes the value from this function's own environment, so it is on no command line,
# docker's or the container's. register's output goes to the journal with the token taken out.
#
# The new runner goes into a config file of its own first, with the global settings and
# concurrent (glr_concurrent); only when GitLab verified the token does that file replace
# config.toml, which the runner reloads (it checks every 3 seconds, and on SIGHUP). The runners of
# the old config.toml are unregistered only after that, from a copy taken before, best effort: for
# a runner created in GitLab's UI that removes this server's runner manager, not the runner, which
# stays in GitLab until deleted there (https://docs.gitlab.com/runner/commands/). A failed attempt,
# including a new config that cannot be saved, changes nothing: the runner keeps the config.toml it
# had and stays registered.
runner_register() {
  local url="$1" name out rc=0 had=no
  name="$(runner_name)"
  out="$(runner_run_dir)/work/out"
  RUNNER_KEPT=yes
  if ! app_compose up -d gitlab-runner >"$out" 2>&1; then
    runner_redact "$RUNNER_TOKEN" <"$out"
    rm -f "$out"
    RUNNER_RESULT="GitLab Runner does not start on this server. Details: journalctl -u vps-apps-glrunner-register"
    return 1
  fi
  if ! glr_global_config "$(glr_concurrent)" | glr_exec sh -c "umask 077 && cat >$VA_GLR_CANDIDATE"; then
    rm -f "$out"
    RUNNER_RESULT="The registration failed. Details: journalctl -u vps-apps-glrunner-register"
    return 1
  fi
  (
    export CI_SERVER_TOKEN="$RUNNER_TOKEN"
    app_compose exec -T -e CI_SERVER_TOKEN gitlab-runner gitlab-runner register --non-interactive \
      --config "$VA_GLR_CANDIDATE" --url "$url" --description "$name" --executor docker \
      --docker-image "$VA_GLR_JOB_IMAGE" \
      --docker-volumes /var/run/docker.sock:/var/run/docker.sock --docker-volumes /cache
  ) </dev/null >"$out" 2>&1 || rc=$?
  runner_redact "$RUNNER_TOKEN" <"$out"
  if [ "$rc" -eq 0 ] && glr_exec grep -q '^\[\[runners\]\]' "$VA_GLR_CANDIDATE" </dev/null >/dev/null 2>&1; then
    rm -f "$out"
    # A copy of the old config first; config.toml itself stays in place until the new one replaces
    # it in one rename, and the old runners are unregistered from the copy only after that.
    if glr_exec cp -f "$VA_GLR_CONFIG" "$VA_GLR_PREVIOUS" </dev/null >/dev/null 2>&1; then
      had=yes
    else
      glr_exec rm -f "$VA_GLR_PREVIOUS" </dev/null >/dev/null 2>&1 || true
    fi
    if ! glr_exec mv -f "$VA_GLR_CANDIDATE" "$VA_GLR_CONFIG" </dev/null; then
      glr_exec rm -f "$VA_GLR_CANDIDATE" </dev/null >/dev/null 2>&1 || true
      glr_exec rm -f "$VA_GLR_PREVIOUS" </dev/null >/dev/null 2>&1 || true
      RUNNER_RESULT="The new registration could not be saved. Details: journalctl -u vps-apps-glrunner-register."
      if [ -n "$(runner_status_url)" ]; then
        RUNNER_RESULT+=" The runner stays registered as before."
      fi
      return 1
    fi
    app_compose kill -s SIGHUP gitlab-runner >/dev/null 2>&1 || true
    if [ "$had" = yes ]; then
      # Best effort, and bounded: a GitLab that accepts connections but never answers must not hold
      # the register unit past its own timeout while config.toml already runs the new runner.
      glr_exec timeout 60 gitlab-runner unregister --all-runners --config "$VA_GLR_PREVIOUS" </dev/null >/dev/null 2>&1 || true
      glr_exec rm -f "$VA_GLR_PREVIOUS" </dev/null >/dev/null 2>&1 || true
    fi
    RUNNER_RESULT="Registered with $url as $name. The runner is waiting for jobs."
    return 0
  fi
  runner_say "gitlab-runner register failed (exit $rc)"
  RUNNER_RESULT="$(glr_failure "$out" "$url")"
  rm -f "$out"
  glr_exec rm -f "$VA_GLR_CANDIDATE" </dev/null >/dev/null 2>&1 || true
  if [ -n "$(runner_status_url)" ]; then
    RUNNER_RESULT+=" The runner stays registered as before."
  fi
  return 1
}
