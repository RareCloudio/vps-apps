# vps-apps

[![ci](https://github.com/RareCloudio/vps-apps/actions/workflows/ci.yml/badge.svg)](https://github.com/RareCloudio/vps-apps/actions/workflows/ci.yml)

Turn a fresh Ubuntu 24.04 server into a properly set up Docker server or n8n server, with HTTPS and an admin account, in minutes.

You get:

- **A firewall that covers your containers.** Ports published by Docker stay closed until you open them with `rc port open <port>`. The firewall covers IPv6 too when the server has it.
- **A locked-down base.** SSH password login is turned off at install when a working key is already in place (a server installed without a key keeps password login), fail2ban watches SSH, security updates install themselves, container logs are rotated, and dangling images and old build cache are pruned every week.
- **HTTPS with no setup.** A reverse proxy gets and renews certificates for any container that carries two labels.
- **A sensible machine.** Swap sized from your RAM, time sync on, kernel hardening applied.
- **The `rc` command.** Status, logs, updates, ports and domains in one short command.

One command gives you all of it, with the same result on every server.

## Run it

On any Ubuntu 24.04 server, as root. Pick a release commit from this repo and use its full SHA.

```bash
VERSION=<full commit sha>
mkdir -p /opt/vps-apps && cd /opt/vps-apps
curl -fsSL "https://codeload.github.com/RareCloudio/vps-apps/tar.gz/$VERSION" | tar -xz
mv "vps-apps-$VERSION" "$VERSION"

(umask 077; printf '%s' 'your-admin-password' > /root/admin-password)

"/opt/vps-apps/$VERSION/install.sh" --app n8n --host n8n.example.com --ip 203.0.113.10 \
  --password-file /root/admin-password
```

The installer keeps its settings in `/etc/vps-apps/app.env` and points `/opt/vps-apps/current` at its code, which is what `rc` uses later.

Arguments:

| Argument | Meaning |
| --- | --- |
| `--app` | `docker` or `n8n` |
| `--host` | A domain name for this server. Point its A record at the server. The installer waits up to five minutes for the name to resolve before it asks for a certificate. |
| `--ip` | The server's public IPv4 address |
| `--password-file` | Required for both apps. A file with the admin password; n8n uses it for the owner login, the Docker app does not use it. Delete it once the install is ready. |
| `--mode` | n8n only: `starter` (default) or `pro` |

It exits 0 when the app is ready, 1 when a step failed (run it again, finished steps are skipped), 2 for bad arguments and 3 on any other OS than Ubuntu 24.04.

Watch it work at `http://<server ip>/.well-known/rarecloud-app-status`. It answers from the proxy step on (a refused connection before that is normal). It says `installing`, `ready`, or `failed:<step>`. The same status and a link to your server show when you log in over SSH.

## The apps

### docker

Docker Engine with the Compose plugin, a Caddy reverse proxy with automatic HTTPS, and a landing page on your domain that shows how to publish your first container. To put your own container on a domain, join it to the `web` network and add two labels:

```yaml
labels:
  caddy: myapp.example.com
  caddy.reverse_proxy: "{{upstreams 3000}}"
```

### n8n

n8n on Postgres, behind HTTPS on your domain. The owner account (`admin@<your host>`, with your password) is created before n8n is reachable from the internet, so nobody else can claim it. If your password does not meet n8n's rules (8 to 64 characters, one capital letter, one digit), a strong one is generated and saved to `/root/vps-apps-credentials.txt`.

- `--mode starter`: n8n and Postgres.
- `--mode pro`: queue mode with Valkey and two workers, for heavier workflows.

Add more domains with `rc domain add <domain>`.

## The `rc` command

```text
rc status                       install status and the app's containers
rc logs [service]               follow the logs
rc update                       move to the newest images and restart
rc port open <port>[/udp]       open a port (22, 80 and 443 are always open)
rc port close <port>[/udp]      close it again
rc port list                    show open ports
rc domain add <domain>          serve n8n on one more domain
```

On the Docker server, extra domains go on your own containers with the labels above.

## How it works

The installer runs a fixed list of steps: packages, swap, kernel settings, Docker, firewall, proxy, SSH, login message, then the app. Each finished step leaves a marker, so a second run picks up where the first one stopped.

Images are pinned by digest at install, and `rc update` moves them to the newest release. On n8n, the database password and encryption key are generated on the server, once, and stay there. n8n data and the proxy's certificates live in Docker named volumes, so back those up.

## Made for RareCloud

RareCloud sells these servers ready-made: you order one and it installs itself, with your HTTPS link ready. [Have a look](https://rarecloud.io/?utm_source=github&utm_medium=readme&utm_campaign=vps-apps).

## Develop

Local test runner: `docker build -f tests/Dockerfile -t vps-apps-test . && docker run --rm vps-apps-test` (CI is the source of truth).

## License

MIT
