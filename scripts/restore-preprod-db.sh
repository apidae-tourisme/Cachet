#!/usr/bin/env bash
# Restaure la base de prod dans le PostgreSQL CNPG de PRÉPRODUCTION,
# puis l'assainit pour les tests de migration :
#   - TRUNCATE jobs / failed_jobs : l'historique de prod traîne 26k+ jobs
#     jamais traités, le worker les enverrait tous
#   - TRUNCATE sessions : bascule SESSION_DRIVER file -> database
#   - TRUNCATE subscribers (+ subscriptions) : GARDE-FOU PREPROD — aucun mail ne
#     doit jamais partir vers un vrai abonné depuis la préproduction. Pour tester
#     les notifications, se réinscrire via /subscribe avec une adresse de test.
#
# Usage :
#   scripts/restore-preprod-db.sh              # dump direct depuis la prod (SSH, lecture seule)
#   scripts/restore-preprod-db.sh fichier.dump # restaure un dump -Fc existant
#
# Prérequis : kubectl configuré sur le cluster preprod, secret status-user déployé
# (branche flux preprod_status_1.0.0), base "status" créée par CNPG.
set -euo pipefail

cd "$(dirname "$0")/.."

# Repo public : les infos d'accès vivent dans scripts/.env (gitignoré),
# cf. scripts/.env.example
if [ -f scripts/.env ]; then set -a; . ./scripts/.env; set +a; fi
PG_NAMESPACE="${PREPROD_PG_NAMESPACE:?PREPROD_PG_NAMESPACE manquant : copier scripts/.env.example en scripts/.env et le compléter}"
PG_SERVICE="${PREPROD_PG_SERVICE:?PREPROD_PG_SERVICE manquant : copier scripts/.env.example en scripts/.env et le compléter}"
LOCAL_PORT=5433
DUMP_FILE="${1:-}"

# --- Garde-fou : jamais sur la production ---
CONTEXT="$(kubectl config current-context)"
if echo "$CONTEXT" | grep -qi "production"; then
    echo "!! Contexte kubectl actuel : $CONTEXT"
    echo "!! Ce script assainit la base (purge des abonnés) : il est réservé à la PREPRODUCTION."
    echo "!! La bascule de production suit une procédure dédiée (conservation des abonnés)."
    exit 1
fi
echo ">> Contexte kubectl : $CONTEXT"

# --- Mot de passe du rôle status (secret CNPG) ---
DB_PWD="$(kubectl get secret status-user -n "$PG_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)"
[ -n "$DB_PWD" ] || { echo "secret status-user introuvable dans $PG_NAMESPACE"; exit 1; }

# --- Dump depuis la prod si aucun fichier fourni ---
if [ -z "$DUMP_FILE" ]; then
    SSH_HOST="${STATUS_PROD_SSH:?STATUS_PROD_SSH manquant : copier scripts/.env.example en scripts/.env et le compléter}"
    DUMP_FILE="$(mktemp -t status-prod-XXXXXX.dump)"
    CLEAN_DUMP=1
    echo ">> Dump de la base de prod via SSH (lecture seule)..."
    ssh "$SSH_HOST" 'cd ~/www/Cachet \
        && PGPASSWORD="$(grep ^DB_PASSWORD .env | cut -d= -f2-)" \
           pg_dump -Fc \
             -h "$(grep ^DB_HOST .env | cut -d= -f2-)" \
             -p "$(grep ^DB_PORT .env | cut -d= -f2-)" \
             -U "$(grep ^DB_USERNAME .env | cut -d= -f2-)" \
             "$(grep ^DB_DATABASE .env | cut -d= -f2-)"' > "$DUMP_FILE"
    echo ">> Dump récupéré : $(du -h "$DUMP_FILE" | cut -f1)"
fi

# --- Port-forward vers le cluster CNPG ---
kubectl port-forward -n "$PG_NAMESPACE" "svc/$PG_SERVICE" "$LOCAL_PORT:5432" >/dev/null 2>&1 &
PF_PID=$!
cleanup() {
    kill "$PF_PID" 2>/dev/null || true
    [ "${CLEAN_DUMP:-0}" = 1 ] && rm -f "$DUMP_FILE"
}
trap cleanup EXIT
sleep 3

# psql/pg_restore via l'image postgres:18 (alignée sur le serveur CNPG),
# en réseau hôte pour atteindre le port-forward local.
run_psql() {
    docker run --rm -i --network host -e PGPASSWORD="$DB_PWD" postgres:18 \
        psql -q -h 127.0.0.1 -p "$LOCAL_PORT" -U status -d status "$@"
}

echo ">> Réinitialisation du schéma public..."
run_psql -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'

echo ">> Restauration du dump..."
docker run --rm -i --network host -e PGPASSWORD="$DB_PWD" postgres:18 \
    pg_restore --no-owner --role=status -h 127.0.0.1 -p "$LOCAL_PORT" -U status -d status < "$DUMP_FILE"

echo ">> Assainissement (jobs, failed_jobs, sessions + PURGE DES ABONNÉS)..."
# NB : pas de contrainte FK entre subscriptions et subscribers (migrations
# Laravel sans FK), un TRUNCATE ... CASCADE ne suffirait pas — on liste les
# deux tables explicitement.
run_psql -c 'TRUNCATE TABLE jobs, failed_jobs, sessions;'
run_psql -c 'TRUNCATE TABLE subscribers, subscriptions;'

echo ">> Compteurs après import :"
run_psql -c \
    "SELECT 'subscribers (attendu: 0)' AS table, count(*) FROM subscribers
     UNION ALL SELECT 'subscriptions (attendu: 0)', count(*) FROM subscriptions
     UNION ALL SELECT 'components', count(*) FROM components
     UNION ALL SELECT 'incidents', count(*) FROM incidents
     UNION ALL SELECT 'users', count(*) FROM users
     UNION ALL SELECT 'jobs (attendu: 0)', count(*) FROM jobs;"

SUBS=$(run_psql -tA -c 'SELECT count(*) FROM subscribers;')
[ "$SUBS" = "0" ] || { echo "!! ECHEC garde-fou : il reste $SUBS abonnés"; exit 1; }

echo ">> Import préproduction terminé. Redémarrer l'app : kubectl rollout restart deployment/status-web-app deployment/status-worker -n status"
