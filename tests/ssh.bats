#!/usr/bin/env bats
load test_helper

setup() {
  # shellcheck source=../lib/common.sh
  . "$BATS_TEST_DIRNAME/../lib/common.sh"
  # shellcheck source=../base/70-ssh.sh
  . "$BATS_TEST_DIRNAME/../base/70-ssh.sh"
  DROPIN="$(p /etc/ssh/sshd_config.d/10-vps-apps.conf)"
  KEYS="$(p /root/.ssh/authorized_keys)"
  JAIL="$(p /etc/fail2ban/jail.d/vps-apps.conf)"
}

@test "a key present turns password login off" {
  mkdir -p "$(dirname "$KEYS")"
  printf '# a comment\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample customer\n' >"$KEYS"
  base_ssh
  grep -qxF 'PasswordAuthentication no' "$DROPIN"
  grep -qxF 'PermitRootLogin prohibit-password' "$DROPIN"
}

@test "no key keeps password login" {
  base_ssh
  grep -qxF 'PasswordAuthentication yes' "$DROPIN"
  grep -qxF 'PermitRootLogin yes' "$DROPIN"
}

@test "an authorized_keys file without a key line keeps password login" {
  mkdir -p "$(dirname "$KEYS")"
  printf '\n   \n# only a comment\n' >"$KEYS"
  base_ssh
  grep -qxF 'PasswordAuthentication yes' "$DROPIN"
}

@test "the reload is socket-safe: sshd -t first, then try-reload-or-restart ssh" {
  base_ssh
  [ "$(sed -n 1p "$STUB_TMP/calls.log")" = "sshd -t" ]
  l_test="$(grep -nxF 'sshd -t' "$STUB_TMP/calls.log" | head -n1 | cut -d: -f1)"
  l_reload="$(grep -nxF 'systemctl try-reload-or-restart ssh' "$STUB_TMP/calls.log" | head -n1 | cut -d: -f1)"
  [ "$l_test" -lt "$l_reload" ]
  refute_grep -qE 'systemctl (restart|reload) ssh' "$STUB_TMP/calls.log"
}

@test "a failed sshd -t restores the previous drop-in and does not reload" {
  mkdir -p "$(dirname "$DROPIN")"
  printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' >"$DROPIN"
  cp "$DROPIN" "$BATS_TEST_TMPDIR/before"
  mkdir -p "$(dirname "$KEYS")"
  printf 'ssh-ed25519 AAAAexample customer\n' >"$KEYS"
  echo 1 >"$STUB_TMP/sshd_rc"
  run base_ssh
  [ "$status" -ne 0 ]
  cmp "$DROPIN" "$BATS_TEST_TMPDIR/before"
  [ ! -e "$STUB_TMP/systemctl.log" ]
}

@test "a failed sshd -t with no previous drop-in leaves none behind" {
  echo 1 >"$STUB_TMP/sshd_rc"
  run base_ssh
  [ "$status" -ne 0 ]
  [ ! -e "$DROPIN" ]
}

@test "the drop-in is world-readable and rewriting it is idempotent" {
  base_ssh
  cp "$DROPIN" "$BATS_TEST_TMPDIR/first"
  base_ssh
  cmp "$DROPIN" "$BATS_TEST_TMPDIR/first"
  [ "$(stat -c %a "$DROPIN")" = 644 ]
}

@test "the fail2ban sshd jail has maxretry 5 and bantime 1h" {
  base_ssh
  grep -qxF '[sshd]' "$JAIL"
  grep -qxF 'enabled = true' "$JAIL"
  grep -qxF 'maxretry = 5' "$JAIL"
  grep -qxF 'bantime = 1h' "$JAIL"
  grep -qxF 'backend = systemd' "$JAIL"
  grep -qxF 'enable fail2ban' "$STUB_TMP/systemctl.log"
  grep -qxF 'restart fail2ban' "$STUB_TMP/systemctl.log"
}
