#!/bin/sh
# En Kubernetes, /var/www/html/storage est un emptyDir vide : on recrée
# l'arborescence attendue par Laravel à chaque démarrage.
set -e

cd /var/www/html

mkdir -p \
    storage/framework/views \
    storage/framework/sessions \
    storage/framework/cache/data \
    storage/logs \
    storage/app/public

# bootstrap/cachet : cache des settings applicatifs — s'il n'est pas accessible
# en écriture, l'app démarre avec des settings vides (pages cassées)
chown -R www-data:www-data storage bootstrap/cache bootstrap/cachet

exec "$@"
