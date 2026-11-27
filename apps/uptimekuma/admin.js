// Uptime Kuma's first account and its reverse proxy settings, made through the app's own socket.io
// API, the one its web UI uses. It runs inside the app container, with the container's own node and
// the socket.io-client that Uptime Kuma ships (a dependency in its package.json), as
//   docker compose exec -T uptime-kuma node -e "<this file>" <mode> [arg]
// so it needs nothing from the network and always speaks the server's own protocol version.
//
// Modes:
//   setup <base-url>  The password on stdin. Creates the user "admin" with Uptime Kuma's own
//                     first-run "setup" event while no user exists, then logs in with that password,
//                     so an account that is already there only counts when the password opens it.
//                     Then saves what the Settings page saves: Trust Proxy on (Uptime Kuma is reached
//                     only through Caddy, which sets the X-Forwarded headers itself) and, while it is
//                     unset, the Primary Base URL used in notification links.
//   need-setup [url]  Prints true while Uptime Kuma still offers its first-run setup, else false.
//   login [url]       The password on stdin. Exits 0 when "admin" logs in with it.
// Exit codes: 0 done, 2 Uptime Kuma finds the password too weak, 1 anything else. The password is
// read from stdin only and never printed.
//
// Checked against Uptime Kuma 2.5.12 (https://github.com/louislam/uptime-kuma/tree/2.5.12):
//   server/server.js:389-395    a new connection is sent "info" first, and the event handlers are
//                               registered only after that, so an event sent before "info" is lost
//   server/server.js:701-736    "needSetup", and "setup" (refused once any user exists; a weak
//                               password is refused with the message "passwordTooWeak")
//   server/server.js:450-528    "login"
//   server/server.js:1483-1563  "getSettings", and "setSettings" (writes only the keys it is given,
//                               server/settings.js:111-134)
//   src/pages/Settings.vue:155-191  the defaults the Settings page fills in before it saves
//   server/uptime-kuma-server.js:166-172  a websocket without an Origin header passes the origin check
"use strict";

const fs = require("fs");
const { io } = require(require.resolve("socket.io-client", { paths: ["/app", process.cwd()] }));

const USERNAME = "admin";
const LOCAL_URL = "http://127.0.0.1:3001";
const TIMEOUT_MS = Number(process.env.UK_ADMIN_TIMEOUT_MS) || 60000;

// The defaults src/pages/Settings.vue gives a setting that was never saved, so a save from here
// stores what a save from the Settings page would.
const SETTINGS_PAGE_DEFAULTS = {
    checkUpdate: true,
    searchEngineIndex: false,
    entryPage: "dashboard",
    nscd: true,
    keepDataPeriodDays: 180,
    tlsExpiryNotifyDays: [7, 14, 21],
    domainExpiryNotifyDays: [7, 14, 21],
    trustProxy: false,
};

function finish(code, message) {
    if (message) {
        process.stderr.write(`uptime-kuma-admin: ${message}\n`);
    }
    process.exit(code);
}

setTimeout(() => finish(1, "Uptime Kuma did not answer in time"), TIMEOUT_MS);

// connect <url>: a socket once the server has sent "info", that is once it listens for events.
function connect(url) {
    return new Promise((resolve, reject) => {
        const socket = io(url, { transports: ["websocket"], reconnection: false, timeout: 20000 });
        socket.once("info", () => resolve(socket));
        socket.once("connect_error", (e) => reject(new Error(`cannot connect to ${url}: ${e.message}`)));
    });
}

// call <socket> <event> [args...]: the event with its arguments, resolved with the server's answer.
function call(socket, event, ...args) {
    return new Promise((resolve) => socket.emit(event, ...args, (answer) => resolve(answer)));
}

function readPassword() {
    const password = fs.readFileSync(0).toString("utf8");
    if (password === "") {
        throw new Error("no password on stdin");
    }
    return password;
}

async function login(socket, password) {
    const answer = await call(socket, "login", { username: USERNAME, password, token: "" });
    return Boolean(answer && answer.ok === true);
}

async function readSettings(socket) {
    const answer = await call(socket, "getSettings");
    if (!answer || answer.ok !== true || typeof answer.data !== "object" || answer.data === null) {
        throw new Error("cannot read the settings");
    }
    return answer.data;
}

async function setup(baseUrl) {
    if (typeof baseUrl !== "string" || !/^https:\/\/[a-z0-9.-]+$/.test(baseUrl)) {
        throw new Error("setup needs the https:// address of this server");
    }
    const password = readPassword();
    const socket = await connect(LOCAL_URL);
    if ((await call(socket, "needSetup")) === true) {
        const answer = await call(socket, "setup", USERNAME, password);
        if (answer && answer.ok !== true && answer.msg === "passwordTooWeak") {
            finish(2, "Uptime Kuma finds the password too weak");
        }
        // Any other refusal (an account made meanwhile) is judged by the login below.
    }
    if (!(await login(socket, password))) {
        throw new Error(`the user ${USERNAME} cannot log in with the password`);
    }
    const settings = { ...SETTINGS_PAGE_DEFAULTS, ...(await readSettings(socket)) };
    settings.trustProxy = true;
    if (!settings.primaryBaseURL) {
        settings.primaryBaseURL = baseUrl;
    }
    const saved = await call(socket, "setSettings", settings, "");
    if (!saved || saved.ok !== true) {
        throw new Error(`cannot save the settings: ${(saved && saved.msg) || "no answer"}`);
    }
    if ((await readSettings(socket)).trustProxy !== true) {
        throw new Error("Trust Proxy did not stay on");
    }
}

async function needSetup(url) {
    const socket = await connect(url || LOCAL_URL);
    const answer = await call(socket, "needSetup");
    if (typeof answer !== "boolean") {
        throw new Error("unreadable answer to needSetup");
    }
    await new Promise((resolve) => process.stdout.write(`${answer}\n`, resolve));
}

async function loginOnly(url) {
    const password = readPassword();
    const socket = await connect(url || LOCAL_URL);
    if (!(await login(socket, password))) {
        throw new Error(`the user ${USERNAME} cannot log in with the password`);
    }
}

const [mode, arg] = process.argv.slice(1);
const modes = { setup, "need-setup": needSetup, login: loginOnly };

if (!Object.prototype.hasOwnProperty.call(modes, mode)) {
    finish(1, "usage: setup <base-url> | need-setup [url] | login [url]");
}
modes[mode](arg).then(
    () => finish(0),
    (e) => finish(1, e.message)
);
