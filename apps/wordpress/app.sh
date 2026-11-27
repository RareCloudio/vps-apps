#!/usr/bin/env bash
# The "wordpress" app: WordPress (Apache, PHP 8.4) on MariaDB, with WP-CLI for the setup. Sourced by
# install.sh and by rc, never executed. It implements the hook contract described in
# apps/docker/app.sh.
#
# The order that matters: until WordPress is installed, wp-admin/install.php lets anyone who reaches
# it take the site. So the stack starts with WordPress published on 127.0.0.1 only
# (compose.setup.yml), WP-CLI installs the site and creates the admin straight in the database, and
# only then does app_expose swap in compose.expose.yml (the caddy labels, no published port), after
# WordPress itself says it is installed and that registration is closed.
#
# The admin password is only ever read from the password file and sent on stdin: to WP-CLI's
# documented prompt for wp core install, then to a login check that reads the raw bytes. It is in no
# argument, compose file, env file or container environment.

VA_APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The image seeds the WordPress files into the volume on first start only; WordPress then updates
# itself there (https://hub.docker.com/_/wordpress, "Static image / updates-via-redeploy"). So the
# tag picks what rc update manages: PHP 8.4 and Apache. 8.4 is fully supported by WordPress 7.x
# (https://make.wordpress.org/core/handbook/references/php-compatibility-and-wordpress-versions/)
# and has security fixes until the end of 2028; the image's plain tags still follow PHP 8.3.
VA_WORDPRESS_IMAGE_REF="wordpress:php8.4-apache"
# WP-CLI 2.x on the same PHP.
VA_WPCLI_IMAGE_REF="wordpress:cli-2-php8.4"
# MariaDB's current LTS series (12.3, maintained until June 2029); rc update stays on 12.3.x.
VA_MARIADB_IMAGE_REF="mariadb:12.3"
VA_WP_ADMIN_USER="admin"
VA_WP_TITLE="My WordPress Site"
# The login check, as wp-login.php makes it: the password slashed (wp-login.php takes it from the
# slashed $_POST, and wp core install stores the hash of the slashed value too), for the admin
# login, which must exist and be an administrator. The password is read raw from stdin, so a
# change made by the one-line prompt on the way in is caught here.
# shellcheck disable=SC2016 # PHP code, expanded by PHP
WP_ADMIN_CHECK_PHP='$u = get_user_by("login", "admin"); $p = file_get_contents("php://stdin");
exit(($u && in_array("administrator", (array) $u->roles, true) && wp_check_password(wp_slash($p), $u->user_pass, $u->ID)) ? 0 : 1);'

app_data_dir() {
  p /opt/vps-apps-data/wordpress
}

app_compose_files() {
  printf '%s\n' "$VA_APP_DIR/compose.yml"
  if [ -f "$(app_data_dir)/exposed" ]; then
    printf '%s\n' "$VA_APP_DIR/compose.expose.yml"
  else
    printf '%s\n' "$VA_APP_DIR/compose.setup.yml"
  fi
}

# app_compose <docker compose args...>
app_compose() {
  compose_run "$(app_data_dir)/.env" "$@"
}

# wp_cli <wp args...>: one WP-CLI command in a one-off container of the cli service (compose.yml),
# stdin passed through.
wp_cli() {
  app_compose run --rm -T cli wp "$@"
}

# wp_secret <bytes>: <bytes> random bytes as hex, or fail.
wp_secret() {
  local s
  s="$(openssl rand -hex "$1")" || return 1
  [[ "$s" =~ ^[0-9a-f]+$ ]] && [ "${#s}" -eq $(($1 * 2)) ] || return 1
  printf '%s' "$s"
}

# app_prepare: php.ini on every run, then the .env, created once. An existing .env is kept as it is,
# so every secret stays byte-identical on a re-run. Every image is resolved and every secret made
# before anything is written. The host goes into PHP code (WP_HOME), so it must be a plain name.
app_prepare() {
  local data wp_image cli_image db_image line key out="" k
  if ! valid_hostname "${VA_HOST:-}"; then
    log "wordpress: '${VA_HOST:-}' is not a valid host name"
    return 1
  fi
  data="$(app_data_dir)"
  mkdir -p "$data"
  write_atomic "$data/php.ini" 0644 <"$VA_APP_DIR/php.ini" || return 1
  [ ! -f "$data/.env" ] || return 0

  wp_image="$(resolve_image_digest "$VA_WORDPRESS_IMAGE_REF")" || return 1
  cli_image="$(resolve_image_digest "$VA_WPCLI_IMAGE_REF")" || return 1
  db_image="$(resolve_image_digest "$VA_MARIADB_IMAGE_REF")" || return 1

  local -A vars=(
    [WORDPRESS_IMAGE]="$wp_image" [WORDPRESS_IMAGE_REF]="$VA_WORDPRESS_IMAGE_REF"
    [WPCLI_IMAGE]="$cli_image" [WPCLI_IMAGE_REF]="$VA_WPCLI_IMAGE_REF"
    [MARIADB_IMAGE]="$db_image" [MARIADB_IMAGE_REF]="$VA_MARIADB_IMAGE_REF"
    [WP_HOST]="$VA_HOST"
    [VA_SITE_ADDRS]="$VA_HOST"
  )
  vars[DB_PASSWORD]="$(wp_secret 24)" || return 1
  vars[DB_ROOT_PASSWORD]="$(wp_secret 24)" || return 1
  # The eight keys and salts of wp-config.php, read by the image from these variables.
  for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
    vars[WORDPRESS_$k]="$(wp_secret 32)" || return 1
  done

  while IFS= read -r line || [ -n "$line" ]; do
    for key in "${!vars[@]}"; do
      line="${line//@${key}@/"${vars[$key]}"}"
    done
    out+="$line"$'\n'
  done <"$VA_APP_DIR/env.tmpl"
  printf '%s' "$out" | write_atomic "$data/.env" 0600
}

app_up_setup() {
  app_compose up -d
}

# wp_password_ok <file>: the exact bytes of the file are a password WP-CLI's one-line prompt carries
# as it is: 1 to 255 printable ASCII characters, with no space at either end (WordPress's own profile
# form trims those). WordPress itself has no other rule, so every password the order form allows
# (8 to 64 printable ASCII characters) passes.
wp_password_ok() {
  local LC_ALL=C pw size
  pw="$(
    cat "$1"
    printf x
  )"
  pw="${pw%x}"
  size="$(wc -c <"$1")"
  # A NUL byte cannot be kept in a shell variable, so the lengths would differ.
  [ "$((size))" -eq "${#pw}" ] || return 1
  [[ "$pw" =~ ^[[:print:]]+$ ]] && [ "${#pw}" -le 255 ] && [[ "$pw" != " "* ]] && [[ "$pw" != *" " ]]
}

# wp_wait_for_web: wait, bounded, until WordPress answers on the loopback port. Apache starts only
# once the image has copied WordPress into the volume and written wp-config.php, which WP-CLI needs.
# wp-login.php also loads WordPress with its database: a redirect (to install.php before the
# install) is an answer, a database error (500) is not.
wp_wait_for_web() {
  local deadline
  deadline=$((SECONDS + ${VA_WP_WAIT:-180}))
  until curl -fsS -o /dev/null --max-time 30 http://127.0.0.1:8080/wp-login.php 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "wordpress: not answering on 127.0.0.1:8080"
      return 1
    fi
    sleep "${VA_WP_INTERVAL:-3}"
  done
}

# wp_admin_email: the admin email install.sh settled on (VA_ADMIN_EMAIL: the customer's email, or
# admin@<host>).
wp_admin_email() {
  printf '%s' "${VA_ADMIN_EMAIL:-admin@$VA_HOST}"
}

# wp_log_error <what> <stderr-file> [<password-file>]: one log line with the end of the error output
# (WP-CLI's own message comes last, after compose's lines). The install log is world-readable, so
# PHP stack-trace lines are dropped: PHP prints call arguments there (the image does not set
# zend.exception_ignore_args), and the password is one of them. The exact password is masked too.
wp_log_error() {
  local msg pw
  msg="$({ grep -vE '^[[:space:]]*(PHP[[:space:]]+)?(#[0-9]+[[:space:]]|Stack trace:|thrown in )' "$2" || true; } |
    tail -c 400 | tr '\n' ' ')"
  if [ -n "${3:-}" ]; then
    pw="$(cat "$3")"
    [ -z "$pw" ] || msg="${msg//"$pw"/<password>}"
  fi
  log "wordpress: $1: $msg"
}

# app_create_admin <password-file>: install WordPress with WP-CLI on the loopback stack, which
# creates the admin, then keep registration closed and check that the admin logs in with the
# password. wp core install leaves a site that is installed already as it is ("WordPress is already
# installed.", exit 0), so a retry is safe, and the login check then proves it holds this password.
#   - The password goes to wp core install's documented --prompt=admin_password on stdin
#     (https://developer.wordpress.org/cli/commands/core/install/), as one line. WP-CLI reads it
#     with readline, which can echo it, so the command's stdout is never kept. Without an answer,
#     WP-CLI would make up a password and print it: the login check fails that case.
#   - users_can_register is WordPress's "Anyone can register" setting, 0 on a new site; it is set to
#     0 explicitly so no open signup ever depends on a default.
app_create_admin() {
  local pwfile="$1" err pw
  if ! wp_password_ok "$pwfile"; then
    log "wordpress: the password must be 1 to 255 printable ASCII characters, without a space at either end"
    return 1
  fi
  wp_wait_for_web || return 1
  err="$(mktemp)"
  pw="$(cat "$pwfile")"
  if ! wp_cli core install --url="https://$VA_HOST" --title="$VA_WP_TITLE" --admin_user="$VA_WP_ADMIN_USER" \
    --admin_email="$(wp_admin_email)" --skip-email --prompt=admin_password <<<"$pw" >/dev/null 2>"$err"; then
    wp_log_error "wp core install failed" "$err" "$pwfile"
    rm -f "$err"
    return 1
  fi
  if ! wp_cli option update users_can_register 0 </dev/null >/dev/null 2>"$err"; then
    wp_log_error "cannot keep registration closed" "$err"
    rm -f "$err"
    return 1
  fi
  if ! wp_cli eval "$WP_ADMIN_CHECK_PHP" <"$pwfile" >/dev/null 2>"$err"; then
    wp_log_error "the admin cannot log in with the chosen password" "$err" "$pwfile"
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
}

# wp_is_installed: WordPress says it is installed (wp core is-installed: is_blog_installed(), the
# test install.php makes before it offers the install). Fails closed on any error.
wp_is_installed() {
  wp_cli core is-installed </dev/null >/dev/null 2>&1
}

# wp_signup_closed: "Anyone can register" reads exactly 0. Fails closed on any error.
wp_signup_closed() {
  local v
  v="$(wp_cli option get users_can_register </dev/null 2>/dev/null)" || return 1
  [ "$v" = 0 ]
}

# app_expose: first puts the stack back into setup state (marker removed, WordPress on the loopback
# port only) and waits for it. That makes a retry after a failed or interrupted expose recover on
# its own, and it is where WordPress can be asked about itself. Then it refuses unless WordPress is
# installed and registration is closed, so install.php or an open signup is never put on the
# internet.
app_expose() {
  rm -f "$(app_data_dir)/exposed"
  if ! app_compose up -d; then
    log "wordpress: cannot bring the setup stack up before exposing"
    return 1
  fi
  wp_wait_for_web || return 1
  if ! wp_is_installed; then
    log "wordpress: refusing to expose, WordPress is not installed or its state is unreadable"
    return 1
  fi
  if ! wp_signup_closed; then
    log "wordpress: refusing to expose, registration is open or its setting is unreadable"
    return 1
  fi
  : >"$(app_data_dir)/exposed"
  set_site_mode app
  if ! app_compose up -d; then
    log "wordpress: starting the exposed stack failed"
    # Stop whatever came up, drop the marker (so rc names the setup file again) and show the failed
    # page instead of leaving a half-exposed server.
    app_compose down || true
    rm -f "$(app_data_dir)/exposed"
    set_site_mode failed
    return 1
  fi
}

# WordPress must answer its REST index over HTTPS on the server's own name with a valid
# certificate, and name https://<host> as its home: that proves PHP, the database and the HTTPS
# address together. ?rest_route= works with any permalink setting
# (https://developer.wordpress.org/rest-api/key-concepts/#routes-endpoints). The body is captured
# first: a pipe can fail curl with error 23 under pipefail.
app_ready_check() {
  local body
  body="$(curl -fsS --max-time 10 --resolve "$VA_HOST:443:127.0.0.1" "https://$VA_HOST/?rest_route=/")" || return 1
  jq -e --arg home "https://$VA_HOST" '.home == $home' >/dev/null 2>&1 <<<"$body"
}

# WordPress has one address: WP_HOME and WP_SITEURL in its config, and the links in its posts. A
# second name would need the site moved (a search and replace in the database), which rc does not
# do, so rc domain add refuses before it records anything.
app_domain_check() {
  echo "WordPress serves one address, https://$VA_HOST, and rc domain add cannot move a WordPress site to another domain yet" >&2
  return 1
}

app_domain_added() {
  app_domain_check "$@"
}
