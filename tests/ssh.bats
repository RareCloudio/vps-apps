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
  ssh-keygen -q -t ed25519 -N '' -C customer -f "$BATS_TEST_TMPDIR/k"
  KEYLINE="$(cat "$BATS_TEST_TMPDIR/k.pub")"
}

# put_keys <content>: a safe authorized_keys (dir 700, file 600) with the given content.
put_keys() {
  mkdir -p "$(dirname "$KEYS")"
  chmod 700 "$(dirname "$KEYS")"
  printf '%s\n' "$1" >"$KEYS"
  chmod 600 "$KEYS"
}

# password_stays_on: base_ssh keeps password login on and says why in the log.
password_stays_on() {
  base_ssh
  grep -qxF 'PasswordAuthentication yes' "$DROPIN"
  grep -qxF 'PermitRootLogin yes' "$DROPIN"
  grep -q 'ssh: no usable key' "$(p /var/log/vps-apps-install.log)"
}

@test "a key present turns password login off" {
  put_keys "# a comment
$KEYLINE"
  base_ssh
  grep -qxF 'PasswordAuthentication no' "$DROPIN"
  grep -qxF 'PermitRootLogin prohibit-password' "$DROPIN"
  grep -qxF 'KbdInteractiveAuthentication no' "$DROPIN"
}

@test "no key keeps password login" {
  base_ssh
  grep -qxF 'PasswordAuthentication yes' "$DROPIN"
  grep -qxF 'PermitRootLogin yes' "$DROPIN"
  refute_grep -q 'KbdInteractiveAuthentication' "$DROPIN"
}

@test "an authorized_keys file without a key line keeps password login" {
  put_keys "
   
# only a comment"
  password_stays_on
}

@test "an RFC4716 (PuTTY) block does not count as a key" {
  put_keys "$(ssh-keygen -e -f "$BATS_TEST_TMPDIR/k.pub")"
  password_stays_on
}

@test "a restricted command= line does not count as a key" {
  put_keys "command=\"echo hi\" $KEYLINE"
  password_stays_on
}

@test "a garbage line and a truncated key do not count as a key" {
  put_keys "ssh-ed25519 notbase64!!
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample"
  password_stays_on
}

@test "a group-writable authorized_keys or .ssh keeps password login" {
  put_keys "$KEYLINE"
  chmod 664 "$KEYS"
  password_stays_on
  put_keys "$KEYLINE"
  chmod 775 "$(dirname "$KEYS")"
  password_stays_on
}

@test "the sshd privilege separation directory exists before sshd -t" {
  base_ssh
  [ -d "$(p /run/sshd)" ]
  [ "$(stat -c %a "$(p /run/sshd)")" = 755 ]
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
  put_keys "$KEYLINE"
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

@test "when sshd -T does not report the intended password setting, the drop-in is restored and nothing reloads" {
  mkdir -p "$(dirname "$DROPIN")"
  printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' >"$DROPIN"
  cp "$DROPIN" "$BATS_TEST_TMPDIR/before"
  put_keys "$KEYLINE"
  echo 'passwordauthentication yes' >"$STUB_TMP/sshd_T_override"
  run base_ssh
  [ "$status" -ne 0 ]
  cmp "$DROPIN" "$BATS_TEST_TMPDIR/before"
  grep -qxF 'sshd -T' "$STUB_TMP/calls.log"
  [ ! -e "$STUB_TMP/systemctl.log" ]
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
