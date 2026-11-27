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
