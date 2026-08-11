# Cachet (apidae-status) — image de production
# PHP 7.3 imposé par l'application (Laravel 5.7, gelée upstream).
# Base Debian 11 bullseye (EOL LTS 2026-08) : si les miroirs standards ne servent
# plus bullseye, basculer les sources vers archive.debian.org/debian (+ l'option
# Acquire::Check-Valid-Until "false").
FROM php:7.3-apache

# Extensions PHP requises par l'application
# (pdo_pgsql n'est pas déclaré dans composer.json mais la prod est en PostgreSQL)
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libpq-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libfreetype6-dev \
        libzip-dev \
        unzip \
    ; \
    docker-php-ext-configure gd --with-freetype-dir=/usr --with-jpeg-dir=/usr; \
    docker-php-ext-install -j"$(nproc)" pdo_pgsql pgsql gd zip; \
    rm -rf /var/lib/apt/lists/*

# Apache : écoute sur 8080 (convention du cluster), front controller Laravel
RUN set -eux; \
    a2enmod rewrite headers; \
    sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf; \
    echo 'ServerName localhost' > /etc/apache2/conf-available/servername.conf; \
    a2enconf servername
COPY docker/apache-vhost.conf /etc/apache2/sites-available/000-default.conf
COPY docker/php.ini "$PHP_INI_DIR/conf.d/zz-cachet.ini"

COPY --from=composer:2.2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html
COPY . /var/www/html

# --no-scripts : le hook post-autoload-dump boote l'application (package:discover),
# impossible au build sans configuration. Le manifest de packages se régénère au
# premier démarrage, bootstrap/cache restant accessible en écriture.
# Aucun `config:cache` : la config doit être lue depuis les variables d'environnement
# à l'exécution (le reCAPTCHA lit env() au runtime).
RUN set -eux; \
    COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-scripts --prefer-dist --optimize-autoloader --no-interaction; \
    rm -f /usr/bin/composer; \
    ln -sfn ../storage/app/public public/storage; \
    chown -R www-data:www-data storage bootstrap/cache bootstrap/cachet

ENTRYPOINT ["/var/www/html/docker/entrypoint.sh"]
CMD ["apache2-foreground"]
