#!/usr/bin/env bash
# Base step 5: Docker from Docker's apt repo, a daemon config and a weekly prune. Sourced, never executed.

VA_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

base_docker() {
  local keyring codename sources
  keyring="$(p /etc/apt/keyrings/docker.asc)"
  sources="$(p /etc/apt/sources.list.d/docker.sources)"
  mkdir -p "$(dirname "$keyring")" "$(dirname "$sources")"
  chmod 0755 "$(dirname "$keyring")"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$keyring"
  chmod a+r "$keyring"

  codename="$(sed -n 's/^VERSION_CODENAME=//p' "$(p /etc/os-release)" 2>/dev/null | head -n1 | tr -d '"')"
  # Rewritten whole on every run, so a retry never leaves two entries.
  cat >"$sources" <<SRC
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename:-noble}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
SRC

  # The daemon config goes in before the first install so Docker starts with it.
  mkdir -p "$(p /etc/docker)"
  install -m 0644 "$VA_BASE_DIR/files/daemon.json" "$(p /etc/docker/daemon.json)"

  apt_safe update
  apt_safe install docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin

  local unit_dir
  unit_dir="$(p /etc/systemd/system)"
  mkdir -p "$unit_dir"
  cat >"$unit_dir/vps-apps-docker-prune.service" <<'UNIT'
[Unit]
Description=Prune unused Docker images and build cache

[Service]
Type=oneshot
ExecStart=/usr/bin/docker image prune -f
ExecStart=/usr/bin/docker builder prune -f --filter until=168h
UNIT
  cat >"$unit_dir/vps-apps-docker-prune.timer" <<'UNIT'
[Unit]
Description=Weekly Docker prune

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now docker
  systemctl enable --now vps-apps-docker-prune.timer
}
