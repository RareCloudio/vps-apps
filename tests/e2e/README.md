# End-to-end smoke test

`vps-smoke.sh` tests the installer on a real, fresh Ubuntu 24.04 VPS. It never creates or deletes a
server: you create the VPS, run the script, and delete the VPS.

Needs `bash`, `curl`, `jq` and an OpenSSH client on the machine that runs it (on Windows: Git Bash and
`C:\Windows\System32\OpenSSH\ssh.exe`, found automatically; set `E2E_SSH` to use another client).

## Run

```bash
tests/e2e/vps-smoke.sh --ssh-key <private key> --ip <ipv4> --app <docker|n8n> [--mode starter|pro] \
  --version <40-char commit> --password-file <file> [--checks 1,2,3] [--expect-pw-auth yes|no|auto]
```

- The VPS has only the test key (and the root password set at creation). The script logs in as root with
  that key.
- `--version` must already be pushed to GitHub: the script first checks that
  `https://codeload.github.com/RareCloudio/vps-apps/tar.gz/<sha>` answers 200.
- `--password-file` holds the root password, byte for byte (no trailing newline: write it with `printf %s`).
  The brief's password is `PW=$'Ab1$"\x60\x27\\ x'`. The script substitutes it into the recipe exactly as
  Virtualizor does and never prints it. The rendered recipe is written only to a 0700 temp dir that is
  removed on exit.
- The host name is `<ip-with-dashes>.sslip.io`. sslip.io is not on the Public Suffix List, so every run
  spends from Let's Encrypt's shared per-domain limit. Keep the runs few.
- Output: one `PASS <n> <name>` or `FAIL <n> <name>: <reason>` line per check on stdout (a PASS may carry
  notes in parentheses, for example when IPv6 was not tested). Progress goes to stderr. Exit 0 only when
  every selected check passed.

## Checks

| # | name | what it proves |
|---|------|----------------|
| 1 | install | the rendered recipe runs as root with the nasty password; the timer is armed; the password file is byte-exact |
| 2 | status | `/.well-known/rarecloud-app-status` reads `installing`, then `ready` |
| 3 | https | `https://<ip-dashed>.sslip.io/` answers with a valid certificate |
| 4 | n8n | login, API key, webhook workflow runs, password change, reboot, `rc update`, login each time (n8n only) |
| 5 | docker | whoami over HTTPS; postgres on 5432 closed, `rc port open`, restarts of docker and `vps-apps-nft`, `rc port close`, on IPv4 and on IPv6 when both ends have it (docker only) |
| 6 | resume | install killed after `app_up_setup`, the timer resumes it, same `.env` checksum (fresh OS only) |
| 7 | domain | `rc domain add app.<ip-dashed>.sslip.io` serves the app there; n8n URL variables follow |
| 8 | hub-64 | records the VPS IPv6 /64, the image pulls of the install, and Docker Hub's rate limit headers |
| 9 | timer | three minutes after ready: still ready, timer inactive and disabled, password file gone |
| 10 | docker-info | `docker info` works with the `daemon.json` (firewall-backend iptables) |
| 11 | nft-reboot | `nft -c` passes; no "ordering cycle" in the journal after a reboot; firewall back after boot |
| 12 | rc-port | `rc port open 5432`, `open 6000`, `close 5432`: DOCKER-USER has no 5432 rule and no duplicates |
| 13 | ssh | sshd on 22; password login and `authorized_keys` as the VPS shows them |

Default checks: docker `1 2 3 5 7 8 9 10 11 12 13`, n8n `1 2 3 4 7 8 9 10 11 12 13`. Check 6 installs by
itself, so it is never a default and cannot be combined with check 1. Checks run in this order whatever
the order of `--checks`: 1 6 2 3 4 5 7 8 10 12 13 9 11.

Check 13 derives the expected `PasswordAuthentication` from the VPS: `no` when `authorized_keys` holds a
usable plain key (the installer's rule), else `yes`. A VPS that carries only the test key therefore expects
`no`. Pass `--expect-pw-auth yes|no` to override.

## The four runs

The first three each start on a freshly reinstalled OS; the fourth too.

```bash
V=<sha40>
K=<private key>
tests/e2e/vps-smoke.sh --ssh-key $K --ip <ip> --app docker --version $V --password-file <pwfile>
tests/e2e/vps-smoke.sh --ssh-key $K --ip <ip> --app n8n --mode starter --version $V --password-file <pwfile>
tests/e2e/vps-smoke.sh --ssh-key $K --ip <ip> --app n8n --mode pro --version $V --password-file <pwfile>
tests/e2e/vps-smoke.sh --ssh-key $K --ip <ip> --app docker --version $V --password-file <pwfile> --checks 6,3,9
```

## Run log

| date | commit | app/mode | where tested | result |
|------|--------|----------|--------------|--------|
