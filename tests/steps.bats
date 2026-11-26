#!/usr/bin/env bats
load test_helper

setup() {
  # shellcheck source=../lib/common.sh
  . "$BATS_TEST_DIRNAME/../lib/common.sh"
  # shellcheck source=../lib/steps.sh
  . "$BATS_TEST_DIRNAME/../lib/steps.sh"
  COUNTER="$BATS_TEST_TMPDIR/counter"
  : >"$COUNTER"
}

bump() { echo x >>"$COUNTER"; }
boom() { return 1; }

current_status() { cat "$(p /var/lib/vps-apps/public/.well-known/rarecloud-app-status)"; }

@test "run_step runs once and skips on re-run" {
  run_step one bump
  run_step one bump
  [ "$(wc -l <"$COUNTER" | tr -d ' ')" = 1 ]
  [ -f "$(p /var/lib/vps-apps/steps/one.done)" ]
}

@test "a failing step writes failed:<name> and no marker" {
  run run_step bad boom
  [ "$status" -eq 1 ]
  [ "$(current_status)" = "failed:bad" ]
  [ ! -e "$(p /var/lib/vps-apps/steps/bad.done)" ]
}

@test "a re-run after a failure runs only the failed step and the later ones" {
  FAIL=1
  flaky() { bump; [ "$FAIL" = 0 ]; }
  run_step first bump
  run_step second flaky || true
  [ "$(current_status)" = "failed:second" ]
  FAIL=0
  run_step first bump
  run_step second flaky
  run_step third bump
  # first once, second twice, third once
  [ "$(wc -l <"$COUNTER" | tr -d ' ')" = 4 ]
  [ -f "$(p /var/lib/vps-apps/steps/second.done)" ]
  [ -f "$(p /var/lib/vps-apps/steps/third.done)" ]
}

@test "the status has no trailing newline and is replaced by rename" {
  f="$(p /var/lib/vps-apps/public/.well-known/rarecloud-app-status)"
  set_status installing
  inode1="$(stat -c %i "$f")"
  set_status ready
  inode2="$(stat -c %i "$f")"
  [ "$inode1" != "$inode2" ]
  [ "$(tail -c1 "$f" | od -An -c | tr -d ' ')" = "y" ]
  [ "$(cat "$f")" = "ready" ]
}

@test "log appends an ISO-8601 UTC timestamp and the message" {
  log hello world
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z hello world$' "$(p /var/log/vps-apps-install.log)"
}
