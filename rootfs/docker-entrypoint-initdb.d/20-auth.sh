#!/usr/bin/env bash
# PGEverything — seed the pgauth JWT signing secret (and optionally enable the
# app_user login) from environment, without exposing the secret in postgresql.conf
# or the process command line. psql :'var' quoting prevents SQL injection.
set -euo pipefail

SECRET="${PGE_JWT_SECRET:-CHANGE-ME-INSECURE-DEV-SECRET}"
APP_PW="${PGE_APP_USER_PASSWORD:-}"

if [ "$SECRET" = "CHANGE-ME-INSECURE-DEV-SECRET" ]; then
  echo "WARNING: PGE_JWT_SECRET is unset — using an INSECURE default. Set PGE_JWT_SECRET in production."
fi

psql -v ON_ERROR_STOP=1 -v secret="$SECRET" \
     --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<'SQL'
  INSERT INTO auth.secret (id, value) VALUES (true, :'secret')
    ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value;
SQL

# Enable direct logins as app_user only when a password is supplied. Otherwise the
# role stays NOLOGIN (still usable for RLS via SET ROLE from a superuser session).
if [ -n "$APP_PW" ]; then
  echo "Enabling app_user login (PGE_APP_USER_PASSWORD provided)."
  psql -v ON_ERROR_STOP=1 -v pw="$APP_PW" \
       --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
       -c "ALTER ROLE app_user LOGIN PASSWORD :'pw';"
fi
