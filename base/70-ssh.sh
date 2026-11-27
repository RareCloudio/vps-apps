#!/usr/bin/env bash
# Base step 7: SSH policy and the fail2ban sshd jail. Sourced after lib/common.sh, never executed.

# ssh_usable_key <authorized_keys>: 0 only when sshd will really accept a plain key from the file,
# so that turning password login off cannot lock the customer out. Otherwise 1, with the reason in
# the install log. All of these must hold:
#   - /root/.ssh and the file are owned by root and not group- or world-writable (sshd's
#     StrictModes ignores the file otherwise). Under a test root the owner is the current user.
#   - a line starts with a known key type, so option lines (command=, from=) and RFC4716 (PuTTY)
#     blocks do not count;
#   - ssh-keygen -l accepts that line as a key.
ssh_usable_key() {
  local file="$1" dir f uid want_uid mode line tmp ok=1
  dir="$(dirname "$file")"
  if [ ! -f "$file" ]; then
    log "ssh: no usable key: $file does not exist"
    return 1
  fi
  want_uid=0
  [ -z "${VPS_APPS_ROOT:-}" ] || want_uid="$(id -u)"
  for f in "$dir" "$file"; do
    uid="$(stat -c %u "$f")"
    mode="$(stat -c %a "$f")"
    if [ "$uid" != "$want_uid" ] || [ $((8#$mode & 8#022)) -ne 0 ]; then
      log "ssh: no usable key: $f has owner $uid and mode $mode, sshd would ignore the keys"
      return 1
    fi
  done
  tmp="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
      printf '%s\n' "$line" >"$tmp"
      if ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
        ok=0
        break
      fi
    fi
  done <"$file"
  rm -f "$tmp"
  if [ "$ok" -ne 0 ]; then
    log "ssh: no usable key: no line of $file is a plain key that ssh-keygen accepts"
  fi
  return "$ok"
}

# ssh_restore_dropin <dropin> <previous-copy or empty>: put the previous drop-in back, or remove ours.
ssh_restore_dropin() {
  if [ -n "$2" ]; then
    mv -f "$2" "$1"
  else
    rm -f "$1"
  fi
}

# base_ssh: password login stays on unless a usable key is installed (see ssh_usable_key).
# With a key: password and keyboard-interactive login are off and root is key-only. Without one:
# password login stays on, because the password is the only way in.
# The setting goes in a drop-in that sorts before Ubuntu's 50-cloud-init.conf (sshd keeps the first
# value it reads, so 10- wins). sshd -t checks it, then sshd -T must report the intended
# passwordauthentication; on either failure the previous drop-in (or none) is restored and the step
# fails. Ubuntu 24.04 starts sshd through a socket, so the reload is try-reload-or-restart on ssh.
base_ssh() {
  local dir dropin prev="" pw root reported
  dir="$(p /etc/ssh/sshd_config.d)"
  dropin="$dir/10-vps-apps.conf"
  mkdir -p "$dir"
  # The privilege separation directory is made by the service start; on a first boot sshd -t may
  # run before that.
  mkdir -p "$(p /run/sshd)"
  chmod 0755 "$(p /run/sshd)"

  if ssh_usable_key "$(p /root/.ssh/authorized_keys)"; then
    pw=no root=prohibit-password
  else
    pw=yes root=yes
  fi

  if [ -f "$dropin" ]; then
    prev="$(mktemp "$dir/.prev.XXXXXX")"
    cp -p "$dropin" "$prev"
  fi
  {
    printf '# Written by vps-apps. Password login is off only when a usable key was found.\n'
    printf 'PasswordAuthentication %s\nPermitRootLogin %s\n' "$pw" "$root"
    if [ "$pw" = no ]; then
      printf 'KbdInteractiveAuthentication no\n'
    fi
  } | write_atomic "$dropin" 0644

  if ! sshd -t; then
    ssh_restore_dropin "$dropin" "$prev"
    log "ssh: sshd -t rejected the new configuration, previous drop-in restored"
    return 1
  fi
  reported="$(sshd -T | awk '$1 == "passwordauthentication" { print $2 }' || true)"
  if [ "$reported" != "$pw" ]; then
    ssh_restore_dropin "$dropin" "$prev"
    log "ssh: sshd -T reports passwordauthentication '$reported', expected '$pw'; previous drop-in restored"
    return 1
  fi
  [ -z "$prev" ] || rm -f "$prev"
  systemctl try-reload-or-restart ssh

  base_fail2ban
}

# base_fail2ban: five failures ban a source for an hour. Ubuntu 24.04 logs sshd to the journal,
# so the jail reads the systemd backend.
base_fail2ban() {
  local dir
  dir="$(p /etc/fail2ban/jail.d)"
  mkdir -p "$dir"
  printf '# Written by vps-apps.\n[sshd]\nenabled = true\nbackend = systemd\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\n' |
    write_atomic "$dir/vps-apps.conf" 0644
  systemctl enable fail2ban
  systemctl restart fail2ban
}
