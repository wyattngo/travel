# syntax=docker/dockerfile:1
#
# Self-contained production image for ToursTravel Kenya (Laravel 11).
# One image runs nginx + php-fpm (via supervisor); migrations + caching happen
# on container start. Build context is trimmed via .dockerignore.
#
#   docker compose up -d --build   # one-command deploy (see docker-compose.yml)

############################
# Stage 1 — Frontend build  #
############################
FROM node:18-alpine AS frontend
WORKDIR /app
# laravel-mix/webpack 5 needs the legacy provider under OpenSSL 3 (node 18)
ENV NODE_OPTIONS=--openssl-legacy-provider
COPY package.json package-lock.json webpack.mix.js ./
RUN npm ci
COPY resources/ ./resources/
COPY public/ ./public/
RUN npm run production

#############################
# Stage 2 — PHP dependencies #
#############################
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-interaction --no-progress
COPY . .
RUN composer dump-autoload --optimize --no-dev

###############################
# Stage 3 — Production runtime #
###############################
# PHP 8.4 to match the composer image that resolves vendor/ (its platform_check
# pins >= 8.4.1) and the 8.4 toolchain the app was verified on.
FROM php:8.4-fpm-alpine AS production

# Runtime libs + nginx + supervisor; build PHP extensions then drop build deps
RUN apk add --no-cache \
        nginx supervisor \
        libpng libjpeg-turbo freetype libzip oniguruma \
    && apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
        libpng-dev libjpeg-turbo-dev freetype-dev libzip-dev oniguruma-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql mbstring bcmath gd zip exif pcntl opcache \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/*

WORKDIR /var/www/html

# Application (with optimized autoloader) + freshly compiled front-end assets
COPY --from=vendor   --chown=www-data:www-data /app                       /var/www/html
COPY --from=frontend --chown=www-data:www-data /app/public/css            ./public/css
COPY --from=frontend --chown=www-data:www-data /app/public/js             ./public/js
COPY --from=frontend --chown=www-data:www-data /app/public/mix-manifest.json ./public/mix-manifest.json

# Service configuration
COPY docker/php/local.ini    /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/nginx.prod.conf  /etc/nginx/http.d/default.conf
COPY docker/supervisord.conf /etc/supervisord.conf
COPY docker/entrypoint.sh    /usr/local/bin/entrypoint

RUN chmod +x /usr/local/bin/entrypoint \
    && chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R ug+rwx storage bootstrap/cache

EXPOSE 80
ENTRYPOINT ["entrypoint"]
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
