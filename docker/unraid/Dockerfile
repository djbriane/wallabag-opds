# syntax=docker/dockerfile:1
#
# Production image that mirrors the official wallabag/wallabag image
# (alpine + s6 + nginx + php-fpm, app at /var/www/wallabag, port 80) but is
# built from this local source tree so the OPDS catalog is baked in.
#
# Build from the repository root:
#   docker buildx build -f docker/unraid/Dockerfile -t <user>/wallabag-opds:latest .

ARG COMPOSER_VERSION=2.7

# ---------------------------------------------------------------------------
# Stage 1 — build front-end assets (Symfony Encore / webpack)
# ---------------------------------------------------------------------------
FROM node:24-bookworm AS assets

WORKDIR /build
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile --network-timeout 600000

COPY . .
RUN yarn build:prod

# ---------------------------------------------------------------------------
# Stage 2 — composer binary
# ---------------------------------------------------------------------------
FROM composer:${COMPOSER_VERSION} AS composer

# ---------------------------------------------------------------------------
# Stage 3 — envsubst (supports default values, unlike gettext's envsubst)
# ---------------------------------------------------------------------------
FROM golang:alpine AS envsubst
RUN go install -ldflags "-s -w" -v github.com/a8m/envsubst/cmd/envsubst@v1.4.3

# ---------------------------------------------------------------------------
# Stage 4 — final runtime image
# ---------------------------------------------------------------------------
FROM alpine:3.24

COPY --from=envsubst /go/bin/envsubst /usr/bin/envsubst
COPY --from=composer /usr/bin/composer /usr/local/bin/composer

RUN set -ex \
 && apk add --no-cache \
      curl \
      libwebp \
      nginx \
      pcre \
      php84 \
      php84-ctype \
      php84-curl \
      php84-dom \
      php84-fileinfo \
      php84-fpm \
      php84-gd \
      php84-gettext \
      php84-iconv \
      php84-intl \
      php84-mbstring \
      php84-opcache \
      php84-openssl \
      php84-pdo_mysql \
      php84-pdo_pgsql \
      php84-pdo_sqlite \
      php84-pecl-amqp \
      php84-pecl-imagick \
      php84-phar \
      php84-session \
      php84-simplexml \
      php84-sodium \
      php84-sockets \
      php84-tidy \
      php84-tokenizer \
      php84-xml \
      php84-xmlreader \
      php84-zlib \
      mariadb-client \
      postgresql17-client \
      rabbitmq-c \
      s6 \
      tar \
      tzdata \
      unzip \
 && ln -sf /usr/bin/php84 /usr/bin/php \
 && ln -sf /usr/sbin/php-fpm84 /usr/sbin/php-fpm \
 && rm -rf /var/cache/apk/* \
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log

# s6 services, nginx config, entrypoint, php override template
COPY docker/unraid/root /
RUN chmod +x /entrypoint.sh /etc/s6/*/run /etc/s6/*/finish /etc/s6/.s6-svscan/finish

# Application source (node_modules / vendor / .git excluded via .dockerignore)
RUN mkdir -p /var/www/wallabag
COPY . /var/www/wallabag/
# Pre-built front-end assets from the node stage
COPY --from=assets /build/web/build /var/www/wallabag/web/build

ENV APP_ENV=prod \
    APP_DEBUG=0 \
    COMPOSER_ALLOW_SUPERUSER=1

WORKDIR /var/www/wallabag

# The composer post-install scripts run `cache:clear`, which needs the app's
# environment variables. This source tree reads them as real env vars, so load
# the committed .env defaults into the build shell before installing.
RUN set -ex \
 && mkdir -p data/assets data/db var/cache var/logs \
 && set -a && . ./.env && set +a \
 && composer install --no-dev -o --prefer-dist --no-progress --no-interaction \
 && composer clear-cache \
 && rm -rf var/cache/* var/logs/* \
 && chown -R nobody:nobody /var/www/wallabag

ENV PATH="${PATH}:/var/www/wallabag/bin"

VOLUME /var/www/wallabag/data

HEALTHCHECK CMD curl --fail --silent --show-error --user-agent healthcheck http://localhost/api/info || exit 1

EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
CMD ["wallabag"]
