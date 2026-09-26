#!/usr/bin/env bash
# make tenant-create — create a new database, then bootstrap its ADMIN user by reusing the
# schema-user create flow (USER_ADMIN=1). The admin is a real role (UUID + 12-word passphrase)
# that OWNS the new database. Distinct from `make database-create` (isolated tenant + fixed-password
# owner). Run on the host; talks to the running container.
set -euo pipefail
cd "$(dirname "$0")/.."

SVC=pgeverything

read -r -p "New database name: " newdb
[ -n "$newdb" ] || { echo "database name required" >&2; exit 1; }

# Create the database (errors clearly if it already exists).
docker compose exec -T "$SVC" psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -v db="$newdb" -f - <<'SQL'
CREATE DATABASE :"db";
SQL

echo "Database '$newdb' created. Bootstrapping its admin user ..."

# Reuse the exact user-create path, pre-filled + elevated to DB admin.
USER_DB="$newdb" USER_SCHEMA=public USER_ADMIN=1 bash scripts/users.sh create
