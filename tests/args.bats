#!/usr/bin/env bats
load test_helper

setup() {
  INSTALL="$BATS_TEST_DIRNAME/../install.sh"
  PWF="$BATS_TEST_TMPDIR/password"
  echo 'Secret123' >"$PWF"
  mkdir -p "$VPS_APPS_ROOT/etc"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$VPS_APPS_ROOT/etc/os-release"
}

@test "an unknown --app exits 2" {
  run bash "$INSTALL" --app foo --host a.example.com --ip 1.2.3.4 --password-file "$PWF"
  [ "$status" -eq 2 ]
}

@test "a missing --password-file exits 2" {
  run bash "$INSTALL" --app docker --host a.example.com --ip 1.2.3.4
  [ "$status" -eq 2 ]
}

@test "--host with a space exits 2" {
  run bash "$INSTALL" --app docker --host "a b.example.com" --ip 1.2.3.4 --password-file "$PWF"
  [ "$status" -eq 2 ]
}

@test "--ip 999.1.1.1 exits 2" {
  run bash "$INSTALL" --app docker --host a.example.com --ip 999.1.1.1 --password-file "$PWF"
  [ "$status" -eq 2 ]
}

@test "--mode is rejected with --app docker" {
  run bash "$INSTALL" --app docker --mode pro --host a.example.com --ip 1.2.3.4 --password-file "$PWF"
  [ "$status" -eq 2 ]
}

@test "--mode is accepted with --app n8n" {
  run bash -c '. "$1"; parse_args --app n8n --mode pro --host a.example.com --ip 1.2.3.4 --password-file "$2"' _ "$INSTALL" "$PWF"
  [ "$status" -eq 0 ]
}

@test "--mode with an unknown value exits 2" {
  run bash "$INSTALL" --app n8n --mode huge --host a.example.com --ip 1.2.3.4 --password-file "$PWF"
  [ "$status" -eq 2 ]
}

@test "valid docker arguments parse and OS check passes" {
  run bash -c '. "$1"; parse_args --app docker --host a.example.com --ip 1.2.3.4 --password-file "$2"; require_ubuntu_2404' _ "$INSTALL" "$PWF"
  [ "$status" -eq 0 ]
}

@test "a Debian os-release exits 3" {
  printf 'ID=debian\nVERSION_ID="12"\n' >"$VPS_APPS_ROOT/etc/os-release"
  run bash "$INSTALL" --app docker --host a.example.com --ip 1.2.3.4 --password-file "$PWF"
  [ "$status" -eq 3 ]
}

@test "install.sh refuses to run when not root, before it looks at anything else" {
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  printf '#!/bin/sh\necho 1000\n' >"$BATS_TEST_TMPDIR/fakebin/id"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/id"
  # No test root here, as on a real server; no arguments, so nothing could be installed either way.
  run env -u VPS_APPS_ROOT PATH="$BATS_TEST_TMPDIR/fakebin:$PATH" bash "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"run as root"* ]]
}

# email_after <args...>: the owner email install.sh settles on for these extra arguments.
email_after() {
  bash -c '. "$1"; shift; parse_args --app n8n --host a.example.com --ip 1.2.3.4 --password-file "$@"; printf "%s" "$VA_ADMIN_EMAIL"' \
    _ "$INSTALL" "$PWF" "$@"
}

@test "--admin-email is lowercased and kept" {
  run email_after --admin-email Owner.Name+n8n@Example.COM
  [ "$status" -eq 0 ]
  [ "$output" = owner.name+n8n@example.com ]
}

@test "no --admin-email, or one that is not a plain address, falls back to admin@<host>" {
  local bad long
  run email_after
  [ "$status" -eq 0 ]
  [ "$output" = admin@a.example.com ]
  long="$(printf 'x%.0s' $(seq 250))@example.com"
  for bad in '' 'a$x@example.com' '`id`@example.com' 'no-at-sign' 'a@b' 'a..b@example.com' '.a@example.com' \
    'a.@example.com' 'a@-x.example.com' 'a@example.c0m' 'a@b@example.com' '{{username}}' 'a b@example.com' \
    "$(printf 'a\nb')@example.com" "$long" "$(printf 'x%.0s' $(seq 65))@example.com"; do
    run email_after --admin-email "$bad"
    [ "$status" -eq 0 ]
    [ "$output" = admin@a.example.com ]
  done
}

@test "--admin-email needs a value" {
  run bash "$INSTALL" --app n8n --host a.example.com --ip 1.2.3.4 --password-file "$PWF" --admin-email
  [ "$status" -eq 2 ]
}
