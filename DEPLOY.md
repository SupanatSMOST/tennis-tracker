# Deploy — Backend (VPS + Docker Compose)

Backend = Go API + PostgreSQL, deployed to your own host via Docker Compose.
Schema migrations run automatically as a release step (`goose`) before the app starts.

## Prerequisites (on the host)
- Docker + the Docker Compose plugin
- This repo cloned/pulled on the host

## First deploy
1. Create the env file and fill in **real** secrets:
   ```
   cp .env.example .env
   # edit .env:
   #   POSTGRES_PASSWORD : a strong random password
   #   JWT_SIGNING_KEY   : openssl rand -base64 48
   #   DATABASE_URL      : keep user/password/db in sync with POSTGRES_*
   ```
2. Build, migrate, and start:
   ```
   docker compose up -d --build
   ```
   Boot order is enforced: **db (healthy) → migrate (`goose up`, runs to completion) → app**.
3. Verify:
   ```
   curl http://localhost:${APP_PORT:-8080}/health          # -> {"status":"ok"}
   # smoke-test auth (auto-login returns a token):
   curl -sX POST localhost:8080/auth/signup \
     -H 'content-type: application/json' \
     -d '{"username":"demo","password":"demopass123"}'
   ```

## Updating to a new version
```
git pull
docker compose up -d --build
```
`migrate` re-runs on every deploy; `goose` is idempotent and applies only new migrations.

## Exposing publicly (TLS)
The app serves plain HTTP on port 8080. Put it behind your existing reverse proxy
(nginx/Caddy) that terminates TLS and forwards to `127.0.0.1:${APP_PORT}`.
**Do not** expose Postgres — the compose file deliberately does not publish its port.

## Operations
- Logs: `docker compose logs -f app` (structured JSON via `slog`)
- Migrate-only re-run: `docker compose run --rm migrate`
- Secrets live only in `.env` on the host (gitignored); nothing secret is committed.
- JWTs are non-expiring by design — rotating `JWT_SIGNING_KEY` invalidates all tokens.
