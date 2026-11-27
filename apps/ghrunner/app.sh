#!/usr/bin/env bash
# The "ghrunner" app: a GitHub Actions self-hosted runner, registered from a page on the server.
# Sourced by install.sh, by rc and by the register unit, never executed. It implements the hook
# contract described in apps/docker/app.sh. The registration page, its login and the register unit
# are shared with glrunner: apps/_runner-common/runner.sh explains that flow.
#
# The runner is the official actions/runner from its release tarball, installed natively the way
# GitHub documents it (https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)
# and run by its own systemd unit as the user ghrunner, which is in the docker group so jobs can use
# the server's Docker. Not the ghcr.io/actions/actions-runner image: it is built for Actions Runner
# Controller, and run against the host's Docker it breaks the jobs that use Docker the GitHub way. A
# job with a container: gets the runner's work directory and its externals (the node that runs
# JavaScript actions inside the job container) mounted from host paths that do not exist outside the
# runner container, and the ports of services: land on the host, not where the runner is. Installed
# natively, every path and port is the host's own.
#
# The runner is a persistent one. An ephemeral runner (--ephemeral) takes one job and needs a new
# registration token for the next, and the token from GitHub's page is valid for one hour; making
# new ones needs a long-lived GitHub credential on the server, which this app does not keep. The
# page says what a persistent runner means for the customer (page.py).
#
# Versions: the newest runner release is installed and checked against the SHA-256 GitHub publishes
# for the asset. From then on the runner updates itself, which GitHub requires: a runner more than 30
# days behind a release gets no jobs, and one that updates itself meets that on its own
# (https://github.blog/changelog/2026-06-12-github-actions-minimum-version-enforcement-timeline-for-self-hosted-runners/).
# Its major version has been 2 since 2019 and the self-update stays within what GitHub serves. So
# rc update leaves the runner alone and refreshes the page's image (python:3.14-alpine) only.

VA_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VA_RUNNER_APP=ghrunner
VA_RUNNER_KIND=github
# shellcheck source=apps/_runner-common/runner.sh
. "$VA_APP_DIR/../_runner-common/runner.sh"

VA_GH_RUNNER_USER=ghrunner
VA_GH_RUNNER_HOME=/home/ghrunner
VA_GH_RUNNER_UNIT=vps-apps-ghrunner.service
VA_GH_RUNNER_RELEASE_URL="https://api.github.com/repos/actions/runner/releases/latest"
# The libraries the runner's .NET needs, by the names its bin/installdependencies.sh picks on
# Ubuntu 24.04 (https://github.com/actions/runner/blob/main/src/Misc/layoutbin/installdependencies.sh).
VA_GH_RUNNER_PACKAGES=(libkrb5-3 zlib1g liblttng-ust1t64 libssl3t64 libicu74)
# The files config.sh writes for a registration (and refuses to run over).
VA_GH_RUNNER_CREDS=(.runner .credentials .credentials_rsaparams)

gh_runner_dir() {
  p "$VA_GH_RUNNER_HOME/actions-runner"
}

# gh_as_runner <command...>: the command as the user ghrunner with its groups (docker), in an
# environment that is this one plus its own HOME and USER. That environment is the only way the
# registration token reaches config.sh.
gh_as_runner() {
  HOME="$VA_GH_RUNNER_HOME" USER="$VA_GH_RUNNER_USER" LOGNAME="$VA_GH_RUNNER_USER" \
    setpriv --reuid="$VA_GH_RUNNER_USER" --regid="$VA_GH_RUNNER_USER" --init-groups -- "$@"
}

# gh_write_unit: the runner's service, the unit svc.sh install would write
# (src/Misc/layoutbin/actions.runner.service.template), under a fixed name. It is enabled only once
# the runner is registered (runner_register).
gh_write_unit() {
  local dir
  dir="$(p /etc/systemd/system)"
  mkdir -p "$dir"
  write_atomic "$dir/$VA_GH_RUNNER_UNIT" 0644 <<UNIT
[Unit]
Description=GitHub Actions runner (vps-apps)
After=network.target docker.service

[Service]
ExecStart=$VA_GH_RUNNER_HOME/actions-runner/runsvc.sh
User=$VA_GH_RUNNER_USER
WorkingDirectory=$VA_GH_RUNNER_HOME/actions-runner
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min

[Install]
WantedBy=multi-user.target
UNIT
}

# app_prepare: the page's user and host side (runner.sh), the runner's user in the docker group and
# its unit, then the .env, created once. An existing .env is kept as it is.
# shellcheck disable=SC2034 # vars is filled and read through namerefs (runner.sh)
app_prepare() {
  local data
  data="$(app_data_dir)"
  mkdir -p "$data" || return 1
  runner_ensure_user "$VA_GH_RUNNER_USER" --create-home --home-dir "$VA_GH_RUNNER_HOME" || return 1
  usermod -aG docker "$VA_GH_RUNNER_USER" || return 1
  gh_write_unit || return 1
  runner_prepare_page || return 1
  [ ! -f "$data/.env" ] || return 0
  local -A vars=()
  runner_page_env_vars vars || return 1
  runner_render_env vars | write_atomic "$data/.env" 0600
}

# gh_arch: the runner's name for this machine's architecture.
gh_arch() {
  case "$(dpkg --print-architecture)" in
    amd64) echo x64 ;;
    arm64) echo arm64 ;;
    *) return 1 ;;
  esac
}

# gh_newest_release <arch>: "<version> <url> <sha256>" of the newest full release of actions/runner
# for this architecture, from GitHub's API. The SHA-256 is the asset's digest, which GitHub computes
# itself; the release notes list the same value between "BEGIN SHA" markers, and when both are
# there they must agree. Fails unless the version is 2.x.y and the URL is the release's own asset.
gh_newest_release() {
  local body line v url digest listed
  body="$(curl -fsS --max-time 30 -H 'Accept: application/vnd.github+json' "$VA_GH_RUNNER_RELEASE_URL")" || return 1
  # shellcheck disable=SC2016 # a jq program, not shell
  line="$(jq -r --arg arch "$1" '
    select(.draft == false and .prerelease == false)
    | (.tag_name | strings | ltrimstr("v")) as $v
    | ([.assets[]? | select(.name == ("actions-runner-linux-" + $arch + "-" + $v + ".tar.gz"))] | first // {}) as $a
    | ((.body // "") | strings
      | (try capture("<!-- BEGIN SHA linux-" + $arch + " -->(?<s>[0-9a-f]{64})<!-- END SHA linux-" + $arch + " -->").s
        catch "")) as $listed
    | [$v, ($a.browser_download_url // "-"), (($a.digest // "-") | ltrimstr("sha256:")), (if $listed == "" then "-" else $listed end)]
    | join(" ")' <<<"$body" 2>/dev/null)" || return 1
  read -r v url digest listed <<<"$line"
  [[ "$v" =~ ^2\.[0-9]+\.[0-9]+$ ]] || return 1
  [ "$url" = "https://github.com/actions/runner/releases/download/v$v/actions-runner-linux-$1-$v.tar.gz" ] || return 1
  if [ "$digest" = - ]; then
    digest="$listed"
  elif [ "$listed" != - ] && [ "$listed" != "$digest" ]; then
    return 1
  fi
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s %s %s\n' "$v" "$url" "$digest"
}

# gh_runner_installed: the runner is in place, from an earlier run or updated by itself since.
gh_runner_installed() {
  local dir
  dir="$(gh_runner_dir)"
  [ -f "$dir/config.sh" ] && [ -f "$dir/bin/Runner.Listener" ] && [ -f "$dir/runsvc.sh" ]
}

# gh_install_runner: the newest runner, downloaded, checked against its SHA-256, unpacked by the
# user ghrunner (nothing in the archive is written as root) into a directory of its own, checked to
# start, and only then moved into place. A retry starts over; an installed runner is kept.
gh_install_runner() {
  local arch release v url sha dir stage tarball got
  gh_runner_installed && return 0
  apt_safe install "${VA_GH_RUNNER_PACKAGES[@]}" || return 1
  if ! arch="$(gh_arch)"; then
    log "ghrunner: actions/runner has no build for this architecture"
    return 1
  fi
  if ! release="$(gh_newest_release "$arch")"; then
    log "ghrunner: cannot read the newest actions/runner release from GitHub"
    return 1
  fi
  read -r v url sha <<<"$release"
  dir="$(gh_runner_dir)"
  stage="$dir.new"
  tarball="$dir.tar.gz"
  if ! { mkdir -p "$(dirname "$dir")" && rm -rf "$stage" "$tarball"; }; then
    return 1
  fi
  if ! curl -fsSL --retry 3 --max-time 900 -o "$tarball" "$url"; then
    log "ghrunner: downloading actions/runner $v failed"
    rm -f "$tarball"
    return 1
  fi
  got="$(sha256sum "$tarball" | cut -d' ' -f1)"
  if [ "$got" != "$sha" ]; then
    log "ghrunner: the actions/runner $v download does not match its published SHA-256"
    rm -f "$tarball"
    return 1
  fi
  # As svc.sh install does, the service runs a copy of bin/runsvc.sh in the runner's root. The
  # listener's --version proves that the runner and its libraries load.
  if ! mkdir -p "$stage" || ! chown "$VA_GH_RUNNER_USER:$VA_GH_RUNNER_USER" "$stage" "$tarball" ||
    ! gh_as_runner tar -xzf "$tarball" -C "$stage" ||
    ! gh_as_runner cp "$stage/bin/runsvc.sh" "$stage/runsvc.sh" ||
    ! gh_as_runner chmod 0755 "$stage/runsvc.sh" ||
    ! gh_as_runner "$stage/bin/Runner.Listener" --version >/dev/null; then
    log "ghrunner: actions/runner $v does not unpack or start"
    rm -rf "$stage" "$tarball"
    return 1
  fi
  rm -f "$tarball"
  if ! { rm -rf "$dir" && mv "$stage" "$dir"; }; then
    log "ghrunner: cannot move actions/runner $v into place"
    return 1
  fi
  log "ghrunner: actions/runner $v installed"
}

# app_up_setup: the runner installed (not registered, not started), and the page's stack started
# without exposure.
app_up_setup() {
  gh_install_runner || return 1
  app_compose up -d
}

# gh_restore_previous <keep-dir>: puts back the registration files set aside in <keep-dir> where the
# runner has none of its own, then removes <keep-dir>. 0 when a registration was put back.
gh_restore_previous() {
  local keep="$1" dir f back=1
  dir="$(gh_runner_dir)"
  [ -d "$keep" ] || return 1
  for f in "${VA_GH_RUNNER_CREDS[@]}"; do
    if [ -e "$keep/$f" ]; then
      rm -f "$dir/$f"
      mv -f "$keep/$f" "$dir/$f" && back=0
    fi
  done
  rm -rf "$keep"
  return "$back"
}

# gh_failure <output-file>: the short reason the page shows for a failed config.sh.
gh_failure() {
  local text
  text="$(cat "$1" 2>/dev/null)"
  case "$text" in
    *NotFound* | *"Not Found"* | *Unauthorized* | *Forbidden* | *"Http response code: "4*)
      echo "GitHub did not accept this address and token. A token is valid for one hour: get a new one in GitHub and send the form again."
      ;;
    *"Name or service not known"* | *"No such host"* | *"Connection refused"* | *"timed out"* | *"SSL connection"*)
      echo "This server could not reach GitHub. Try again in a minute."
      ;;
    *)
      echo "The registration failed. Details: journalctl -u vps-apps-ghrunner-register"
      ;;
  esac
}

# runner_register <url>: the runner registered with GitHub from the token in RUNNER_TOKEN, by the
# runner's own config.sh, as ghrunner. The token reaches it as ACTIONS_RUNNER_INPUT_TOKEN, which the
# runner reads for --token, masks, and removes from its environment
# (src/Runner.Listener/CommandSettings.cs); it is on no command line. config.sh's output goes to the
# journal with the token taken out (runner_redact).
#
# Registering again: the runner is stopped and its current registration files are set aside, since
# config.sh refuses to run over them; --replace makes GitHub replace a runner of the same name in
# the same repository or organization. A runner registered elsewhere before cannot be removed from
# there without a removal token from that repository; it goes offline, and GitHub deletes it after
# 14 days (https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/remove-runners).
# A failed attempt puts the earlier registration back and starts the runner again.
runner_register() {
  local url="$1" dir name out keep rc=0 had=no f
  dir="$(gh_runner_dir)"
  name="$(runner_name)"
  out="$(runner_run_dir)/work/out"
  keep="$dir/.vps-apps-previous"
  if ! gh_runner_installed; then
    RUNNER_RESULT="The runner is not installed on this server."
    return 1
  fi
  systemctl stop "$VA_GH_RUNNER_UNIT" || true
  # A run that died with the earlier registration set aside left it here: put it back first.
  gh_restore_previous "$keep" || true
  if ! mkdir -m 0700 "$keep"; then
    RUNNER_RESULT="The registration failed. Details: journalctl -u vps-apps-ghrunner-register"
    return 1
  fi
  for f in "${VA_GH_RUNNER_CREDS[@]}"; do
    if [ -e "$dir/$f" ]; then
      mv -f "$dir/$f" "$keep/$f" && had=yes
    fi
  done
  # config.sh keeps LANG in the runner's .env for the jobs (env.sh); a unit has none of its own.
  (
    export ACTIONS_RUNNER_INPUT_TOKEN="$RUNNER_TOKEN" LANG=C.UTF-8
    gh_as_runner "$dir/config.sh" --unattended --url "$url" --name "$name" --work _work --replace
  ) </dev/null >"$out" 2>&1 || rc=$?
  runner_redact "$RUNNER_TOKEN" <"$out"
  if [ "$rc" -eq 0 ] && [ -f "$dir/.runner" ]; then
    rm -f "$out"
    rm -rf "$keep"
    if ! systemctl enable "$VA_GH_RUNNER_UNIT" || ! systemctl restart "$VA_GH_RUNNER_UNIT"; then
      RUNNER_RESULT="Registered with $url, but the runner does not start. Details: journalctl -u $VA_GH_RUNNER_UNIT"
      return 1
    fi
    RUNNER_RESULT="Registered with $url as $name. The runner is waiting for jobs."
    return 0
  fi
  runner_say "config.sh failed (exit $rc)"
  RUNNER_RESULT="$(gh_failure "$out")"
  rm -f "$out"
  for f in "${VA_GH_RUNNER_CREDS[@]}"; do
    rm -f "$dir/$f"
  done
  if [ "$had" = yes ] && gh_restore_previous "$keep"; then
    systemctl start "$VA_GH_RUNNER_UNIT" || true
    RUNNER_KEPT=yes
    RUNNER_RESULT+=" The runner stays registered as before."
  fi
  rm -rf "$keep"
  return 1
}
