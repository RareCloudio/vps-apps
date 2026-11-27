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
count() { grep -c "^$1\$" "$COUNTER" || true; }
mark() { echo "$1" >>"$COUNTER"; }
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
  echo 1 >"$BATS_TEST_TMPDIR/fail"
  s_first() { mark first; }
  s_second() { mark second; [ "$(cat "$BATS_TEST_TMPDIR/fail")" = 0 ]; }
  s_third() { mark third; }
  run_step first s_first
  run_step second s_second || true
  [ "$(current_status)" = "failed:second" ]
  echo 0 >"$BATS_TEST_TMPDIR/fail"
  run_step first s_first
  run_step second s_second
  run_step third s_third
  [ "$(count first)" = 1 ]
  [ "$(count second)" = 2 ]
  [ "$(count third)" = 1 ]
  [ -f "$(p /var/lib/vps-apps/steps/second.done)" ]
  [ -f "$(p /var/lib/vps-apps/steps/third.done)" ]
}

@test "a failing command in the middle of a step aborts it and fails the step" {
  multi() { false; mark after; }
  # Called plainly (not via `run` or `||`): bash ignores errexit inside conditions.
  set +e
  run_step multi multi
  rc=$?
  set -e
  [ "$rc" -eq 1 ]
  [ "$(count after)" = 0 ]
  [ "$(current_status)" = "failed:multi" ]
  [ ! -e "$(p /var/lib/vps-apps/steps/multi.done)" ]
}

@test "run_step keeps the caller's errexit setting" {
  ok() { true; }
  set -e
  run_step keep ok
  case $- in *e*) ;; *) false ;; esac
  set +e
  run_step keep2 ok
  case $- in *e*) false ;; esac
}

@test "set_status leaves no temp file behind, in the served dir or the state dir" {
  set_status installing
  set_status ready
  [ -z "$(find "$(p /var/lib/vps-apps)" -name '.status.*')" ]
  [ "$(ls -A "$(p /var/lib/vps-apps/public/.well-known)")" = "rarecloud-app-status" ]
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

@test "write_atomic stores stdin with the mode and leaves no temp file" {
  mkdir -p "$BATS_TEST_TMPDIR/d"
  printf 'hello\n' | write_atomic "$BATS_TEST_TMPDIR/d/f" 0640
  [ "$(cat "$BATS_TEST_TMPDIR/d/f")" = hello ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/d/f")" = 640 ]
  [ "$(find "$BATS_TEST_TMPDIR/d" -type f | wc -l)" -eq 1 ]
}

@test "write_atomic replaces the old content whole and cleans up when it fails" {
  mkdir -p "$BATS_TEST_TMPDIR/d"
  printf 'old' >"$BATS_TEST_TMPDIR/d/f"
  run bash -c '. "$1"; printf new | write_atomic "$2" zzz' _ "$BATS_TEST_DIRNAME/../lib/common.sh" "$BATS_TEST_TMPDIR/d/f"
  [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/d/f")" = old ]
  [ "$(find "$BATS_TEST_TMPDIR/d" -type f | wc -l)" -eq 1 ]
  printf 'new' | write_atomic "$BATS_TEST_TMPDIR/d/f" 0644
  [ "$(cat "$BATS_TEST_TMPDIR/d/f")" = new ]
}
