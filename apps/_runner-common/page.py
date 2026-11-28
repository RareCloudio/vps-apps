#!/usr/bin/env python3
"""The registration page of the CI runner apps (ghrunner, glrunner).

It is what https://<host>/ serves on a runner server, behind Caddy basic auth (the caddy labels in
the app's compose.expose.yml). It runs as an unprivileged user on a read-only root filesystem, with
no Docker socket, and does three things only:
  - it shows the registration status that the root unit on the host writes (/status/status.json,
    mounted read-only);
  - it shows one form for the GitHub or GitLab address and the token, and validates both;
  - it writes a valid request as one 0600 JSON file, /inbox/request, which a systemd path unit on
    the host picks up (apps/_runner-common/runner.sh, runner_handle_request). The host validates the
    request again: nothing here is trusted there.
Standard library only, so the image needs nothing installed. No JavaScript.

The validation rules here and in runner.sh (runner_valid_url, runner_valid_token) are the same
rules; tests/app_ghrunner.bats and tests/app_glrunner.bats check that both agree.
"""

import base64
import hashlib
import hmac
import html
import http.cookies
import http.server
import json
import os
import re
import secrets
import signal
import sys
import tempfile
import urllib.parse

KIND = os.environ.get("RUNNER_KIND", "")
INBOX = os.environ.get("RUNNER_PAGE_INBOX", "/inbox")
STATUS = os.environ.get("RUNNER_PAGE_STATUS", "/status/status.json")
BIND = os.environ.get("RUNNER_PAGE_BIND", "0.0.0.0")
PORT = int(os.environ.get("RUNNER_PAGE_PORT", "8080"))
# The largest form and the largest status file this page reads.
MAX_BODY = 4096
# One value per process, in a SameSite=Strict cookie and in the form (double submit). A restart
# makes a form that is still open stale; reloading the page fixes it.
CSRF = secrets.token_urlsafe(32)
COOKIE = "rc_csrf"

GH_URL = re.compile(r"https://github\.com/[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?(?:/[A-Za-z0-9._-]{1,100})?")
GH_TOKEN = re.compile(r"[A-Za-z0-9_-]{20,255}")
# Personal access and OAuth tokens. config.sh takes only a registration token through --token.
GH_NOT_REGISTRATION = ("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_")
GL_URL = re.compile(r"https://([^/:]+)(?::([0-9]{1,5}))?((?:/[A-Za-z0-9._~-]+)*)")
GL_HOST = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+")
# A runner authentication token, GitLab 16 and later (https://docs.gitlab.com/security/tokens/).
GL_TOKEN = re.compile(r"glrt-[A-Za-z0-9_.-]{20,250}")


def valid_url(kind, url):
    """The address rule of runner.sh (runner_valid_url), on an already normalized address."""
    if kind == "github":
        if len(url) > 200 or not GH_URL.fullmatch(url):
            return False
        parts = url[len("https://github.com/"):].split("/")
        return len(parts) == 1 or (parts[1] not in (".", "..") and not parts[1].endswith(".git"))
    if kind == "gitlab":
        m = GL_URL.fullmatch(url) if len(url) <= 255 else None
        if not m:
            return False
        host, port, path = m.group(1), m.group(2), m.group(3)
        if len(host) > 253 or not GL_HOST.fullmatch(host):
            return False
        if port is not None and not 1 <= int(port) <= 65535:
            return False
        return all(seg not in (".", "..") for seg in path.split("/")[1:])
    return False


def valid_token(kind, token):
    """The token rule of runner.sh (runner_valid_token)."""
    if kind == "github":
        return bool(GH_TOKEN.fullmatch(token)) and not token.startswith(GH_NOT_REGISTRATION)
    if kind == "gitlab":
        return bool(GL_TOKEN.fullmatch(token))
    return False


def normalize_url(url):
    """Surrounding spaces and one trailing slash go, and the scheme and host are lowercased."""
    url = url.strip()
    if url.endswith("/"):
        url = url[:-1]
    m = re.match(r"(?i)https://([^/]*)", url)
    if m:
        url = "https://" + m.group(1).lower() + url[m.end():]
    return url


def check(kind, url, token):
    """(url, token, None) for a request worth sending, else (url, "", message)."""
    url = normalize_url(url)
    token = token.strip()
    if not valid_url(kind, url):
        return url, "", TEXTS[kind]["bad_url"]
    if kind == "github" and token.startswith(GH_NOT_REGISTRATION):
        return url, "", TEXTS[kind]["pat"]
    if kind == "gitlab" and token.startswith("GR1348941"):
        return url, "", TEXTS[kind]["legacy"]
    if kind == "gitlab" and token.startswith("glpat-"):
        return url, "", TEXTS[kind]["pat"]
    if not valid_token(kind, token):
        return url, "", TEXTS[kind]["bad_token"]
    return url, token, None


TEXTS = {
    "github": {
        "title": "GitHub Actions runner",
        "url_label": "Repository or organization address",
        "url_hint": "https://github.com/your-name/your-repo",
        "token_label": "Registration token",
        "bad_url": "Enter the address of your repository or organization, like https://github.com/your-name/your-repo.",
        "bad_token": "This is not a runner registration token. Copy the value after --token in GitHub's Configure step.",
        "pat": "This is a personal access token. Paste the runner registration token instead: the value after --token in GitHub's Configure step.",
        "help": (
            "<ol>"
            "<li>In GitHub, open your repository, then <b>Settings</b> &gt; <b>Actions</b> &gt; <b>Runners</b> &gt; "
            "<b>New self-hosted runner</b>. For an organization: the organization's <b>Settings</b> &gt; <b>Actions</b> "
            "&gt; <b>Runners</b> &gt; <b>New runner</b> &gt; <b>New self-hosted runner</b>.</li>"
            "<li>Choose <b>Linux</b>. In the <b>Configure</b> step, copy the value after <code>--token</code>. "
            "It is valid for one hour.</li>"
            "<li>Paste the repository (or organization) address and the token here, and select <b>Register</b>.</li>"
            "<li>In your workflows, use <code>runs-on: self-hosted</code>.</li>"
            "</ol>"
            "<p>Registering again replaces this server's runner. If you move it to another repository, remove the old "
            "entry under that repository's <b>Settings</b> &gt; <b>Actions</b> &gt; <b>Runners</b>; GitHub also removes "
            "it by itself after 14 days offline.</p>"
        ),
        "warning": (
            "Jobs run on this server as the user ghrunner and can use Docker, which gives them full control of the "
            "server. The runner keeps running between jobs, so files or programs one job leaves behind are there for the "
            "next. Register it only with repositories whose workflows you trust. GitHub advises against self-hosted "
            "runners on public repositories: a pull request from a fork could run code here."
        ),
    },
    "gitlab": {
        "title": "GitLab Runner",
        "url_label": "GitLab address",
        "url_hint": "https://gitlab.com",
        "token_label": "Runner authentication token",
        "bad_url": "Enter the address of your GitLab, like https://gitlab.com.",
        "bad_token": "This is not a runner authentication token. It starts with glrt-.",
        "pat": "This is a personal access token. Paste the runner authentication token instead, which starts with glrt-.",
        "legacy": "This is a registration token, which GitLab no longer uses by default. Create a runner in GitLab and paste its token, which starts with glrt-.",
        "help": (
            "<ol>"
            "<li>In GitLab, open your project, then <b>Settings</b> &gt; <b>CI/CD</b> &gt; <b>Runners</b> &gt; "
            "<b>Create project runner</b>. For a group: <b>Build</b> &gt; <b>Runners</b> &gt; <b>Create group runner</b>.</li>"
            "<li>Enter the job tags, or select <b>Run untagged jobs</b>, then <b>Create runner</b>.</li>"
            "<li>Copy the runner authentication token, which starts with <code>glrt-</code>. GitLab shows it only "
            "while you register the runner.</li>"
            "<li>Paste your GitLab address (<code>https://gitlab.com</code> for GitLab.com) and the token here, and "
            "select <b>Register</b>.</li>"
            "</ol>"
            "<p>Registering again replaces this server's runner. A runner you no longer use stays listed in GitLab "
            "until you delete it there.</p>"
        ),
        "warning": (
            "Each job runs in its own container, and jobs can use Docker on this server, which gives them full control "
            "of the server. Register this runner only with projects whose pipelines you trust."
        ),
    },
}

STYLE = (
    "body{font-family:system-ui,sans-serif;margin:0;background:#f4f6fb;color:#0b1120}"
    "main{max-width:40rem;margin:0 auto;padding:1.5rem 1rem}"
    "section{background:#fff;border-radius:8px;padding:1rem 1.25rem;margin:1rem 0}"
    "h1{font-size:1.5rem}h2{font-size:1.1rem;margin-top:0}"
    "label{display:block;font-weight:600;margin-top:.75rem}"
    "input{width:100%;box-sizing:border-box;padding:.5rem;font:inherit;margin-top:.25rem}"
    "button{margin-top:1rem;padding:.5rem 1.25rem;font:inherit;background:#8b5cf6;color:#fff;border:0;border-radius:6px}"
    ".error{border-left:4px solid #dc2626}.state-registered{border-left:4px solid #16a34a}"
    ".state-failed{border-left:4px solid #dc2626}.state-working,.state-queued{border-left:4px solid #8b5cf6}"
    "code{background:#eef0f6;padding:0 .2rem}"
)
CSP = (
    "default-src 'none'; style-src 'sha256-"
    + base64.b64encode(hashlib.sha256(STYLE.encode()).digest()).decode()
    + "'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
)


def read_status():
    """The status the root unit wrote, each field a string; a placeholder when it cannot be read."""
    try:
        with open(STATUS, "rb") as f:
            raw = f.read(MAX_BODY + 1)
        if len(raw) > MAX_BODY:
            raise ValueError("too large")
        status = json.loads(raw.decode("utf-8"))
        if not isinstance(status, dict):
            raise ValueError("not an object")
    except (OSError, ValueError):
        return {"state": "unknown", "message": "The status cannot be read right now.", "url": "", "updated": ""}
    return {k: status[k] if isinstance(status.get(k), str) else "" for k in ("state", "message", "url", "updated")}


def pending():
    return os.path.lexists(os.path.join(INBOX, "request"))


def queue(url, token):
    """Writes the request for the root unit: a 0600 file (mkstemp), renamed into place in one step so
    the unit never sees half of it. False when a request is already waiting (one at a time)."""
    target = os.path.join(INBOX, "request")
    if os.path.lexists(target):
        return False
    fd, tmp = tempfile.mkstemp(prefix=".request-", dir=INBOX)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as f:
            json.dump({"url": url, "token": token}, f)
        os.rename(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return True


def render(kind, error=None, url_value=""):
    t = TEXTS[kind]
    status = read_status()
    state = "queued" if pending() else status["state"]
    if state == "queued":
        message = "Your request is waiting to be processed. This page reloads by itself."
    elif state == "failed":
        message = "Registration failed: " + status["message"]
    else:
        message = status["message"] or "Not registered yet."
    esc = html.escape
    lines = [
        "<!doctype html>",
        '<html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
    ]
    if state in ("queued", "working"):
        lines.append('<meta http-equiv="refresh" content="5">')
    lines += [
        f"<title>{esc(t['title'])}</title><style>{STYLE}</style></head><body><main>",
        f"<h1>{esc(t['title'])}</h1>",
        f'<section class="state-{esc(state)}"><h2>Status</h2><p>{esc(message)}</p>',
    ]
    if status["url"]:
        lines.append(f"<p>Registered with <code>{esc(status['url'])}</code>.</p>")
    if status["updated"]:
        lines.append(f"<p>Last change: {esc(status['updated'])}</p>")
    lines.append("</section>")
    if error:
        lines.append(f'<section class="error"><p>{esc(error)}</p></section>')
    lines += [
        '<section><h2>Register</h2><form method="post" action="/">',
        f'<input type="hidden" name="csrf" value="{esc(CSRF)}">',
        f'<label for="url">{esc(t["url_label"])}</label>',
        f'<input id="url" name="url" type="url" required maxlength="255" placeholder="{esc(t["url_hint"])}" value="{esc(url_value)}">',
        f'<label for="token">{esc(t["token_label"])}</label>',
        '<input id="token" name="token" type="password" required maxlength="255" autocomplete="off">',
        '<button type="submit">Register</button></form></section>',
        f"<section><h2>Where to find the token</h2>{t['help']}</section>",
        f"<section><h2>Before you register</h2><p>{esc(t['warning'])}</p></section>",
        "</main></body></html>",
    ]
    return "\n".join(lines) + "\n"


class Page(http.server.BaseHTTPRequestHandler):
    server_version = "runner-page"
    sys_version = ""
    # A client that stalls is dropped, so it cannot hold this one-request-at-a-time server.
    timeout = 15

    # The access log: method, path without its query, and status. Never a header or a body. The
    # container's own health check every 30 seconds is left out.
    def log_request(self, code="-", size="-"):
        path = urllib.parse.urlsplit(self.path).path if isinstance(getattr(self, "path", None), str) else "-"
        if path == "/healthz" and code == 200:
            return
        sys.stderr.write(f"{getattr(self, 'command', '-')} {path[:100]} {code}\n")

    def log_error(self, format, *args):
        code = args[0] if args and isinstance(args[0], int) else "-"
        sys.stderr.write(f"rejected a request ({code})\n")

    def log_message(self, format, *args):
        pass

    def send(self, code, body, ctype="text/html; charset=utf-8", headers=()):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        # same-origin, not no-referrer: under no-referrer browsers send "Origin: null" with the form's
        # POST (Fetch standard, "append a request Origin header"), which same_origin() refuses.
        # same-origin still sends nothing to another site.
        self.send_header("Referrer-Policy", "same-origin")
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def page(self, code, error=None, url_value=""):
        cookie = f"{COOKIE}={CSRF}; Path=/; Secure; HttpOnly; SameSite=Strict"
        self.send(code, render(KIND, error, url_value), headers=[("Set-Cookie", cookie)])

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/":
            self.page(200)
        elif path == "/healthz":
            self.send(200, "ok", "text/plain; charset=utf-8")
        else:
            self.send(404, "not found", "text/plain; charset=utf-8")

    def same_origin(self, form):
        """The CSRF checks: the form value and the cookie both carry this process's value, and the
        browser's own Origin and Sec-Fetch-Site headers, when sent, say the form came from here."""
        cookies = http.cookies.SimpleCookie()
        try:
            for raw in self.headers.get_all("Cookie") or []:
                cookies.load(raw)
        except http.cookies.CookieError:
            return False
        sent = cookies[COOKIE].value if COOKIE in cookies else ""
        want = CSRF.encode()
        if not (hmac.compare_digest(sent.encode(), want) and hmac.compare_digest(form.get("csrf", "").encode(), want)):
            return False
        origins = self.headers.get_all("Origin") or []
        sites = self.headers.get_all("Sec-Fetch-Site") or []
        if len(origins) > 1 or len(sites) > 1:
            return False
        if origins and origins[0] != "https://" + (self.headers.get("Host") or ""):
            return False
        return not sites or sites[0] == "same-origin"

    def discard(self, length):
        """Reads and drops what a refused request sent, up to 64 KiB within one second, and closes
        the connection after the answer: a socket closed with unread data resets, and the client
        could lose the answer."""
        self.close_connection = True
        try:
            self.connection.settimeout(1)
            left = min(length, 65536) if length is not None else 65536
            while left > 0:
                chunk = self.rfile.read1(left)
                if not chunk or length is None:
                    break
                left -= len(chunk)
        except OSError:
            pass

    def content_length(self):
        """The declared body length, None when there is none or it is not a plain number."""
        length = self.headers.get("Content-Length")
        # isascii too: isdigit takes Unicode digits ("²"), which int() then refuses.
        if length is None or self.headers.get("Transfer-Encoding") or not (length.isascii() and length.isdigit()):
            return None
        return int(length)

    def read_form(self):
        """The form fields, or an HTTP status for a body that is not one small urlencoded form."""
        length = self.content_length()
        if length is None:
            self.discard(None)
            return 411
        if length > MAX_BODY:
            self.discard(length)
            return 413
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/x-www-form-urlencoded":
            self.discard(length)
            return 415
        body = self.rfile.read(length)
        try:
            # ASCII only, also once percent-decoded: no field of this form takes anything else.
            pairs = urllib.parse.parse_qsl(
                body.decode("ascii"), keep_blank_values=True, strict_parsing=True, encoding="ascii",
                errors="strict", max_num_fields=8,
            )
        except (UnicodeDecodeError, ValueError):
            return 400
        form = {}
        for key, value in pairs:
            if key in form:
                return 400
            form[key] = value
        return form

    def do_POST(self):
        split = urllib.parse.urlsplit(self.path)
        if split.path != "/" or split.query:
            self.discard(self.content_length())
            self.send(404, "not found", "text/plain; charset=utf-8")
            return
        form = self.read_form()
        if isinstance(form, int):
            self.send(form, "The form could not be read.", "text/plain; charset=utf-8")
            return
        if not self.same_origin(form):
            self.page(403, "The form has expired. Reload this page and send it again.")
            return
        url, token, error = check(KIND, form.get("url", ""), form.get("token", ""))
        if error:
            self.page(400, error, url)
            return
        if not queue(url, token):
            self.page(409, "A registration is already in progress. Wait for it to finish.", url)
            return
        self.send(303, "", "text/plain; charset=utf-8", headers=[("Location", "/")])


def main():
    if KIND not in TEXTS:
        sys.exit("RUNNER_KIND must be github or gitlab")
    # As PID 1 in its container, Python would ignore SIGTERM without a handler of its own.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server = http.server.HTTPServer((BIND, PORT), Page)
    sys.stderr.write(f"listening on {server.server_address[1]}\n")
    sys.stderr.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
