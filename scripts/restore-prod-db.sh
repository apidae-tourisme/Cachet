#!/usr/bin/env bash
# BASCULE DE PRODUCTION : restaure la base de l'hébergement actuel dans le
# PostgreSQL CNPG de PRODUCTION (jour J de la migration).
#
# Différences volontaires avec restore-preprod-db.sh :
#   - CONSERVE les abonnés (subscribers/subscriptions) : ce sont les vrais.
#   - Le dump EXCLUT les données de jobs/failed_jobs/sessions (sécurité
#     anti-envoi : l'historique de prod traîne 26k+ jobs jamais traités ;
#     exclus au dump, ils ne touchent jamais la nouvelle base, le worker
#     peut tourner pendant le restore sans risque).
#   - Patch du schéma failed_jobs (migration Cachet 2015 incomplète pour
#     Laravel 5.5 : colonne exception + défaut failed_at).
#   - Exige un contexte kubectl de PRODUCTION et une confirmation explicite.
#
# Usage :
#   scripts/restore-prod-db.sh              # dump direct depuis l'hébergement actuel (SSH)
#   scripts/restore-prod-db.sh fichier.dump # restaure un dump -Fc existant (déjà exclu !)
#
# Après le script : kubectl rollout restart deployment/status-web-app
# deployment/status-worker -n status, puis smoke tests via /etc/hosts
# AVANT la bascule DNS.
set -euo pipefail

cd "$(dirname "$0")/.."

# Repo public : les infos d'accès vivent dans scripts/.env (gitignoré),
# cf. scripts/.env.example
if [ -f scripts/.env ]; then set -a; . ./scripts/.env; set +a; fi
PG_NAMESPACE="${PROD_PG_NAMESPACE:?PROD_PG_NAMESPACE manquant : compléter scripts/.env (cf. scripts/.env.example)}"
PG_SERVICE="${PROD_PG_SERVICE:?PROD_PG_SERVICE manquant : compléter scripts/.env (cf. scripts/.env.example)}"
LOCAL_PORT=5434
DUMP_FILE="${1:-}"

# --- Garde-fou : uniquement sur la production ---
CONTEXT="$(kubectl config current-context)"
if ! echo "$CONTEXT" | grep -qi "production"; then
    echo "!! Contexte kubectl actuel : $CONTEXT"
    echo "!! Ce script restaure la base de PRODUCTION (abonnés conservés)."
    echo "!! Basculer sur le contexte production avant de relancer."
    exit 1
fi
echo ">> Contexte kubectl : $CONTEXT"
echo ">> Ce script va ÉCRASER la base status de PRODUCTION avec le dump."
printf ">> Taper exactement MIGRATION PROD pour continuer : "
read -r CONFIRM
[ "$CONFIRM" = "MIGRATION PROD" ] || { echo "Abandon."; exit 1; }

# --- Mot de passe du rôle status (secret CNPG) ---
DB_PWD="$(kubectl get secret status-user -n "$PG_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)"
[ -n "$DB_PWD" ] || { echo "secret status-user introuvable dans $PG_NAMESPACE"; exit 1; }

# --- Dump depuis l'hébergement actuel si aucun fichier fourni ---
if [ -z "$DUMP_FILE" ]; then
    SSH_HOST="${STATUS_PROD_SSH:?STATUS_PROD_SSH manquant : compléter scripts/.env (cf. scripts/.env.example)}"
    DUMP_FILE="$HOME/status-prod-final-$(date +%Y%m%d-%H%M%S).dump"
    echo ">> Dump final de la prod (données jobs/failed_jobs/sessions EXCLUES)..."
    ssh "$SSH_HOST" 'cd ~/www/Cachet \
        && PGPASSWORD="$(grep ^DB_PASSWORD .env | cut -d= -f2-)" \
           pg_dump -Fc \
             --exclude-table-data=jobs \
             --exclude-table-data=failed_jobs \
             --exclude-table-data=sessions \
             -h "$(grep ^DB_HOST .env | cut -d= -f2-)" \
             -p "$(grep ^DB_PORT .env | cut -d= -f2-)" \
             -U "$(grep ^DB_USERNAME .env | cut -d= -f2-)" \
             "$(grep ^DB_DATABASE .env | cut -d= -f2-)"' > "$DUMP_FILE"
    echo ">> Dump conservé (rollback/archive) : $DUMP_FILE ($(du -h "$DUMP_FILE" | cut -f1))"
fi

# --- Port-forward vers le cluster CNPG ---
# kubectl port-forward peut mourir dès qu'une connexion se ferme : on vérifie
# qu'il est vivant avant chaque commande SQL et on le relance au besoin.
PF_PID=""
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null && exec 3>&-; }
start_pf() {
    kubectl port-forward -n "$PG_NAMESPACE" "svc/$PG_SERVICE" "$LOCAL_PORT:5432" >/dev/null 2>&1 &
    PF_PID=$!
    for _ in $(seq 1 20); do
        port_open && return 0
        kill -0 "$PF_PID" 2>/dev/null || break
        sleep 0.5
    done
    echo "!! port-forward vers svc/$PG_SERVICE impossible"; exit 1
}
ensure_pf() {
    kill -0 "$PF_PID" 2>/dev/null && port_open && return 0
    kill "$PF_PID" 2>/dev/null || true
    start_pf
}
cleanup() { kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT
start_pf

run_psql() {
    ensure_pf
    docker run --rm -i --network host -e PGPASSWORD="$DB_PWD" postgres:18 \
        psql -q -h 127.0.0.1 -p "$LOCAL_PORT" -U status -d status "$@"
}

echo ">> Réinitialisation du schéma public..."
run_psql -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'

echo ">> Restauration du dump..."
ensure_pf
docker run --rm -i --network host -e PGPASSWORD="$DB_PWD" postgres:18 \
    pg_restore --no-owner --role=status -h 127.0.0.1 -p "$LOCAL_PORT" -U status -d status < "$DUMP_FILE"

echo ">> Patch schéma failed_jobs (migration Cachet 2015 incomplète pour Laravel 5.5)..."
run_psql -c 'ALTER TABLE failed_jobs ADD COLUMN IF NOT EXISTS exception text;'
run_psql -c 'ALTER TABLE failed_jobs ALTER COLUMN failed_at SET DEFAULT CURRENT_TIMESTAMP;'

echo ">> Compteurs après restauration :"
run_psql -c \
    "SELECT 'jobs (attendu: 0)' AS table, count(*) FROM jobs
     UNION ALL SELECT 'failed_jobs (attendu: 0)', count(*) FROM failed_jobs
     UNION ALL SELECT 'sessions (attendu: 0)', count(*) FROM sessions
     UNION ALL SELECT 'subscribers (CONSERVÉS, ~556)', count(*) FROM subscribers
     UNION ALL SELECT 'subscriptions (CONSERVÉES)', count(*) FROM subscriptions
     UNION ALL SELECT 'components', count(*) FROM components
     UNION ALL SELECT 'incidents', count(*) FROM incidents
     UNION ALL SELECT 'users', count(*) FROM users;"

JOBS=$(run_psql -tA -c 'SELECT count(*) FROM jobs;')
[ "$JOBS" = "0" ] || { echo "!! ECHEC garde-fou : $JOBS jobs en base, le worker les enverrait — NE PAS BASCULER"; exit 1; }
SUBS=$(run_psql -tA -c 'SELECT count(*) FROM subscribers;')
[ "$SUBS" != "0" ] || { echo "!! ATTENTION : 0 abonné restauré — dump suspect, vérifier avant de basculer"; exit 1; }

echo ">> Restauration production terminée ($SUBS abonnés conservés, 0 job)."
echo ">> Suite : kubectl rollout restart deployment/status-web-app deployment/status-worker -n status"
echo ">>         puis smoke tests via /etc/hosts AVANT la bascule DNS."
