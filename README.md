# vps-apps

One-command apps for Ubuntu 24.04 servers: Docker and n8n to start, with HTTPS and a hardened base. The installer and full documentation are on the way.

Local test runner: `docker build -f tests/Dockerfile -t vps-apps-test . && docker run --rm vps-apps-test` (CI is the source of truth).
