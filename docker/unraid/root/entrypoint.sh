#!/bin/sh
# Exit when any command fails
set -e

COMMAND_ARG1="$1"
COMMAND_ARG2="$2"

WALLABAG_DIR=/var/www/wallabag
cd "$WALLABAG_DIR" || exit

# ---------------------------------------------------------------------------
# Compatibility shim
#
# The official wallabag/wallabag image (2.6.x) is configured through
# parameters.yml + SYMFONY__ENV__* environment variables. This image is built
# from a newer wallabag source tree (with the OPDS catalog) that is configured
# through real environment variables (DATABASE_URL, WALLABAG_*, ...).
#
# To stay drop-in compatible with the official image's Unraid template, we load
# the committed .env defaults and then translate the same SYMFONY__ENV__*
# variables the official image uses into the variables the new code reads. All
# of them are exported so the console commands below — and, after `exec
# s6-svscan`, the php-fpm workers (clear_env = no) — can see them.
# ---------------------------------------------------------------------------

bool_env() {
    # normalise true/false/1/0 -> 1/0
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) echo 1 ;;
        *) echo 0 ;;
    esac
}

load_environment() {
    # Defaults from the committed .env (APP_SECRET, locales, token lifetimes, ...)
    set -a
    # shellcheck disable=SC1091
    [ -f "$WALLABAG_DIR/.env" ] && . "$WALLABAG_DIR/.env"
    set +a

    # Build DATABASE_URL from the official SYMFONY__ENV__DATABASE_* variables
    driver="${SYMFONY__ENV__DATABASE_DRIVER:-pdo_sqlite}"
    case "$driver" in
        pdo_mysql)
            DATABASE_URL="mysql://${SYMFONY__ENV__DATABASE_USER:-root}:${SYMFONY__ENV__DATABASE_PASSWORD}@${SYMFONY__ENV__DATABASE_HOST:-127.0.0.1}:${SYMFONY__ENV__DATABASE_PORT:-3306}/${SYMFONY__ENV__DATABASE_NAME:-wallabag}?charset=${SYMFONY__ENV__DATABASE_CHARSET:-utf8mb4}"
            ;;
        pdo_pgsql)
            DATABASE_URL="postgresql://${SYMFONY__ENV__DATABASE_USER:-wallabag}:${SYMFONY__ENV__DATABASE_PASSWORD}@${SYMFONY__ENV__DATABASE_HOST:-127.0.0.1}:${SYMFONY__ENV__DATABASE_PORT:-5432}/${SYMFONY__ENV__DATABASE_NAME:-wallabag}?charset=${SYMFONY__ENV__DATABASE_CHARSET:-utf8}"
            ;;
        *)
            DATABASE_URL="sqlite:///%kernel.project_dir%/data/db/wallabag.sqlite"
            ;;
    esac
    export DATABASE_URL

    # Map the remaining SYMFONY__ENV__* overrides onto the new variable names
    [ -n "$SYMFONY__ENV__SECRET" ]              && export APP_SECRET="$SYMFONY__ENV__SECRET"
    [ -n "$SYMFONY__ENV__DATABASE_TABLE_PREFIX" ] && export WALLABAG_TABLE_PREFIX="$SYMFONY__ENV__DATABASE_TABLE_PREFIX"
    [ -n "$SYMFONY__ENV__DOMAIN_NAME" ]         && export WALLABAG_BASE_URL="$SYMFONY__ENV__DOMAIN_NAME"
    [ -n "$SYMFONY__ENV__SERVER_NAME" ]         && export WALLABAG_SERVER_NAME="$SYMFONY__ENV__SERVER_NAME"
    [ -n "$SYMFONY__ENV__LOCALE" ]              && export DEFAULT_LOCALE="$SYMFONY__ENV__LOCALE"
    [ -n "$SYMFONY__ENV__MAILER_DSN" ]          && export MAILER_DSN="$SYMFONY__ENV__MAILER_DSN"
    [ -n "$SYMFONY__ENV__FROM_EMAIL" ]          && export WALLABAG_FROM_EMAIL="$SYMFONY__ENV__FROM_EMAIL"
    [ -n "$SYMFONY__ENV__TWOFACTOR_SENDER" ]    && export WALLABAG_TWOFACTOR_SENDER="$SYMFONY__ENV__TWOFACTOR_SENDER"
    [ -n "$SYMFONY__ENV__FOSUSER_REGISTRATION" ] && export WALLABAG_REGISTRATION_ENABLED="$(bool_env "$SYMFONY__ENV__FOSUSER_REGISTRATION")"
    [ -n "$SYMFONY__ENV__FOSUSER_CONFIRMATION" ] && export WALLABAG_CONFIRMATION_ENABLED="$(bool_env "$SYMFONY__ENV__FOSUSER_CONFIRMATION")"
    [ -n "$SYMFONY__ENV__SENTRY_DSN" ]          && export SENTRY_DSN="$SYMFONY__ENV__SENTRY_DSN"
    if [ -n "$SYMFONY__ENV__REDIS_HOST" ]; then
        export REDIS_URL="${SYMFONY__ENV__REDIS_SCHEME:-redis}://${SYMFONY__ENV__REDIS_HOST}:${SYMFONY__ENV__REDIS_PORT:-6379}"
    fi
    if [ -n "$SYMFONY__ENV__RABBITMQ_HOST" ]; then
        export RABBITMQ_URL="amqp://${SYMFONY__ENV__RABBITMQ_USER:-guest}:${SYMFONY__ENV__RABBITMQ_PASSWORD:-guest}@${SYMFONY__ENV__RABBITMQ_HOST}:${SYMFONY__ENV__RABBITMQ_PORT:-5672}"
    fi

    export APP_ENV=prod
    export APP_DEBUG=0
}

wait_for_database() {
    timeout 60s /bin/sh -c "$(cat << EOF
        until echo 'Waiting for database ...' \
            && nc -z ${SYMFONY__ENV__DATABASE_HOST} ${SYMFONY__ENV__DATABASE_PORT} < /dev/null > /dev/null 2>&1 ; \
        do sleep 1 ; done
EOF
)"
}

run_console() {
    # Run as nobody while preserving the exported environment (su -p)
    su -p -s /bin/sh nobody -c "php bin/console $* --env=prod --no-interaction"
}

schema_present() {
    su -p -s /bin/sh nobody -c \
        "php bin/console doctrine:query:sql 'SELECT 1 FROM ${WALLABAG_TABLE_PREFIX:-wallabag_}user LIMIT 1' --env=prod" \
        > /dev/null 2>&1
}

provisioner() {
    driver="${SYMFONY__ENV__DATABASE_DRIVER:-pdo_sqlite}"
    SQLITE_DB_DIR="$WALLABAG_DIR/data/db"

    load_environment

    # Render the PHP override (memory_limit, ...)
    envsubst < /etc/wallabag/php-wallabag.template.ini > /etc/php84/conf.d/50_wallabag.ini

    if [ "$driver" = "pdo_sqlite" ]; then
        mkdir -p "$SQLITE_DB_DIR"
        chown nobody: "$SQLITE_DB_DIR"
    fi

    # Refresh the prod cache for the runtime configuration
    rm -rf "$WALLABAG_DIR/var/cache/prod"
    chown -R nobody: "$WALLABAG_DIR/var" "$WALLABAG_DIR/data"
    run_console cache:clear --no-warmup

    if [ "$driver" = "pdo_mysql" ] || [ "$driver" = "pdo_pgsql" ]; then
        wait_for_database
    fi

    if schema_present; then
        echo "Existing wallabag schema found, applying pending migrations ..."
        run_console doctrine:migrations:migrate || true
    else
        echo "No wallabag schema found, installing a fresh database ..."
        run_console wallabag:install
    fi
}

if [ "$COMMAND_ARG1" = "wallabag" ]; then
    echo "Starting wallabag ..."
    provisioner
    echo "wallabag is ready!"
    exec s6-svscan /etc/s6/
fi

if [ "$COMMAND_ARG1" = "import" ]; then
    provisioner
    exec su -p -s /bin/sh nobody -c "bin/console wallabag:import:redis-worker --env=prod $COMMAND_ARG2 -vv"
fi

if [ "$COMMAND_ARG1" = "migrate" ]; then
    provisioner
    exec su -p -s /bin/sh nobody -c "bin/console doctrine:migrations:migrate --env=prod --no-interaction"
fi

exec "$@"
