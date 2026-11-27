# End-to-end smoke test

`vps-smoke.sh` tests the installer on a real, fresh Ubuntu 24.04 VPS. It never creates or deletes a
server: you create the VPS, run the script, and delete the VPS.

Needs `bash`, `curl`, `jq` and an OpenSSH client on the machine that runs it (on Windows: Git Bash and
`C:\Windows\System32\OpenSSH\ssh.exe`, found automatically; set `E2E_SSH` to use another client).

## Run

```bash
tests/e2e/vps-smoke.sh --ssh-key <private key> --ip <ipv4> --app <docker|n8n> [--mode starter|pro] \
  --version <40-char commit> --password-file <file> [--checks 1,2,3] [--expect-pw-auth yes|no|auto] \
  [--probe-host <ipv4>]
```

- The VPS has only the test key (and the root password set at creation). The script logs in as root with
  that key.
- `--version` must already be pushed to GitHub: the script first checks that
  `https://codeload.github.com/RareCloudio/vps-apps/tar.gz/<sha>` answers 200.
- `--password-file` holds the root password, byte for byte (no trailing newline: write it with `printf %s`).
  The brief's password is `PW=$'Ab1$"\x60\x27\\ x'`. The script substitutes it into the recipe exactly as
  Virtualizor does and never prints it. The rendered recipe is written only to a private temp dir that is
  removed on exit, and the script refuses to run on a VPS where `/etc/vps-apps` already exists.
- The host name is `<ip-with-dashes>.sslip.io`. sslip.io is not on the Public Suffix List, so every run
  spends from Let's Encrypt's shared per-domain limit. Keep the runs few.
- Output: one `PASS <n> <name>` or `FAIL <n> <name>: <reason>` line per check on stdout (a PASS may carry
  notes in parentheses, for example when IPv6 was not tested). Progress goes to stderr. Exit 0 only when
  every selected check passed.

## IPv6 and `--probe-host`

The reachability probes of check 5 normally run from the machine that runs the script. If that machine
has no IPv6, the IPv6 half is skipped and the PASS line says `(IPv6 NOT TESTED ...)` in capitals.

`--probe-host <ipv4>` names a second server we own, reachable with the same `--ssh-key`, with its own
global IPv6 address. The probes then run from it over ssh, to the target's IPv4 and to its global
IPv6 address. With `--probe-host`, IPv6 is required: check 5 FAILs if either server lacks it. If the probe
host stops answering over ssh, the probe FAILs instead of reading it as "closed".

## Checks

| # | name | what it proves |
|---|------|----------------|
| 1 | install | the rendered recipe runs as root with the nasty password; the timer is armed; the password file is byte-exact |
| 2 | status | `/.well-known/rarecloud-app-status` reads `installing`, then `ready` |
| 3 | https | `https://<ip-dashed>.sslip.io/` answers with a valid certificate |
| 4 | n8n | login as `e2e-owner@<ip-dashed>.sslip.io` (the email the script puts in `{{username}}`), API key, webhook workflow runs, password change, reboot, `rc update`, login each time (n8n only) |
| 5 | docker | whoami over HTTPS; postgres on 5432 closed, `rc port open`, restarts of docker and `vps-apps-nft`, `rc port close`, on IPv4 and IPv6 (docker only). Port 22 is probed first as a positive control |
| 6 | resume | install killed after `app_up_setup`, the timer resumes it, same `.env` checksum (fresh OS only) |
| 7 | domain | `rc domain add app.<ip-dashed>.sslip.io` serves the app there; n8n URL variables move to the new name and the first name keeps serving |
| 8 | hub-64 | records the VPS IPv6 /64; the image pull count and Docker Hub rate limit headers are taken the moment the install is ready (before any restart), or reported as unreliable when that moment was not seen in this run |
| 9 | timer | three minutes after ready: still ready, timer inactive and disabled, password file gone |
| 10 | docker-info | `docker info` works with the `daemon.json` (firewall-backend iptables) |
| 11 | nft-reboot | `nft -c` passes; no "ordering cycle" in the journal after a reboot; firewall back after boot |
| 12 | rc-port | `rc port open 5432`, `open 6000`, `close 5432`: DOCKER-USER has no 5432 rule and no duplicates |
| 13 | ssh | checks the configuration only: sshd listens on 22, `PasswordAuthentication` and `PermitRootLogin` match the keys in `authorized_keys`, the test key is still there (it does not try a password login) |

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
tests/e2e/vps-smoke.sh --ssh-key $K --ip <ip> --app docker --version $V --password-file <pwfile> --probe-host <other-vps-ipv4>
tests/e2e/vps-smoke.sh --ssh-key $K --ip <ip> --app n8n --mode starter --version $V --password-file <pwfile>
tests/e2e/vps-smoke.sh --ssh-key $K --ip <ip> --app n8n --mode pro --version $V --password-file <pwfile>
tests/e2e/vps-smoke.sh --ssh-key $K --ip <ip> --app docker --version $V --password-file <pwfile> --checks 6,3,9
```

## Run log

| date | commit | app/mode | where tested | result |
|------|--------|----------|--------------|--------|
| 2026-11-27 | 0fdfd61 | docker, n8n starter | 2 x VPS on fra1 (Virtualizor, 2 GB) | first live runs: docker 8/11, n8n starter 9/11; found the proxy readiness bug (fixed in efba2c7) and script defects (fixed in 463f968); IPv6 untestable (node template has no on-link route) |
| 2026-11-27 | 8c764df | docker | VPS on thg1, 2 GB, probe host on thg1 | 11/11 (check 5 re-run alone after the probe host's own reboot; IPv4 and IPv6 probed, IPv6 route added by hand on both VPS because the node template lacks on-link) |
| 2026-11-27 | 8c764df | n8n starter | VPS on thg1, 4 GB | 11/11 |
| 2026-11-27 | 8c764df | n8n pro | VPS on thg1, 8 GB | 11/11 |
| 2026-11-27 | 8c764df | docker, resume (checks 6, 3, 9) | VPS on thg1, 2 GB | 3/3 |
