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
  if [ -z "${KEEP_IPS:-}" ]; then body="${body//'{{ips}}'/85.121.120.207}"; fi
  printf '%s' "$body" >"$BATS_TEST_TMPDIR/recipe.sh"
  sh "$BATS_TEST_TMPDIR/recipe.sh" >"$BATS_TEST_TMPDIR/recipe.out" 2>&1
}

bootstrap() { bash "$VPS_APPS_ROOT/usr/local/sbin/vps-apps-bootstrap"; }
status_now() { cat "$VPS_APPS_ROOT$STATUS"; }
pw_file="/etc/vps-apps/password"

# refute_grep <grep args>: fails the test when grep finds a match (a bare ! is ignored by bats mid-test).
refute_grep() {
  if grep "$@"; then return 1; fi
}

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
  KEEP_IPS=1 run_recipe 'Secret9A' --app docker
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

@test "the bootstrap refuses a tampered env VERSION" {
  install_recipe
  sed -i 's/^VERSION=.*/VERSION=main/' "$VPS_APPS_ROOT/etc/vps-apps/env"
  run bootstrap
  [ "$status" -ne 0 ]
  [ ! -e "$STUB_TMP/curl.log" ]
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

@test "a hostname with a newline cannot inject env lines" {
  HOSTVAL=$'h2.example.com
VERSION=main
APP=n8n' run_recipe 'Secret9A' --app docker
  run bootstrap
  [ "$status" -eq 0 ]
  grep -q -- "--app docker --host h2.example.com " "$STUB_TMP/install.log"
  grep -q "tar.gz/$SHA" "$STUB_TMP/curl.log"
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
  run bootstrap
  [ "$status" -eq 0 ]
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
