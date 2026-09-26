#!/usr/bin/env bash
# make database-create — grant an EXISTING login role access to a database + schema, creating
# the database and/or schema if they do not exist. It NEVER creates the user or changes a
# password: DB_USER must already exist and DB_PASSWORD must be its current password.
#
#   make database-create DB_NAME=<db> SCHEMA_NAME=<schema> DB_USER=<user> DB_PASSWORD=<pw>
#     DB_NAME      database to use   — created if it does not exist
#     SCHEMA_NAME  schema to use     — created if it does not exist
#     DB_USER      login role        — MUST already exist (grant only, never created)
#     DB_PASSWORD  DB_USER's password — verified by a login attempt, never set/changed
#
# To create a brand-new database WITH a freshly generated admin user, use `make tenant-create`.
set -euo pipefail
cd "$(dirname "$0")/.."

SVC=pgeverything
DB_NAME="${DB_NAME:-}"
SCHEMA_NAME="${SCHEMA_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"

usage() {
  echo "Usage: make database-create DB_NAME=<db> SCHEMA_NAME=<schema> DB_USER=<user> DB_PASSWORD=<pw>" >&2
  echo "  DB_NAME/SCHEMA_NAME are created if missing; DB_USER must already exist and DB_PASSWORD" >&2
  echo "  must be its current password. To create a new DB + a new admin user, use make tenant-create." >&2
  exit 1
}
[ -n "$DB_NAME" ] && [ -n "$SCHEMA_NAME" ] && [ -n "$DB_USER" ] && [ -n "$DB_PASSWORD" ] || usage

psqlp()  { docker compose exec -T "$SVC" psql -v ON_ERROR_STOP=1 -U postgres "$@"; }   # pick db via -d
scalar() { docker compose exec -T "$SVC" psql -tA -U postgres "$@" | tr -d '[:space:]'; }

# 1) DB_USER must already exist as a role that can log in — we grant to it, never create it.
canlogin="$(scalar -d postgres -v u="$DB_USER" -f - <<'SQL'
SELECT rolcanlogin FROM pg_roles WHERE rolname = :'u';
SQL
)"
[ -n "$canlogin" ] || { echo "error: role '$DB_USER' does not exist — create it first (make user-create) or use make tenant-create" >&2; exit 1; }
[ "$canlogin" = "t" ] || { echo "error: role '$DB_USER' exists but cannot log in (NOLOGIN)" >&2; exit 1; }

# 2) Verify DB_PASSWORD. Loopback (127.0.0.1) is 'trust' in pg_hba and would accept any password,
#    so probe over the container's own network name, which matches the scram-sha-256 host rule.
#    Postgres checks the password before any database-CONNECT privilege, so a wrong password fails
#    here regardless of grants; a right password either connects or is denied at the CONNECT stage.
autherr="$(docker compose exec -T -e PGPASSWORD="$DB_PASSWORD" "$SVC" \
             psql -tA -h "$SVC" -U "$DB_USER" -d postgres -c 'SELECT 1' 2>&1 >/dev/null || true)"
case "$autherr" in
  *"password authentication failed"*)
    echo "error: invalid password for DB_USER '$DB_USER'" >&2; exit 1 ;;
esac

# 3) Ensure the database exists. CREATE DATABASE can't be conditional or run in a transaction,
#    so branch in the shell.
created_db=0
if [ "$(scalar -d postgres -v db="$DB_NAME" -f - <<'SQL'
SELECT 1 FROM pg_database WHERE datname = :'db';
SQL
)" != "1" ]; then
  psqlp -d postgres -v db="$DB_NAME" -f - <<'SQL'
CREATE DATABASE :"db";
SQL
  created_db=1
  # Fresh DB: lock CONNECT to explicitly-granted roles only (Postgres grants it to PUBLIC by
  # default). Never re-lock a pre-existing/shared database.
  psqlp -d "$DB_NAME" -v db="$DB_NAME" -f - <<'SQL'
REVOKE CONNECT ON DATABASE :"db" FROM PUBLIC;
SQL
fi

# 4) Grant the existing user CONNECT on the DB, ensure the schema exists, and grant it on the
#    schema (new schema → owned by the user; existing schema → left as-is, just granted).
psqlp -d "$DB_NAME" -v db="$DB_NAME" -v u="$DB_USER" -v schema="$SCHEMA_NAME" -f - <<'SQL'
GRANT CONNECT ON DATABASE :"db" TO :"u";
CREATE SCHEMA IF NOT EXISTS :"schema" AUTHORIZATION :"u";
GRANT USAGE, CREATE ON SCHEMA :"schema" TO :"u";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"schema" TO :"u";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"schema" TO :"u";
ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"u";
ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema" GRANT USAGE, SELECT ON SEQUENCES TO :"u";
SQL

echo "database:   $DB_NAME  ($([ "$created_db" = 1 ] && echo 'created' || echo 'reused'))"
echo "schema:     $SCHEMA_NAME  (created if it did not exist)"
echo "user:       $DB_USER  (existing role — granted CONNECT + USAGE/CREATE + CRUD on the schema)"
echo "Success."
