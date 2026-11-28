# vps-apps

[![ci](https://github.com/RareCloudio/vps-apps/actions/workflows/ci.yml/badge.svg)](https://github.com/RareCloudio/vps-apps/actions/workflows/ci.yml)

Turn a fresh Ubuntu 24.04 server into a properly set up app server, with HTTPS and an admin account, in minutes: a Docker server, or n8n, Nextcloud, Forgejo, WordPress, Uptime Kuma or Grafana, or a self-hosted runner for GitHub Actions or GitLab CI.

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
  --password-file /root/admin-password --admin-email you@example.com
```

The installer keeps its settings in `/etc/vps-apps/app.env` and points `/opt/vps-apps/current` at its code, which is what `rc` uses later.

Arguments:

| Argument | Meaning |
| --- | --- |
| `--app` | `docker`, `n8n`, `nextcloud`, `forgejo`, `wordpress`, `uptimekuma`, `grafana`, `ghrunner` or `glrunner` |
| `--host` | A domain name for this server. Point its A record at the server. The installer waits up to five minutes for the name to resolve before it asks for a certificate. |
| `--ip` | The server's public IPv4 address |
| `--password-file` | Required for every app. A file with the admin password, for the app's first login: the n8n owner (your `--admin-email`), the user `admin` in Nextcloud, WordPress, Uptime Kuma and Grafana, the user `gitadmin` in Forgejo, and the user `admin` of the runner apps' registration page. The Docker app does not use it. Delete it once the install is ready. |
| `--mode` | n8n only: `starter` (default) or `pro` |
| `--admin-email` | Optional. The n8n owner login, and the WordPress admin's email. Without it, or when it is not a plain address, it is `admin@<your host>`. |

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

n8n on Postgres, behind HTTPS on your domain. The owner account (your `--admin-email`, or `admin@<your host>`, with your password) is created before n8n is reachable from the internet, so nobody else can claim it. The login message over SSH shows the owner email. If your password does not meet n8n's rules (8 to 64 characters, one capital letter, one digit), a strong one is generated and saved to `/root/vps-apps-credentials.txt`.

- `--mode starter`: n8n and Postgres.
- `--mode pro`: queue mode with Valkey and two workers, for heavier workflows. Valkey requires a password, generated on the server.

n8n is installed from its `stable` tag and runs on UTC (`GENERIC_TIMEZONE` and `TZ` in `/opt/vps-apps-data/n8n/.env`), with n8n's security settings for nodes, the Git node, its settings file and OAuth callbacks set explicitly in the same file.

Add more domains with `rc domain add <domain>`. The newest one becomes n8n's main address, used in webhook URLs and editor links, and every earlier name keeps working.

On a server installed before n8n ran on UTC, schedules move from America/New_York to UTC once `rc update` recreates n8n: a workflow set to run at 09:00 then runs at 09:00 UTC. A workflow with its own time zone in its settings keeps it.

`rc update` keeps n8n on the major version it runs, because n8n's database migrations only go forward. When `stable` moves to a new major version, n8n moves to the newest release of its current major instead, and `rc update` says so. If that release cannot be found, n8n keeps its current image. Moving to a new major version with `rc` is not supported yet.

### nextcloud

Nextcloud on Postgres, with Valkey for caching and file locking. Nextcloud is installed and its admin account (login `admin`, with your password) is created before Nextcloud is reachable from the internet, and nobody can sign up. If your password does not meet Nextcloud's password policy (at least 10 characters, not a common or leaked password), a strong one is generated and saved to `/root/vps-apps-credentials.txt`.

While Nextcloud installs, `occ maintenance:install` takes the database password only as a command-line argument, so the Postgres superuser password from `/opt/vps-apps-data/nextcloud/.env` is on php's command line in the Nextcloud container for as long as that one command runs, visible in the server's process list. It is used only for the install, since Nextcloud then makes its own database login with a password of its own, and it is not your admin password.

Background jobs run every five minutes in their own container (cron mode). Calendar and contacts apps find CalDAV and CardDAV on their own, through the standard well-known addresses.

Add more domains with `rc domain add <domain>`. Nextcloud trusts and serves every name, and the newest one becomes the address in the links that background jobs write (`overwrite.cli.url`).

Nextcloud runs from its `34-apache` tag. `rc update` moves it to the newest 34.x release and never to another major version, because Nextcloud upgrades one major version at a time. Back up the `vps-apps-nextcloud_nextcloud_data` and `vps-apps-nextcloud_postgres_data` volumes.

### forgejo

Forgejo, a self-hosted Git service, on SQLite. The admin account `gitadmin` (Forgejo reserves `admin`), with your password and the email `admin@<your host>`, is created before Forgejo is reachable from the internet, and nobody can sign up. If your password is not 8 to 255 characters long, a strong one is generated and saved to `/root/vps-apps-credentials.txt`.

Git over SSH runs on port 2222, which the installer opens in the firewall:

```bash
git clone ssh://git@<your host>:2222/<owner>/<repo>.git
```

Every page needs a login. To show public repositories to visitors, set `FORGEJO_REQUIRE_SIGNIN_VIEW=false` in `/opt/vps-apps-data/forgejo/.env` and run `rc update`.

Add more domains with `rc domain add <domain>`. The newest one becomes Forgejo's main address, used in links and clone URLs, and every earlier name keeps working.

Forgejo runs from its `15-rootless` tag, the long-term support release (supported until July 2027), and `rc update` keeps it on 15. Back up the `vps-apps-forgejo_forgejo_data` volume.

### wordpress

WordPress on MariaDB. The site and its admin account (login `admin`, with your password) are set up before WordPress is reachable from the internet, so nobody else can run its installer. The admin email is your `--admin-email`, or `admin@<your host>`. Registration stays off. The proxy answers `/xmlrpc.php` with 403, because XML-RPC lets one request try hundreds of passwords; apps and plugins that use XML-RPC do not work. Log in at `https://<your host>/wp-admin/`. If your password is not 1 to 255 printable ASCII characters without a space at either end, a strong one is generated and saved to `/root/vps-apps-credentials.txt`.

WordPress runs on PHP 8.4 (the `php8.4-apache` tag) and MariaDB 12.3, its long-term support series. The database passwords and WordPress's keys and salts are generated on the server, and uploads can be up to 64 MB.

WP-CLI is included:

```bash
cd /opt/vps-apps/current/apps/wordpress
docker compose -f compose.yml -f compose.expose.yml --env-file /opt/vps-apps-data/wordpress/.env run --rm cli wp <command>
```

WordPress updates itself. `rc update` keeps PHP 8.4, MariaDB 12.3 and WP-CLI 2.x on their newest patch releases.

WordPress has one address, your host. Moving a site to another domain changes the links stored in its database, so `rc domain add` refuses on a WordPress server. Back up the `vps-apps-wordpress_wordpress_data` and `vps-apps-wordpress_db_data` volumes.

### uptimekuma

Uptime Kuma 2 on SQLite. The admin account (login `admin`, with your password) is created before Uptime Kuma is reachable from the internet, so nobody else can claim it. If your password does not meet Uptime Kuma's rule (at least 6 characters, with two of: lowercase letters, capital letters, digits, symbols), a strong one is generated and saved to `/root/vps-apps-credentials.txt`.

Uptime Kuma trusts the proxy's headers, so it sees each visitor's real address, and its Primary Base URL, used in notification links, is set to your domain.

Add more domains with `rc domain add <domain>`. Every name serves Uptime Kuma; a status page is shown on the names you map to it in that status page's own settings.

`rc update` keeps Uptime Kuma on version 2. Moving to version 3 needs a manual migration. Back up the `vps-apps-uptimekuma_uptime_kuma_data` volume.

### grafana

Grafana with Loki for logs and Prometheus for metrics, plus node-exporter, so the server shows its own CPU, memory, disk and network from the start. The admin account (login `admin`, with your password) gets its password before Grafana is reachable from the internet, so Grafana's default password never works there. Nobody can sign up, and nothing shows without a login. If your password is shorter than 4 characters, is `admin` or is not printable ASCII, a strong one is generated and saved to `/root/vps-apps-credentials.txt`.

Grafana comes with its Prometheus and Loki data sources and a dashboard for this server, which is also its home page.

Send logs from your other servers to `https://<your host>/loki/api/v1/push`, with the user `loki` and the password generated on the server, both in `/root/vps-apps-credentials.txt`. With Grafana Alloy:

```alloy
loki.write "rarecloud" {
  endpoint {
    url = "https://<your host>/loki/api/v1/push"
    basic_auth {
      username = "loki"
      password = sys.env("LOKI_PUSH_PASSWORD")
    }
  }
}
```

That push address is the only part of Loki on the internet. Loki's query API and Prometheus answer only inside the server, where Grafana reads them. Loki keeps logs for 15 days; Prometheus keeps metrics for 15 days and at most 4 GB.

Add more domains with `rc domain add <domain>`. Grafana and the push address answer on every name, and the newest one becomes Grafana's main address, used in the links it writes.

Grafana runs from the newest release of Grafana 13, Loki from its `3` tag, Prometheus from `v3` and node-exporter from `v1`. `rc update` moves each to the newest release of the major version it runs, and never to another major version, because their database migrations only go forward. Back up the `vps-apps-grafana_grafana_data`, `vps-apps-grafana_loki_data` and `vps-apps-grafana_prometheus_data` volumes.

### ghrunner

A GitHub Actions self-hosted runner. The runner is GitHub's own `actions/runner`, from its newest release, checked against the SHA-256 GitHub publishes for it, and runs on the server itself as the user `ghrunner`, which can use the server's Docker. Jobs that use `container:` and `services:` work as GitHub documents them.

An order cannot carry a GitHub token, so the runner is installed unregistered, and you register it from the page at `https://<your host>/`. The page asks for a login (user `admin`, with your password) before it shows anything. An order password has 10 to 64 characters, with a capital letter and a digit, which makes guessing it through the login impractical. If your password is not 1 to 72 printable ASCII characters, a strong one is generated and saved to `/root/vps-apps-credentials.txt`. On the page, paste your repository or organization address and the registration token from GitHub (your repository's **Settings** > **Actions** > **Runners** > **New self-hosted runner**, the value after `--token`; it is valid for one hour). The server registers the runner and starts it, and the page shows the outcome. In your workflows, use `runs-on: self-hosted`.

The runner stays registered between jobs. Registering again from the page replaces it; when the new registration fails, the earlier one stays in place.

Jobs run as `ghrunner` and can use Docker, which gives them full control of the server, and files one job leaves behind are there for the next. Register the runner only with repositories whose workflows you trust. GitHub advises against self-hosted runners on public repositories, where a pull request from a fork could run code on the server.

The runner updates itself, as GitHub requires. `rc update` refreshes the page only. `rc logs` shows the page; the runner's own log is `journalctl -u vps-apps-ghrunner`, and each registration's is `journalctl -u vps-apps-ghrunner-register`. Add more domains with `rc domain add <domain>`: the page answers on every name, behind the same login.

### glrunner

GitLab Runner with the Docker executor, from GitLab's official image. Every job runs in its own container (`ubuntu:24.04` when your `.gitlab-ci.yml` names no image), and jobs can use the server's Docker, so they can build and run images. Jobs run side by side: one for every 2 GB of memory, at most one per CPU.

An order cannot carry a GitLab token, so the runner is installed unregistered, and you register it from the page at `https://<your host>/`. The page asks for a login (user `admin`, with your password) before it shows anything. An order password has 10 to 64 characters, with a capital letter and a digit, which makes guessing it through the login impractical. If your password is not 1 to 72 printable ASCII characters, a strong one is generated and saved to `/root/vps-apps-credentials.txt`. In GitLab, create a runner (your project's **Settings** > **CI/CD** > **Runners** > **Create project runner**) and copy its runner authentication token, which starts with `glrt-`. On the page, paste your GitLab address (`https://gitlab.com` for GitLab.com, or your own GitLab) and the token. The server registers the runner, and the page shows the outcome. Registration tokens, which GitLab no longer uses by default, are not accepted.

Registering again from the page replaces this server's runner; when the new registration fails, the runner keeps the one it had.

Jobs can use Docker, which gives them full control of the server. Register the runner only with projects whose pipelines you trust.

GitLab Runner runs from the newest release at install, pinned to that version. `rc update` moves it to the newest release of the same major version, never to the next one, whose changed defaults need a look first. `rc logs gitlab-runner` shows the runner's log, and each registration's is `journalctl -u vps-apps-glrunner-register`. Add more domains with `rc domain add <domain>`: the page answers on every name, behind the same login. Back up the `vps-apps-glrunner_gitlab_runner_config` volume, which holds the runner's registration.

## The `rc` command

```text
rc status                       install status and the app's containers
rc logs [service]               follow the logs
rc update                       refresh each image to its tag's newest digest and restart
rc port open <port>[/udp]       open a port (SSH, 80 and 443 are always open)
rc port close <port>[/udp]      close it again
rc port list                    show open ports
rc domain add <domain>          serve the app on one more domain
```

On the Docker server, extra domains go on your own containers with the labels above. WordPress serves one address only, so `rc domain add` refuses there.

## How it works

The installer runs a fixed list of steps: network (an IPv6 gateway outside the server's own prefix gets the on-link flag it needs, at install and at every boot, so IPv6 works), packages, swap, kernel settings, Docker, firewall, proxy, SSH, login message, then the app. Each finished step leaves a marker, so a second run picks up where the first one stopped.

Images are pinned by digest at install. `rc update` looks each image's tag up again and moves to the digest it points to now, so the proxy stays on its pinned release tag and Postgres on version 16, while n8n follows its `stable` tag within its major version. On n8n, the database password, the encryption key and the Valkey password are generated on the server, once, and stay there. On an n8n server installed by an earlier release, `rc update` also adds the settings that release did not have to the `.env`, and keeps every value already there. App data and the proxy's certificates live in Docker named volumes, so back those up.

## Move a server to newer code

A server keeps the code it was installed with. To move it to a newer release commit, as root:

```bash
VERSION=<full commit sha>
cd /opt/vps-apps
curl -fsSL "https://codeload.github.com/RareCloudio/vps-apps/tar.gz/$VERSION" | tar -xz
mv "vps-apps-$VERSION" "$VERSION"
ln -sfn "/opt/vps-apps/$VERSION" /opt/vps-apps/current
rc update
```

Run `rc update` in the same session, right after the link: it adds the settings the newer code needs to the app's `.env` (a pro n8n server needs them before `rc status` or `rc logs` work again), then updates the images. This moves `rc` and the app to the new code; the installer's base steps do not run again.

## Made for RareCloud

RareCloud sells these servers ready-made: you order one and it installs itself, with your HTTPS link ready. [Have a look](https://rarecloud.io/?utm_source=github&utm_medium=readme&utm_campaign=vps-apps).

## Develop

Local test runner: `docker build -f tests/Dockerfile -t vps-apps-test . && docker run --rm vps-apps-test` (CI is the source of truth).

## License

MIT
