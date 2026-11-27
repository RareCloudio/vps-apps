#!/usr/bin/env bats
load test_helper

SHA=0123456789abcdef0123456789abcdef01234567
STATE=/var/lib/vps-apps
STATUS=/var/lib/vps-apps/public/.well-known/rarecloud-app-status

setup() {
  shopt -u patsub_replacement 2>/dev/null || true
  RENDER="$BATS_TEST_DIRNAME/../bin/render-recipe"
}

# run_recipe <password> [app args...]: render, substitute the Virtualizor tokens by plain
# text replace, and run with sh.
run_recipe() {
  local pw="$1" body
  shift
  body="$("$RENDER" "$@" --version "$SHA"; printf x)"
  body="${body%x}"
  body="${body//'{{root_pass}}'/"$pw"}"
  body="${body//'{{vps_hostname}}'/"${HOSTVAL:-h1.example.com}"}"
  printf '%s' "$body" >"$BATS_TEST_TMPDIR/recipe.sh"
  sh "$BATS_TEST_TMPDIR/recipe.sh" >"$BATS_TEST_TMPDIR/recipe.out" 2>&1
}

bootstrap() { bash "$VPS_APPS_ROOT/usr/local/sbin/vps-apps-bootstrap"; }
status_now() { cat "$VPS_APPS_ROOT$STATUS"; }
pw_file="/etc/vps-apps/password"


install_recipe() {
  run_recipe 'Secret9A' --app docker
}

@test "the password file holds the exact bytes" {
  local pw
  for pw in 'a$b"c' 'x`id`y' "q'w\e r" '-dash' 'Ünï€ode9A'; do
    rm -rf "$VPS_APPS_ROOT"
    mkdir -p "$VPS_APPS_ROOT"
    run_recipe "$pw" --app docker
    printf '%s' "$pw" >"$BATS_TEST_TMPDIR/expected"
    cmp "$BATS_TEST_TMPDIR/expected" "$VPS_APPS_ROOT$pw_file"
    [ "$(stat -c %a "$VPS_APPS_ROOT$pw_file")" = 600 ]
  done
}

@test "the recipe runs under sh" {
  "$RENDER" --app docker --version "$SHA" >"$BATS_TEST_TMPDIR/r.sh"
  sh -n "$BATS_TEST_TMPDIR/r.sh"
  install_recipe
  grep -q '^APP=docker$' "$VPS_APPS_ROOT/etc/vps-apps/env"
  grep -q "^VERSION=$SHA\$" "$VPS_APPS_ROOT/etc/vps-apps/env"
  grep -q '^VA_HOST=h1.example.com$' "$VPS_APPS_ROOT/etc/vps-apps/env"
}

@test "the recipe never prints the password" {
  run_recipe 'Zz9Secret' --app docker
  refute_grep -q 'Zz9Secret' "$BATS_TEST_TMPDIR/recipe.out"
}

@test "VA_IP comes from the default route" {
  install_recipe
  grep -q '^VA_IP=85.121.120.207$' "$VPS_APPS_ROOT/etc/vps-apps/env"
  grep -q 'route get 1.1.1.1' "$STUB_TMP/ip.log"
}

@test "only the timer is enabled, with --now" {
  install_recipe
  grep -qx 'enable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
  refute_grep -q 'enable.*vps-apps-install.service' "$STUB_TMP/systemctl.log"
  local svc="$VPS_APPS_ROOT/etc/systemd/system/vps-apps-install.service"
  local tmr="$VPS_APPS_ROOT/etc/systemd/system/vps-apps-install.timer"
  grep -q '^Type=oneshot$' "$svc"
  grep -q '^After=network-online.target$' "$svc"
  grep -q '^Wants=network-online.target$' "$svc"
  refute_grep -q '^\[Install\]' "$svc"
  grep -q '^OnBootSec=30$' "$tmr"
  grep -q '^OnUnitInactiveSec=60$' "$tmr"
  grep -q '^AccuracySec=1s$' "$tmr"
  grep -q '^WantedBy=timers.target$' "$tmr"
}

@test "a VERSION that is not 40 hex is refused" {
  run "$RENDER" --app docker --version main
  [ "$status" -eq 2 ]
  run "$RENDER" --app docker --version v1.0
  [ "$status" -eq 2 ]
}

@test "a successful run installs, shreds the password and disables the timer" {
  install_recipe
  run bootstrap
  [ "$status" -eq 0 ]
  grep -q -- "--app docker --host h1.example.com --ip 85.121.120.207 --password-file $VPS_APPS_ROOT$pw_file\$" "$STUB_TMP/install.log"
  grep -q "codeload.github.com/RareCloudio/vps-apps/tar.gz/$SHA" "$STUB_TMP/curl.log"
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
  [ "$(readlink "$VPS_APPS_ROOT/opt/vps-apps/current")" = "$VPS_APPS_ROOT/opt/vps-apps/$SHA" ]
}

@test "n8n mode is passed through to install.sh" {
  run_recipe 'Secret9A' --app n8n --mode pro
  run bootstrap
  [ "$status" -eq 0 ]
  grep -q -- '--mode pro$' "$STUB_TMP/install.log"
}

@test "a download failure counts an attempt and exits 0" {
  install_recipe
  echo 7 >"$STUB_TMP/curl_rc"
  run bootstrap
  [ "$status" -eq 0 ]
  [ "$(cat "$VPS_APPS_ROOT$STATE/attempts")" = 1 ]
  [ -f "$VPS_APPS_ROOT$STATE/first-attempt" ]
  [ -f "$VPS_APPS_ROOT$pw_file" ]
  refute_grep -q 'disable' "$STUB_TMP/systemctl.log"
  [ "$(status_now)" = "failed:download" ]
}

@test "a download failure does not overwrite an existing failed step" {
  install_recipe
  seed_failed
  echo 7 >"$STUB_TMP/curl_rc"
  run bootstrap
  [ "$status" -eq 0 ]
  [ "$(status_now)" = "failed:docker" ]
}

@test "a failing install.sh counts an attempt and keeps the timer" {
  install_recipe
  echo 1 >"$STUB_TMP/install_rc"
  run bootstrap
  [ "$status" -eq 0 ]
  [ "$(cat "$VPS_APPS_ROOT$STATE/attempts")" = 1 ]
  [ -f "$VPS_APPS_ROOT$pw_file" ]
  refute_grep -q 'disable' "$STUB_TMP/systemctl.log"
}

seed_failed() {
  mkdir -p "$VPS_APPS_ROOT$STATE/public/.well-known"
  printf 'failed:docker' >"$VPS_APPS_ROOT$STATUS"
}

assert_finished() {
  [ ! -e "$STUB_TMP/install.log" ]
  [ ! -e "$STUB_TMP/curl.log" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  [ "$(status_now)" = "failed:docker" ]
}

@test "the budget ends after 30 attempts" {
  install_recipe
  seed_failed
  echo 30 >"$VPS_APPS_ROOT$STATE/attempts"
  date +%s >"$VPS_APPS_ROOT$STATE/first-attempt"
  run bootstrap
  [ "$status" -eq 0 ]
  assert_finished
}

@test "the budget ends after 45 minutes" {
  install_recipe
  seed_failed
  echo 3 >"$VPS_APPS_ROOT$STATE/attempts"
  echo $(($(date +%s) - 2701)) >"$VPS_APPS_ROOT$STATE/first-attempt"
  run bootstrap
  [ "$status" -eq 0 ]
  assert_finished
}

@test "the 30th failed attempt ends the budget at once" {
  install_recipe
  echo 1 >"$STUB_TMP/install_rc"
  echo 29 >"$VPS_APPS_ROOT$STATE/attempts"
  date +%s >"$VPS_APPS_ROOT$STATE/first-attempt"
  run bootstrap
  [ "$status" -eq 0 ]
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
}

@test "exit 2 from install.sh is final at once" {
  install_recipe
  echo 2 >"$STUB_TMP/install_rc"
  run bootstrap
  [ "$status" -eq 2 ]
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
}

@test "exit 3 from install.sh is final at once" {
  install_recipe
  echo 3 >"$STUB_TMP/install_rc"
  run bootstrap
  [ "$status" -eq 3 ]
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
}

@test "ready ends the timer and shreds the password but calls neither curl nor install.sh" {
  install_recipe
  mkdir -p "$VPS_APPS_ROOT$STATE/public/.well-known"
  printf 'ready' >"$VPS_APPS_ROOT$STATUS"
  run bootstrap
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_TMP/curl.log" ]
  [ ! -e "$STUB_TMP/install.log" ]
  [ "$(status_now)" = ready ]
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
}

@test "a tampered VERSION is final: failed:args, password shredded, timer disabled" {
  install_recipe
  sed -i 's/^VERSION=.*/VERSION=main/' "$VPS_APPS_ROOT/etc/vps-apps/env"
  run bootstrap
  [ "$status" -eq 2 ]
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
  [ "$(status_now)" = "failed:args" ]
}

@test "a hostname with a dollar sign cannot abort the recipe, and the bootstrap refuses it" {
  HOSTVAL='a$b.example.com' run_recipe 'Secret9A' --app docker
  [ -f "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'enable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
  grep -qxF 'VA_HOST=a$b.example.com' "$VPS_APPS_ROOT/etc/vps-apps/env"
  run bootstrap
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_TMP/curl.log" ]
  [ "$(status_now)" = "failed:args" ]
}

@test "a hostname with backticks runs nothing and is refused" {
  HOSTVAL='`touch '"$BATS_TEST_TMPDIR"'/pwned`.example.com' run_recipe 'Secret9A' --app docker
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  run bootstrap
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ ! -e "$STUB_TMP/curl.log" ]
}

@test "a hostname with a newline makes the env invalid: failed:args" {
  HOSTVAL=$'h2.example.com
VERSION=main
APP=n8n' run_recipe 'Secret9A' --app docker
  run bootstrap
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_TMP/curl.log" ]
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  [ "$(status_now)" = "failed:args" ]
}

@test "an uppercase hostname is lowercased before install.sh" {
  HOSTVAL=H3.Example.COM run_recipe 'Secret9A' --app docker
  run bootstrap
  [ "$status" -eq 0 ]
  grep -q -- "--host h3.example.com " "$STUB_TMP/install.log"
}

@test "an empty VA_IP is detected again by the bootstrap" {
  install_recipe
  sed -i 's/^VA_IP=.*/VA_IP=/' "$VPS_APPS_ROOT/etc/vps-apps/env"
  run bootstrap
  [ "$status" -eq 0 ]
  grep -q -- "--ip 85.121.120.207 " "$STUB_TMP/install.log"
}

@test "no IP at all is a retryable attempt and does not end the budget" {
  install_recipe
  sed -i 's/^VA_IP=.*/VA_IP=junk/' "$VPS_APPS_ROOT/etc/vps-apps/env"
  : >"$STUB_TMP/ip_empty"
  run bootstrap
  [ "$status" -eq 0 ]
  [ ! -e "$STUB_TMP/install.log" ]
  [ "$(cat "$VPS_APPS_ROOT$STATE/attempts")" = 1 ]
  [ -f "$VPS_APPS_ROOT$pw_file" ]
  refute_grep -q 'disable' "$STUB_TMP/systemctl.log"
}

@test "a hung install.sh is killed at the end of the budget and the final status is failed:timeout" {
  install_recipe
  echo 600 >"$STUB_TMP/install_sleep"
  echo 3 >"$VPS_APPS_ROOT$STATE/attempts"
  echo $(($(date +%s) - 2698)) >"$VPS_APPS_ROOT$STATE/first-attempt"
  run timeout 60 bash "$VPS_APPS_ROOT/usr/local/sbin/vps-apps-bootstrap"
  [ "$status" -eq 0 ]
  [ -s "$STUB_TMP/install.log" ]
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
  [ "$(status_now)" = "failed:timeout" ]
}

@test "exit 2 and exit 3 from install.sh write failed:args and failed:os" {
  install_recipe
  echo 2 >"$STUB_TMP/install_rc"
  run bootstrap
  [ "$(status_now)" = "failed:args" ]
  echo 3 >"$STUB_TMP/install_rc"
  rm -f "$VPS_APPS_ROOT$STATUS"
  run bootstrap
  [ "$status" -eq 3 ]
  [ "$(status_now)" = "failed:os" ]
}

@test "the budget ending replaces installing with a failed status" {
  install_recipe
  mkdir -p "$VPS_APPS_ROOT$STATE/public/.well-known"
  printf 'installing' >"$VPS_APPS_ROOT$STATUS"
  echo 30 >"$VPS_APPS_ROOT$STATE/attempts"
  date +%s >"$VPS_APPS_ROOT$STATE/first-attempt"
  run bootstrap
  [ "$status" -eq 0 ]
  [ "$(status_now)" = "failed:timeout" ]
}

@test "exit 137 from install.sh is a retryable timeout; on the last attempt it ends as failed:timeout" {
  install_recipe
  echo 137 >"$STUB_TMP/install_rc"
  echo 29 >"$VPS_APPS_ROOT$STATE/attempts"
  date +%s >"$VPS_APPS_ROOT$STATE/first-attempt"
  run bootstrap
  [ "$status" -eq 0 ]
  [ -s "$STUB_TMP/install.log" ]
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
  [ "$(status_now)" = "failed:timeout" ]
}

@test "a plain install.sh failure that wrote no step ends as failed:install" {
  install_recipe
  echo 1 >"$STUB_TMP/install_rc"
  echo 29 >"$VPS_APPS_ROOT$STATE/attempts"
  date +%s >"$VPS_APPS_ROOT$STATE/first-attempt"
  run bootstrap
  [ "$status" -eq 0 ]
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
  [ "$(status_now)" = "failed:install" ]
}

@test "a transient failed:download does not mask a later final reason" {
  install_recipe
  echo 7 >"$STUB_TMP/curl_rc"
  run bootstrap
  [ "$status" -eq 0 ]
  [ "$(status_now)" = "failed:download" ]
  rm "$STUB_TMP/curl_rc"
  echo 3 >"$STUB_TMP/install_rc"
  run bootstrap
  [ "$status" -eq 3 ]
  [ "$(status_now)" = "failed:os" ]
}

@test "a failed:<step> written by install.sh is kept by a later final reason" {
  install_recipe
  mkdir -p "$VPS_APPS_ROOT$STATE/public/.well-known"
  printf 'failed:docker' >"$STUB_TMP/install_status"
  echo 1 >"$STUB_TMP/install_rc"
  echo 29 >"$VPS_APPS_ROOT$STATE/attempts"
  date +%s >"$VPS_APPS_ROOT$STATE/first-attempt"
  run bootstrap
  [ "$status" -eq 0 ]
  [ "$(status_now)" = "failed:docker" ]
}

@test "ready is never overwritten, even by a bad env" {
  install_recipe
  mkdir -p "$VPS_APPS_ROOT$STATE/public/.well-known"
  printf 'ready' >"$VPS_APPS_ROOT$STATUS"
  sed -i 's/^VERSION=.*/VERSION=main/' "$VPS_APPS_ROOT/etc/vps-apps/env"
  run bootstrap
  [ "$status" -eq 0 ]
  [ "$(status_now)" = ready ]
}

@test "an env file with an unknown line or a repeated key is failed:args" {
  install_recipe
  echo 'EXTRA=1' >>"$VPS_APPS_ROOT/etc/vps-apps/env"
  run bootstrap
  [ "$status" -eq 2 ]
  [ "$(status_now)" = "failed:args" ]
  [ ! -e "$STUB_TMP/curl.log" ]
  install_recipe
  echo 'APP=n8n' >>"$VPS_APPS_ROOT/etc/vps-apps/env"
  run bootstrap
  [ "$status" -eq 2 ]
  [ ! -e "$STUB_TMP/curl.log" ]
}

@test "the password is shredded and the timer disabled even when the status cannot be written" {
  install_recipe
  sed -i 's/^VERSION=.*/VERSION=main/' "$VPS_APPS_ROOT/etc/vps-apps/env"
  mkdir -p "$VPS_APPS_ROOT$STATE/public"
  : >"$VPS_APPS_ROOT$STATE/public/.well-known"
  run bootstrap
  [ "$status" -eq 2 ]
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
}

@test "finishing also shreds the password copy install.sh keeps, in case install.sh was killed" {
  install_recipe
  mkdir -p "$VPS_APPS_ROOT$STATE/public/.well-known"
  printf 'Secret9A' >"$VPS_APPS_ROOT$STATE/.admin-password"
  printf 'ready' >"$VPS_APPS_ROOT$STATUS"
  run bootstrap
  [ "$status" -eq 0 ]
  [ ! -e "$VPS_APPS_ROOT$STATE/.admin-password" ]
  rm -f "$VPS_APPS_ROOT$STATUS"
  install_recipe
  printf 'Secret9A' >"$VPS_APPS_ROOT$STATE/.admin-password"
  echo 2 >"$STUB_TMP/install_rc"
  run bootstrap
  [ "$status" -eq 2 ]
  [ ! -e "$VPS_APPS_ROOT$STATE/.admin-password" ]
}

@test "after a recipe env with an empty VA_IP, rc works from install.sh's app.env and the bootstrap still parses its env" {
  install_recipe
  sed -i 's/^VA_IP=.*/VA_IP=/' "$VPS_APPS_ROOT/etc/vps-apps/env"
  cp "$VPS_APPS_ROOT/etc/vps-apps/env" "$BATS_TEST_TMPDIR/env.before"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$VPS_APPS_ROOT/etc/os-release"
  # The real install.sh as the bootstrap runs it, with the IP the bootstrap detected in memory. The
  # first step is stubbed to fail, so nothing else runs.
  run bash -c '. "$1"; load_code() { base_packages() { return 1; }; }; main --app docker --host h1.example.com --ip 85.121.120.207 --password-file "$2"' \
    _ "$BATS_TEST_DIRNAME/../install.sh" "$VPS_APPS_ROOT$pw_file"
  [ "$status" -eq 1 ]
  cmp "$VPS_APPS_ROOT/etc/vps-apps/env" "$BATS_TEST_TMPDIR/env.before"
  run "$BATS_TEST_DIRNAME/../bin/rc" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Host:   https://h1.example.com"* ]]
  run bootstrap
  [ "$status" -eq 0 ]
  grep -q -- "--ip 85.121.120.207 " "$STUB_TMP/install.log"
}

@test "a final failure asks install.sh to show the failed page; a retryable one does not" {
  install_recipe
  echo 1 >"$STUB_TMP/install_rc"
  run bootstrap
  [ "$status" -eq 0 ]
  refute_grep -qx -- '--site-failed' "$STUB_TMP/install.log"
  echo 29 >"$VPS_APPS_ROOT$STATE/attempts"
  run bootstrap
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$STUB_TMP/install.log")" = "--site-failed" ]
  [ "$(grep -cx -- '--site-failed' "$STUB_TMP/install.log")" -eq 1 ]
}

@test "exit 2 and exit 3 from install.sh are final failures that show the failed page too" {
  install_recipe
  echo 3 >"$STUB_TMP/install_rc"
  run bootstrap
  [ "$status" -eq 3 ]
  [ "$(tail -n 1 "$STUB_TMP/install.log")" = "--site-failed" ]
}

@test "a success never shows the failed page" {
  install_recipe
  run bootstrap
  [ "$status" -eq 0 ]
  refute_grep -qx -- '--site-failed' "$STUB_TMP/install.log"
}

@test "a failing --site-failed never stops the password shred or the timer disable" {
  install_recipe
  echo 2 >"$STUB_TMP/install_rc"
  echo 1 >"$STUB_TMP/site_failed_rc"
  run bootstrap
  [ "$status" -eq 2 ]
  grep -qx -- '--site-failed' "$STUB_TMP/install.log"
  [ ! -e "$VPS_APPS_ROOT$pw_file" ]
  grep -qx 'disable --now vps-apps-install.timer' "$STUB_TMP/systemctl.log"
  [ "$(status_now)" = "failed:args" ]
}
