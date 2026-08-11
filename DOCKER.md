# Cachet en Docker (local + image de déploiement)

L'image (`Dockerfile`) est celle déployée sur Kubernetes : PHP 7.3 + Apache sur le
port 8080, config **entièrement par variables d'environnement** (aucun fichier
`.env` dans l'image).

⚠️ Règles propres à ce fork :
- **Jamais** de `php artisan config:cache` : la vérification reCAPTCHA lit
  `env('GOOGLE_CAPTCHA_SECRET')` à l'exécution.
- **Jamais** définir `APP_NAME` : la sitekey reCAPTCHA transite par
  `config('app.name')` (`config/app.php`).
- `APP_DEBUG=true` est impossible sur cette image (le provider Debugbar est un
  paquet dev, exclu du build `--no-dev`).

## Stack locale

```bash
cp .env.example .env   # config docker compose — puis compléter (repo public : le .env reste local)
docker compose up -d --build
# UI :      http://localhost:8091
# MailHog : http://localhost:8026   (surchargeable via MAILHOG_UI_PORT dans .env)
```

Les scripts de migration (`scripts/`) ont leur propre configuration, séparée
du docker-compose : `cp scripts/.env.example scripts/.env` puis compléter.

Services : `app` (web), `worker` (`php artisan queue:work`, traite les mails de
notification), `db` (PostgreSQL 18, aligné sur le cluster CNPG), `mailhog`
(capture tous les mails sortants).

### Base vierge

```bash
docker compose exec app php artisan migrate --force
# puis http://localhost:8091 → assistant de setup
```

### Répétition de migration : importer la base de prod

```bash
# Prérequis : STATUS_PROD_SSH dans scripts/.env (dump) et APP_KEY dans .env (back-office sur données de prod)
docker compose up -d
scripts/import-prod-db.sh        # dump SSH direct (lecture seule) ou : scripts/import-prod-db.sh fichier.dump
docker compose restart app worker
```

Le script restaure le dump puis **assainit** la base : `TRUNCATE jobs,
failed_jobs, sessions` (la prod traîne 26k+ jobs jamais traités — un worker les
enverrait tous) et invalide le cache de settings (`bootstrap/cachet/`).

### Restore vers la préproduction kube

`scripts/restore-preprod-db.sh` : même principe vers le CNPG preprod (via
`kubectl port-forward`), avec en plus la **purge systématique des abonnés**
(`subscribers` + `subscriptions`) — aucun mail ne doit jamais partir vers un
vrai abonné depuis la preprod. Le script refuse de tourner sur un contexte
kubectl de production ; la bascule prod suit une procédure dédiée qui conserve
les abonnés.

### Points de vérification

- `curl localhost:8091/api/v1/ping` → `{"data":"Pong!"}` (probe utilisée par Kubernetes)
- page publique avec le branding Apidae, `<title>Apidae Status</title>`
- inscription abonné sur `/subscribe` (clés reCAPTCHA de test Google par défaut :
  la vérification passe toujours) → mails visibles dans MailHog
