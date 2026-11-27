#!/usr/bin/env bash
# Base step 7: SSH policy and the fail2ban sshd jail. Sourced after lib/common.sh, never executed.

# base_ssh: password login stays on only when the customer gave no key.
# - A usable key in /root/.ssh/authorized_keys (a line that is not blank and not a comment) turns
#   password login off and root login becomes key-only.
# - No key: password login stays on, because the password is the only way in.
# The setting goes in a drop-in that sorts before Ubuntu's 50-cloud-init.conf (sshd keeps the first
# value it reads, so 10- wins). The drop-in is checked with sshd -t before sshd sees it; a bad
# config restores the previous drop-in (or removes ours) and the step fails. Ubuntu 24.04 starts
# sshd through a socket, so the reload is try-reload-or-restart on the ssh unit.
base_ssh() {
  local dir dropin keys prev="" pw root
  dir="$(p /etc/ssh/sshd_config.d)"
  dropin="$dir/10-vps-apps.conf"
  keys="$(p /root/.ssh/authorized_keys)"
  mkdir -p "$dir"

  if [ -f "$keys" ] && grep -qE '^[[:space:]]*[^#[:space:]]' "$keys"; then
    pw=no root=prohibit-password
  else
    pw=yes root=yes
  fi

  if [ -f "$dropin" ]; then
    prev="$(mktemp "$dir/.prev.XXXXXX")"
    cp -p "$dropin" "$prev"
  fi
  printf '# Written by vps-apps. Password login is off only when a key was given.\nPasswordAuthentication %s\nPermitRootLogin %s\n' "$pw" "$root" |
    write_atomic "$dropin" 0644

  if ! sshd -t; then
    if [ -n "$prev" ]; then
      mv -f "$prev" "$dropin"
    else
      rm -f "$dropin"
    fi
    log "ssh: sshd -t rejected the new configuration, previous drop-in restored"
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
