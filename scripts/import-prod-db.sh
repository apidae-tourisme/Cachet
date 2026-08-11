#!/usr/bin/env bash
# Importe la base de prod dans le PostgreSQL du docker-compose local,
# puis l'assainit pour les tests de migration :
#   - TRUNCATE jobs / failed_jobs : 26k+ jobs jamais traités en prod, un worker
#     local enverrait des milliers de vieux mails
#   - TRUNCATE sessions : bascule SESSION_DRIVER file -> database
#
# Usage :
#   scripts/import-prod-db.sh              # dump direct depuis la prod (SSH, lecture seule)
#   scripts/import-prod-db.sh fichier.dump # restaure un dump -Fc existant
#
# Rappel : pour pouvoir se connecter au back-office sur les données de prod,
# renseigner APP_KEY (celle de la prod) dans le .env avant `docker compose up`.
set -euo pipefail

cd "$(dirname "$0")/.."

# Repo public : les infos d'accès vivent dans scripts/.env (gitignoré),
# cf. scripts/.env.example
if [ -f scripts/.env ]; then set -a; . ./scripts/.env; set +a; fi
DUMP_FILE="${1:-}"

if [ -z "$DUMP_FILE" ]; then
    SSH_HOST="${STATUS_PROD_SSH:?STATUS_PROD_SSH manquant : copier scripts/.env.example en scripts/.env et le compléter}"
    DUMP_FILE="$(mktemp -t status-prod-XXXXXX.dump)"
    trap 'rm -f "$DUMP_FILE"' EXIT
    echo ">> Dump de la base de prod via SSH (lecture seule)..."
    # Les identifiants sont lus dans le .env du serveur, le dump est exécuté
    # côté serveur de prod et streamé en local.
    ssh "$SSH_HOST" 'cd ~/www/Cachet \
        && PGPASSWORD="$(grep ^DB_PASSWORD .env | cut -d= -f2-)" \
           pg_dump -Fc \
             -h "$(grep ^DB_HOST .env | cut -d= -f2-)" \
             -p "$(grep ^DB_PORT .env | cut -d= -f2-)" \
             -U "$(grep ^DB_USERNAME .env | cut -d= -f2-)" \
             "$(grep ^DB_DATABASE .env | cut -d= -f2-)"' > "$DUMP_FILE"
    echo ">> Dump récupéré : $(du -h "$DUMP_FILE" | cut -f1)"
fi

echo ">> Démarrage du conteneur db..."
docker compose up -d --wait db

echo ">> Réinitialisation du schéma public..."
docker compose exec -T db psql -q -U status -d status \
    -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'

echo ">> Restauration du dump..."
docker compose exec -T db pg_restore --no-owner --role=status -U status -d status < "$DUMP_FILE"

echo ">> Patch schéma failed_jobs (migration Cachet 2015 incomplète pour Laravel 5.5)..."
docker compose exec -T db psql -q -U status -d status \
    -c 'ALTER TABLE failed_jobs ADD COLUMN IF NOT EXISTS exception text;' \
    -c 'ALTER TABLE failed_jobs ALTER COLUMN failed_at SET DEFAULT CURRENT_TIMESTAMP;'

echo ">> Assainissement (jobs, failed_jobs, sessions)..."
docker compose exec -T db psql -q -U status -d status \
    -c 'TRUNCATE TABLE jobs, failed_jobs, sessions;'

echo ">> Compteurs après import :"
docker compose exec -T db psql -U status -d status -c \
    "SELECT 'subscribers' AS table, count(*) FROM subscribers
     UNION ALL SELECT 'components', count(*) FROM components
     UNION ALL SELECT 'incidents', count(*) FROM incidents
     UNION ALL SELECT 'users', count(*) FROM users
     UNION ALL SELECT 'jobs', count(*) FROM jobs;"

echo ">> Invalidation du cache de settings de l'app (si elle tourne)..."
docker compose exec -T app sh -c 'rm -f bootstrap/cachet/*.php' 2>/dev/null || true

echo ">> Import terminé. Redémarrer l'app si elle tournait : docker compose restart app worker"
