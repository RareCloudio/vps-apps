#!/usr/bin/env bats
load test_helper

setup() {
  ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  APP_DIR="$ROOT_DIR/apps/wordpress"
  # shellcheck source=../lib/common.sh
  . "$ROOT_DIR/lib/common.sh"
  # shellcheck source=../lib/compose.sh
  . "$ROOT_DIR/lib/compose.sh"
  # shellcheck source=../lib/images.sh
  . "$ROOT_DIR/lib/images.sh"
  # shellcheck source=../lib/steps.sh
  . "$ROOT_DIR/lib/steps.sh"
  # shellcheck source=../base/60-proxy.sh
  . "$ROOT_DIR/base/60-proxy.sh"
  # shellcheck source=../apps/wordpress/app.sh
  . "$APP_DIR/app.sh"
  VA_HOST=wp.example.com
  export VA_HOST
  unset VA_ADMIN_EMAIL
  DATA="$(p /opt/vps-apps-data/wordpress)"
  PWF="$BATS_TEST_TMPDIR/password"
  printf '%s' 'Secret123' >"$PWF"
  export VA_WP_WAIT=2 VA_WP_INTERVAL=0
  WP="$BATS_TEST_TMPDIR/wp"
  mkdir -p "$WP"
  # Every docker and curl call, in order, one line each.
  EVENTS="$BATS_TEST_TMPDIR/events"
  # Every docker argv entry on its own line, to look for the password in any single argument.
  DOCKER_ARGV="$BATS_TEST_TMPDIR/docker_argv"
  : >"$EVENTS"
  : >"$DOCKER_ARGV"
}

# stub_docker: a docker that records every call, and answers "compose ... run ... cli wp <args>"
# like WP-CLI on a WordPress site whose state lives in $WP:
#   core install        reads the password as WP-CLI's prompt does (one line) and stores it, unless
#                       the site is installed already ("WordPress is already installed.", exit 0).
#                       It echoes the line it read to stdout, as readline can on a pipe.
#   core is-installed   0 when installed
#   option get|update   the options in $WP/option.<name>; users_can_register is 0 by default
#   eval                0 when its stdin is, byte for byte, the stored password
# WP_INSTALL_RC, WP_EVAL_RC and WP_OPTION_GET override an answer; DOCKER_FAIL_MATCH fails any call
# whose command line contains it. The stdin of each run call is kept in $WP/stdin.<n>.
stub_docker() {
  docker() {
    local a seen=no n line
    local -a wp=()
    printf 'docker %s\n' "$*" >>"$EVENTS"
    printf '%s\n' "$*" >>"$STUB_TMP/docker.log"
    printf '%s\n' "$@" >>"$DOCKER_ARGV"
    if [ -n "${DOCKER_FAIL_MATCH:-}" ] && [[ "$*" == *"$DOCKER_FAIL_MATCH"* ]]; then
      return 1
    fi
    [[ " $* " == *" run "* ]] || return 0
    for a in "$@"; do
      if [ "$seen" = yes ]; then
        wp+=("$a")
      elif [ "$a" = wp ]; then
        seen=yes
      fi
    done
    n=$(($(cat "$WP/runs" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$WP/runs"
    cat >"$WP/stdin.$n"
    case "${wp[0]:-} ${wp[1]:-}" in
      "core install")
        if [ -n "${WP_INSTALL_RC:-}" ]; then
          # A PHP fatal error, whose stack trace shows call arguments (the password among them).
          line=""
          IFS= read -r line <"$WP/stdin.$n" || true
          printf '%s\n' "PHP Fatal error:  Uncaught Exception: boom in /var/www/html/wp-admin/includes/upgrade.php:80" \
            "Stack trace:" "#0 /var/www/html/wp-admin/includes/upgrade.php(80): wp_create_user('admin', '${line:0:15}...', 'a@b.c')" \
            "#1 {main}" "  thrown in /var/www/html/wp-admin/includes/upgrade.php on line 80" \
            "PHP   #2 wp_install('$line')" "Error: Error establishing a database connection." >&2
          return "$WP_INSTALL_RC"
        fi
        if [ -e "$WP/installed" ]; then
          echo "WordPress is already installed."
          return 0
        fi
        line=""
        IFS= read -r line <"$WP/stdin.$n" || true
        printf '1/1 --admin_password=<password>: %s\n' "$line"
        printf '%s' "$line" >"$WP/admin_password"
        : >"$WP/installed"
        echo "Success: WordPress installed successfully."
        ;;
      "core is-installed") [ -e "$WP/installed" ] ;;
      "option update") printf '%s' "${wp[3]}" >"$WP/option.${wp[2]}" ;;
      "option get")
        if [ -n "${WP_OPTION_GET+x}" ]; then
          printf '%s\n' "$WP_OPTION_GET"
        elif [ -f "$WP/option.${wp[2]}" ]; then
          cat "$WP/option.${wp[2]}"
          echo
        elif [ "${wp[2]}" = users_can_register ]; then
          echo 0
        else
          echo "Error: Could not get '${wp[2]}' option. Does it exist?" >&2
          return 1
        fi
        ;;
      "eval "*)
        if [ -n "${WP_EVAL_RC:-}" ]; then
          printf '%s\n' "PHP Warning:  odd in eval()'d code on line 1" "Stack trace:" \
            "#0 wp_check_password('$(cat "$WP/stdin.$n")')" "the password itself: $(cat "$WP/stdin.$n")" >&2
          return "$WP_EVAL_RC"
        fi
        [ -f "$WP/admin_password" ] && cmp -s "$WP/stdin.$n" "$WP/admin_password"
        ;;
    esac
  }
}

# stub_curl: the loopback probe fails as many times as the number in $WP/web_fail, then answers;
# the HTTPS call prints REST_BODY.
stub_curl() {
  curl() {
    local n
    printf 'curl %s\n' "$*" >>"$EVENTS"
    if [[ "$*" == *"http://127.0.0.1:8080/"* ]]; then
      n="$(cat "$WP/web_fail" 2>/dev/null || echo 0)"
      if [ "$n" = forever ] || [ "$n" -gt 0 ]; then
        [ "$n" = forever ] || echo $((n - 1)) >"$WP/web_fail"
        return 7
      fi
      return 0
    fi
    printf '%s' "${REST_BODY-}"
  }
}

# wp_runs <pattern>: the docker run calls (in $EVENTS) whose command line matches the ERE.
wp_runs() {
  grep -E "^docker .* run --rm -T cli wp $1" "$EVENTS"
}

# line_of <ERE>: the number of the first line in $EVENTS that matches.
line_of() {
  grep -nE "$1" "$EVENTS" | head -n1 | cut -d: -f1
}

# The real docker, when the machine has one (the stub is first on PATH): merged config checks.
real_docker() {
  local d
  while IFS= read -r d; do
    [ "$d" = "$BATS_TEST_DIRNAME/stubs" ] && continue
    [ -x "$d/docker" ] && {
      echo "$d/docker"
      return 0
    }
  done < <(tr ':' '\n' <<<"$PATH")
  return 1
}

# Docker Desktop reached from WSL is a Windows binary and wants Windows paths; elsewhere a no-op.
native_path() {
  if command -v wslpath >/dev/null; then wslpath -w "$1"; else echo "$1"; fi
}

# merged_config <file...>: the compose config as JSON, the cli profile included.
merged_config() {
  local docker f
  local -a args=()
  docker="$(real_docker)" || skip "no real docker on this machine"
  for f in "$@"; do args+=(-f "$(native_path "$APP_DIR/$f")"); done
  "$docker" compose "${args[@]}" --env-file "$(native_path "$DATA/.env")" --profile cli config --format json
}

SALTS=(WORDPRESS_AUTH_KEY WORDPRESS_SECURE_AUTH_KEY WORDPRESS_LOGGED_IN_KEY WORDPRESS_NONCE_KEY
  WORDPRESS_AUTH_SALT WORDPRESS_SECURE_AUTH_SALT WORDPRESS_LOGGED_IN_SALT WORDPRESS_NONCE_SALT)

# A password with every character a shell or a JSON or PHP string could trip on, and a space.
NASTY_PW=$'Ab1$"\x60\x27\\ x;&|<>(){}[]*?!#~%^=+,./:@'

@test "secrets are generated once, each different, and a second run keeps them byte-identical" {
  app_prepare
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
  grep -Eq '^DB_PASSWORD=[0-9a-f]{48}$' "$DATA/.env"
  grep -Eq '^DB_ROOT_PASSWORD=[0-9a-f]{48}$' "$DATA/.env"
  for k in "${SALTS[@]}"; do
    grep -Eq "^$k=[0-9a-f]{64}\$" "$DATA/.env"
  done
  # Ten secrets, ten different values.
  [ "$(grep -E '^(DB_PASSWORD|DB_ROOT_PASSWORD|WORDPRESS_[A-Z_]+_(KEY|SALT))=' "$DATA/.env" | cut -d= -f2 | sort -u | wc -l)" -eq 10 ]
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  app_prepare
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  [ "$(stat -c %a "$DATA/.env")" = 600 ]
}

@test "a second server gets other secrets" {
  app_prepare
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/first"
  rm "$DATA/.env"
  app_prepare
  for k in DB_PASSWORD DB_ROOT_PASSWORD "${SALTS[@]}"; do
    [ "$(grep "^$k=" "$DATA/.env")" != "$(grep "^$k=" "$BATS_TEST_TMPDIR/first")" ]
  done
}

@test "the .env pins WordPress, WP-CLI and MariaDB by digest, with the tag kept for rc update" {
  app_prepare
  grep -Eq '^WORDPRESS_IMAGE=wordpress@sha256:[0-9a-f]{64}$' "$DATA/.env"
  grep -Eq '^WPCLI_IMAGE=wordpress@sha256:[0-9a-f]{64}$' "$DATA/.env"
  grep -Eq '^MARIADB_IMAGE=mariadb@sha256:[0-9a-f]{64}$' "$DATA/.env"
  grep -qxF 'WORDPRESS_IMAGE_REF=wordpress:php8.4-apache' "$DATA/.env"
  grep -qxF 'WPCLI_IMAGE_REF=wordpress:cli-2-php8.4' "$DATA/.env"
  grep -qxF 'MARIADB_IMAGE_REF=mariadb:12.3' "$DATA/.env"
  for ref in wordpress:php8.4-apache wordpress:cli-2-php8.4 mariadb:12.3; do
    grep -qxF "buildx imagetools inspect $ref --format {{json .Manifest}}" "$STUB_TMP/docker.log"
    want="$(printf '%s' "$ref" | sha256sum | cut -d' ' -f1)"
    grep -qF "@sha256:$want" "$DATA/.env"
  done
}

@test "no image follows latest, and the compose defaults are the same tags" {
  grep -qF 'image: ${WORDPRESS_IMAGE:-wordpress:php8.4-apache}' "$APP_DIR/compose.yml"
  grep -qF 'image: ${WPCLI_IMAGE:-wordpress:cli-2-php8.4}' "$APP_DIR/compose.yml"
  grep -qF 'image: ${MARIADB_IMAGE:-mariadb:12.3}' "$APP_DIR/compose.yml"
  refute_grep -qE ':latest|:lts|wordpress:apache|wordpress:cli[^-]' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl" "$APP_DIR/app.sh"
}

@test "rc update re-resolves every image from its own tag, so PHP, WP-CLI and MariaDB keep their major" {
  app_prepare
  resolve_env_images "$DATA/.env" "$BATS_TEST_TMPDIR/out"
  [ "$(grep -c '_IMAGE_REF=' "$BATS_TEST_TMPDIR/out")" -eq 3 ]
  diff <(grep '_IMAGE_REF=' "$DATA/.env") <(grep '_IMAGE_REF=' "$BATS_TEST_TMPDIR/out")
  # The default re-resolution is enough: no app hook changes what rc update does.
  run declare -F app_update_env
  [ "$status" -ne 0 ]
}

@test "the host and the one site address come from VA_HOST" {
  app_prepare
  grep -qxF 'WP_HOST=wp.example.com' "$DATA/.env"
  grep -qxF 'VA_SITE_ADDRS="wp.example.com"' "$DATA/.env"
}

@test "app_prepare refuses a host that is not a plain DNS name, and writes no .env" {
  for bad in "" "Wp.Example.com" "x');system('id');//.example.com" "a b.example.com"; do
    VA_HOST="$bad" run app_prepare
    [ "$status" -ne 0 ]
    [ ! -e "$DATA/.env" ]
  done
}

@test "an image that cannot be resolved fails app_prepare and leaves no .env" {
  : >"$BATS_TEST_TMPDIR/inspect_fail"
  run app_prepare
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/.env" ]
}

@test "the template substitution is literal for a value with an ampersand and a backslash" {
  resolve_image_digest() { printf '%s\n' 'x/y&z\w@sha256:abc'; }
  app_prepare
  grep -qxF 'WORDPRESS_IMAGE=x/y&z\w@sha256:abc' "$DATA/.env"
  grep -qxF 'MARIADB_IMAGE=x/y&z\w@sha256:abc' "$DATA/.env"
}

@test "the PHP upload limits are raised and the file is mounted read-only into PHP's conf.d" {
  app_prepare
  [ "$(stat -c %a "$DATA/php.ini")" = 644 ]
  grep -qxF 'upload_max_filesize = 64M' "$DATA/php.ini"
  grep -qxF 'post_max_size = 64M' "$DATA/php.ini"
  grep -qF -- '- /opt/vps-apps-data/wordpress/php.ini:/usr/local/etc/php/conf.d/vps-apps.ini:ro' "$APP_DIR/compose.yml"
  # It is written again on every run, without touching the .env.
  printf 'broken\n' >"$DATA/php.ini"
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/env"
  app_prepare
  grep -qxF 'upload_max_filesize = 64M' "$DATA/php.ini"
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/env"
}

@test "the compose files are base and setup, then base and expose once the marker exists" {
  app_prepare
  run app_compose_files
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$APP_DIR/compose.yml" ]
  [ "${lines[1]}" = "$APP_DIR/compose.setup.yml" ]
  : >"$DATA/exposed"
  run app_compose_files
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = "$APP_DIR/compose.expose.yml" ]
}

@test "the setup file publishes WordPress on loopback only and carries no caddy label" {
  grep -qF '"127.0.0.1:8080:80"' "$APP_DIR/compose.setup.yml"
  refute_grep -q caddy "$APP_DIR/compose.setup.yml"
  refute_grep -qE '^[[:space:]]+- "?[0-9]+:[0-9]+' "$APP_DIR"/compose*.yml
  refute_grep -q 'ports:' "$APP_DIR/compose.yml" "$APP_DIR/compose.expose.yml"
}

@test "the expose label is exactly the site address, with no scheme or port, and Apache's port 80" {
  grep -qF 'caddy: ${VA_SITE_ADDRS:?VA_SITE_ADDRS is not set}' "$APP_DIR/compose.expose.yml"
  grep -qF 'caddy.reverse_proxy: "{{upstreams 80}}"' "$APP_DIR/compose.expose.yml"
  refute_grep -qE 'https?://|:443' "$APP_DIR/compose.expose.yml"
}

@test "merged setup config: loopback 8080 for WordPress only, no labels, nothing else published" {
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services | keys | join(",")' <<<"$cfg")" = "cli,db,wordpress" ]
  [ "$(jq -r '.services.wordpress.ports | length' <<<"$cfg")" = 1 ]
  [ "$(jq -r '.services.wordpress.ports[0] | "\(.host_ip):\(.published):\(.target)"' <<<"$cfg")" = "127.0.0.1:8080:80" ]
  [ "$(jq -r '.services.wordpress.labels // {} | length' <<<"$cfg")" = 0 ]
  [ "$(jq -r '.services.wordpress.networks | keys | join(",")' <<<"$cfg")" = default ]
  for s in db cli; do
    [ "$(jq -r --arg s "$s" '.services[$s].ports // [] | length' <<<"$cfg")" = 0 ]
  done
}

@test "merged expose config: WordPress on default and web with the host label, no published port" {
  app_prepare
  cfg="$(merged_config compose.yml compose.expose.yml)"
  [ "$(jq -r '.services.wordpress.networks | keys | join(",")' <<<"$cfg")" = "default,web" ]
  [ "$(jq -r '.services.wordpress.labels.caddy' <<<"$cfg")" = wp.example.com ]
  [ "$(jq -r '.services.wordpress.labels["caddy.reverse_proxy"]' <<<"$cfg")" = "{{upstreams 80}}" ]
  for s in db wordpress cli; do
    [ "$(jq -r --arg s "$s" '.services[$s].ports // [] | length' <<<"$cfg")" = 0 ]
  done
  [ "$(jq -r '.services.db.networks | keys | join(",")' <<<"$cfg")" = default ]
}

@test "merged config: WordPress knows its HTTPS address, and WP-CLI gets the same environment" {
  app_prepare
  cfg="$(merged_config compose.yml compose.expose.yml)"
  extra="$(jq -r '.services.wordpress.environment.WORDPRESS_CONFIG_EXTRA' <<<"$cfg")"
  grep -qxF "define('WP_HOME', 'https://wp.example.com');" <<<"$extra"
  grep -qxF "define('WP_SITEURL', 'https://wp.example.com');" <<<"$extra"
  [ "$(jq -r '.services.wordpress.environment.WORDPRESS_DB_HOST' <<<"$cfg")" = db ]
  [ "$(jq -r '.services.wordpress.environment.WORDPRESS_DB_PASSWORD' <<<"$cfg")" = "$(sed -n 's/^DB_PASSWORD=//p' "$DATA/.env")" ]
  [ "$(jq -r '.services.db.environment.MARIADB_PASSWORD' <<<"$cfg")" = "$(sed -n 's/^DB_PASSWORD=//p' "$DATA/.env")" ]
  for k in "${SALTS[@]}"; do
    [ "$(jq -r --arg k "$k" '.services.wordpress.environment[$k]' <<<"$cfg")" = "$(sed -n "s/^$k=//p" "$DATA/.env")" ]
  done
  # WP-CLI loads wp-config.php, which reads the environment: it needs every WordPress variable.
  [ "$(jq -c '.services.cli.environment | del(.HOME)' <<<"$cfg")" = "$(jq -c '.services.wordpress.environment' <<<"$cfg")" ]
  [ "$(jq -r '.services.cli.environment.HOME' <<<"$cfg")" = /tmp ]
  [ "$(jq -r '.services.cli.user' <<<"$cfg")" = "33:33" ]
  [ "$(jq -r '.services.cli.profiles | join(",")' <<<"$cfg")" = cli ]
  [ "$(jq -r '.services.cli.volumes[0].source' <<<"$cfg")" = "$(jq -r '.services.wordpress.volumes[0].source' <<<"$cfg")" ]
}

@test "merged config: MariaDB root stays on localhost, upgrades itself and has a real healthcheck" {
  app_prepare
  cfg="$(merged_config compose.yml compose.setup.yml)"
  [ "$(jq -r '.services.db.environment.MARIADB_ROOT_HOST' <<<"$cfg")" = localhost ]
  [ "$(jq -r '.services.db.environment.MARIADB_AUTO_UPGRADE' <<<"$cfg")" = 1 ]
  [ "$(jq -r '.services.db.environment.MARIADB_ROOT_PASSWORD' <<<"$cfg")" = "$(sed -n 's/^DB_ROOT_PASSWORD=//p' "$DATA/.env")" ]
  [ "$(jq -c '.services.db.healthcheck.test' <<<"$cfg")" = '["CMD","healthcheck.sh","--connect","--innodb_initialized"]' ]
  [ "$(jq -r '.services.wordpress.depends_on.db.condition' <<<"$cfg")" = service_healthy ]
  [ "$(jq -r '.services.cli.depends_on.db.condition' <<<"$cfg")" = service_healthy ]
}

@test "the compose files carry no admin password, and only the database passwords from the .env" {
  run grep -hiE 'password' "$APP_DIR"/compose.yml "$APP_DIR"/compose.setup.yml "$APP_DIR"/compose.expose.yml
  [ -n "$output" ]
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *'${DB_PASSWORD:?'* || "$line" == *'${DB_ROOT_PASSWORD:?'* ]]
  done <<<"$output"
  refute_grep -qiE 'admin_password|ADMIN_PASS|user_pass' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl"
}

@test "no open signup: nothing turns registration on, and the admin step sets it off explicitly" {
  refute_grep -qiE 'users_can_register[^0-9]*1|WP_ALLOW_MULTISITE|default_role' "$APP_DIR"/compose*.yml "$APP_DIR/env.tmpl" "$APP_DIR/app.sh"
  app_prepare
  stub_docker
  stub_curl
  app_create_admin "$PWF"
  wp_runs 'option update users_can_register 0$'
  [ "$(cat "$WP/option.users_can_register")" = 0 ]
}

@test "app_up_setup starts the stack with the setup file" {
  app_prepare
  stub_docker
  app_up_setup
  grep -qxF "docker compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.setup.yml --env-file $DATA/.env up -d" "$EVENTS"
}

@test "the admin is created by wp core install on the loopback stack, with the documented arguments" {
  app_prepare
  stub_docker
  stub_curl
  app_create_admin "$PWF"
  run wp_runs 'core install '
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "docker compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.setup.yml --env-file $DATA/.env run --rm -T cli wp core install "* ]]
  for a in --url=https://wp.example.com '--title=My WordPress Site' --admin_user=admin \
    --admin_email=admin@wp.example.com --skip-email --prompt=admin_password; do
    grep -qxF -- "$a" "$DOCKER_ARGV"
  done
  refute_grep -qE -- '^--admin_pass(word)?=' "$DOCKER_ARGV"
}

@test "the admin email is the one install.sh settled on (VA_ADMIN_EMAIL), else admin@<host>" {
  app_prepare
  stub_docker
  stub_curl
  VA_ADMIN_EMAIL=owner@example.org app_create_admin "$PWF"
  grep -qxF -- --admin_email=owner@example.org "$DOCKER_ARGV"
}

@test "the password reaches WP-CLI's prompt on stdin, byte for byte, one line" {
  app_prepare
  stub_docker
  stub_curl
  printf '%s' "$NASTY_PW" >"$PWF"
  app_create_admin "$PWF"
  n="$(grep -nE ' run --rm -T cli wp core install ' "$EVENTS" | head -n1 | cut -d: -f1)"
  [ -n "$n" ]
  # The prompt reads one line: the exact bytes and a newline.
  printf '%s\n' "$NASTY_PW" >"$BATS_TEST_TMPDIR/want"
  install_run="$(grep -c ' run ' <(head -n "$n" "$EVENTS"))"
  cmp "$WP/stdin.$install_run" "$BATS_TEST_TMPDIR/want"
  printf '%s' "$NASTY_PW" >"$BATS_TEST_TMPDIR/stored"
  cmp "$WP/admin_password" "$BATS_TEST_TMPDIR/stored"
}

@test "the login is checked afterwards on another path: the raw password on stdin, as wp-login.php compares it" {
  app_prepare
  stub_docker
  stub_curl
  printf '%s' "$NASTY_PW" >"$PWF"
  app_create_admin "$PWF"
  run wp_runs 'eval '
  [ "${#lines[@]}" -eq 1 ]
  last="$(cat "$WP/runs")"
  cmp "$WP/stdin.$last" "$PWF"
  # The check is WordPress's own, for the admin login, with the slashes wp-login.php adds.
  [[ "$WP_ADMIN_CHECK_PHP" == *'get_user_by("login", "admin")'* ]]
  [[ "$WP_ADMIN_CHECK_PHP" == *'wp_check_password(wp_slash($p), $u->user_pass, $u->ID)'* ]]
  [[ "$WP_ADMIN_CHECK_PHP" == *'"administrator"'* ]]
  [[ "$WP_ADMIN_CHECK_PHP" == *'php://stdin'* ]]
}

@test "the password never reaches an argument, the .env, the compose files or the install log" {
  app_prepare
  stub_docker
  stub_curl
  printf '%s' 'Zq9UniqueSecret' >"$PWF"
  app_create_admin "$PWF"
  refute_grep -qF 'Zq9UniqueSecret' "$DOCKER_ARGV" "$EVENTS" "$DATA/.env" "$APP_DIR"/compose*.yml
  # The stub echoes the prompt answer to stdout, as readline can: that output is never kept.
  refute_grep -qF 'Zq9UniqueSecret' "$(p /var/log/vps-apps-install.log)"
  run grep -rlF 'Zq9UniqueSecret' "$DATA"
  [ -z "$output" ]
}

@test "the password stays out of the log when the install fails, even from a PHP stack trace" {
  app_prepare
  stub_docker
  stub_curl
  printf '%s' 'Zq9UniqueSecret' >"$PWF"
  WP_INSTALL_RC=1 run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  refute_grep -qF 'Zq9UniqueS' "$(p /var/log/vps-apps-install.log)"
  grep -qF 'Error establishing a database connection' "$(p /var/log/vps-apps-install.log)"
  grep -qF 'PHP Fatal error:  Uncaught Exception: boom' "$(p /var/log/vps-apps-install.log)"
}

@test "the password stays out of the log when the login check fails, even when echoed whole" {
  app_prepare
  stub_docker
  stub_curl
  printf '%s' 'Zq9UniqueSecret' >"$PWF"
  WP_EVAL_RC=1 run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  refute_grep -qF 'Zq9UniqueS' "$(p /var/log/vps-apps-install.log)"
  grep -qF 'the password itself: <password>' "$(p /var/log/vps-apps-install.log)"
}

@test "a failing wp core install fails the step, and nothing after it runs" {
  app_prepare
  stub_docker
  stub_curl
  WP_INSTALL_RC=1 run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  run wp_runs 'eval '
  [ -z "$output" ]
  run wp_runs 'option update'
  [ -z "$output" ]
}

@test "a login check that fails fails the step" {
  app_prepare
  stub_docker
  stub_curl
  WP_EVAL_RC=1 run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  grep -qF 'wordpress: the admin cannot log in' "$(p /var/log/vps-apps-install.log)"
}

@test "a docker failure on the registration setting fails the step" {
  app_prepare
  stub_docker
  stub_curl
  DOCKER_FAIL_MATCH='option update' run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
}

@test "a retry is idempotent: WordPress says it is installed, the admin keeps the first password" {
  app_prepare
  stub_docker
  stub_curl
  app_create_admin "$PWF"
  cp "$WP/admin_password" "$BATS_TEST_TMPDIR/first"
  app_create_admin "$PWF"
  cmp "$WP/admin_password" "$BATS_TEST_TMPDIR/first"
  [ "$(wp_runs 'core install ' | wc -l)" -eq 2 ]
  [ "$(wp_runs 'eval ' | wc -l)" -eq 2 ]
}

@test "a retry with another password fails instead of passing on the old admin" {
  app_prepare
  stub_docker
  stub_curl
  app_create_admin "$PWF"
  printf '%s' 'Other12345' >"$PWF"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
}

@test "app_create_admin waits for WordPress on loopback, bounded, before any WP-CLI call" {
  app_prepare
  stub_docker
  stub_curl
  echo 2 >"$WP/web_fail"
  app_create_admin "$PWF"
  [ "$(grep -c '^curl .*http://127.0.0.1:8080/wp-login.php' "$EVENTS")" -eq 3 ]
  [ "$(line_of '^curl ')" -lt "$(line_of ' run --rm -T cli ')" ]
  grep -qF -- '--max-time 30' "$EVENTS"
}

@test "app_create_admin fails when WordPress never answers on loopback, and runs no WP-CLI" {
  app_prepare
  stub_docker
  stub_curl
  echo forever >"$WP/web_fail"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  refute_grep -q ' run ' "$EVENTS"
}

@test "WordPress's own rule takes every password the order form allows, at 8 and 64 characters" {
  app_prepare
  stub_docker
  stub_curl
  for good in Abcdefg1 "$NASTY_PW" "A1$(printf 'x%.0s' $(seq 62))" 'Ab1 with spaces inside'; do
    rm -f "$WP/installed"
    printf '%s' "$good" >"$PWF"
    app_create_admin "$PWF"
    [ "$(cat "$WP/admin_password")" = "$good" ]
  done
  [ "${#good}" -gt 8 ]
}

@test "a password WP-CLI's one-line prompt cannot carry is refused before any docker call" {
  app_prepare
  stub_docker
  stub_curl
  for bad in '' $'Pass\nword1X' $'Tab\tPass1' 'Pässword1x' ' Lead1space' 'Trail1space ' \
    "$(printf 'A1%.0s' $(seq 128))"; do
    printf '%s' "$bad" >"$PWF"
    : >"$EVENTS"
    run app_create_admin "$PWF"
    [ "$status" -ne 0 ]
    refute_grep -q '^docker ' "$EVENTS"
  done
  printf 'Abc1\0def' >"$PWF"
  run app_create_admin "$PWF"
  [ "$status" -ne 0 ]
  refute_grep -q '^docker ' "$EVENTS"
}

@test "app_expose writes the marker, puts the site in app mode and starts the expose file" {
  app_prepare
  stub_docker
  stub_curl
  app_create_admin "$PWF"
  app_expose
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
  grep -qxF "docker compose -f $APP_DIR/compose.yml -f $APP_DIR/compose.expose.yml --env-file $DATA/.env up -d" "$EVENTS"
}

@test "app_expose refuses while WordPress is not installed: install.php never goes public" {
  app_prepare
  stub_docker
  stub_curl
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  [ ! -e "$(p /var/lib/vps-apps/site-mode)" ]
  refute_grep -q compose.expose.yml "$EVENTS"
  wp_runs 'core is-installed$'
}

@test "app_expose refuses while registration is open or cannot be read" {
  app_prepare
  stub_docker
  stub_curl
  app_create_admin "$PWF"
  for v in 1 '' 'Error: something'; do
    WP_OPTION_GET="$v" run app_expose
    [ "$status" -ne 0 ]
    [ ! -e "$DATA/exposed" ]
    refute_grep -q compose.expose.yml "$EVENTS"
  done
  DOCKER_FAIL_MATCH='option get' run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
}

@test "app_expose brings the setup stack up and checks WordPress before the expose file starts" {
  app_prepare
  stub_docker
  stub_curl
  app_create_admin "$PWF"
  : >"$DATA/exposed"
  : >"$EVENTS"
  app_expose
  setup="$(line_of 'compose.setup.yml.* up -d$')"
  probe="$(line_of '^curl .*127.0.0.1:8080')"
  installed="$(line_of 'cli wp core is-installed$')"
  signup="$(line_of 'cli wp option get users_can_register$')"
  expose="$(line_of 'compose.expose.yml.* up -d$')"
  [ -n "$setup" ] && [ -n "$probe" ] && [ -n "$installed" ] && [ -n "$signup" ] && [ -n "$expose" ]
  [ "$setup" -lt "$probe" ] && [ "$probe" -lt "$installed" ] && [ "$installed" -lt "$signup" ] && [ "$signup" -lt "$expose" ]
}

@test "the whole app sequence: setup, then the admin, then exposure, and only then the labels" {
  app_prepare
  stub_docker
  stub_curl
  app_up_setup
  app_create_admin "$PWF"
  app_expose
  [ "$(line_of 'compose.setup.yml.* up -d$')" -lt "$(line_of 'cli wp core install ')" ]
  [ "$(line_of 'cli wp core install ')" -lt "$(line_of 'cli wp eval ')" ]
  [ "$(line_of 'cli wp eval ')" -lt "$(line_of 'compose.expose.yml.* up -d$')" ]
  # No call before the admin existed named the expose file.
  refute_grep -q compose.expose.yml <(head -n "$(line_of 'cli wp eval ')" "$EVENTS")
}

@test "a failed start in app_expose takes the stack down, drops the marker and shows the failed page" {
  app_prepare
  stub_docker
  stub_curl
  app_create_admin "$PWF"
  DOCKER_FAIL_MATCH='compose.expose.yml --env-file' run app_expose
  [ "$status" -ne 0 ]
  grep -q ' down$' "$EVENTS"
  [ ! -e "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = failed ]
  # A retry recovers.
  run app_expose
  [ "$status" -eq 0 ]
  [ -f "$DATA/exposed" ]
  [ "$(cat "$(p /var/lib/vps-apps/site-mode)")" = app ]
}

@test "app_expose fails without exposing when WordPress never answers after the setup stack is up" {
  app_prepare
  stub_docker
  stub_curl
  app_create_admin "$PWF"
  echo forever >"$WP/web_fail"
  : >"$EVENTS"
  run app_expose
  [ "$status" -ne 0 ]
  [ ! -e "$DATA/exposed" ]
  refute_grep -q compose.expose.yml "$EVENTS"
}

REST_OK='{"name":"My WordPress Site","url":"https:\/\/wp.example.com","home":"https:\/\/wp.example.com","namespaces":["wp\/v2"]}'

@test "app_ready_check needs WordPress itself over HTTPS on the server's own name, at its HTTPS address" {
  stub_curl
  REST_BODY="$REST_OK" app_ready_check
  grep -qF -- "--resolve wp.example.com:443:127.0.0.1 https://wp.example.com/?rest_route=/" "$EVENTS"
  refute_grep -qE -- ' -k | --insecure' "$EVENTS"
  # WordPress believing it lives on http:// (no HTTPS behind the proxy) is not ready.
  REST_BODY='{"home":"http:\/\/wp.example.com"}' run app_ready_check
  [ "$status" -ne 0 ]
  REST_BODY='<html>installing</html>' run app_ready_check
  [ "$status" -ne 0 ]
  REST_BODY='' run app_ready_check
  [ "$status" -ne 0 ]
  curl() { printf '%s' "$REST_OK"; return 60; }
  run app_ready_check
  [ "$status" -ne 0 ]
}

@test "extra domains are refused with a clear message, and nothing changes" {
  app_prepare
  stub_docker
  cp "$DATA/.env" "$BATS_TEST_TMPDIR/env"
  : >"$EVENTS"
  run app_domain_check www.example.org
  [ "$status" -ne 0 ]
  [[ "$output" == *"https://wp.example.com"* ]]
  [[ "$output" == *"WordPress"* ]]
  run app_domain_added www.example.org
  [ "$status" -ne 0 ]
  cmp "$DATA/.env" "$BATS_TEST_TMPDIR/env"
  [ ! -s "$EVENTS" ]
}
