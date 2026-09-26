#!/usr/bin/env bash
# Dispatcher for the schema-scoped user CRUD `make user-*` commands. Users are real Postgres
# login roles (name = UUID, password = a 12-word EFF-diceware passphrase), scoped to one
# schema and tracked in the per-DB pgusers.schema_users registry.
#
# Every subcommand prompts for the target DATABASE (roles are cluster-global, but the schema
# grants + registry are per-DB). `create` also prompts for the schema. Feature 3
# (tenant-create) pre-fills USER_DB / USER_SCHEMA / USER_ADMIN to skip prompts.
set -euo pipefail
cd "$(dirname "$0")/.."

SVC=pgeverything
DEFAULT_DB="${DB:-pgeverything}"
WORDLIST=/usr/share/pgeverything/eff_large_wordlist.txt

ask() {  # ask VAR "Question" [default]
  local var="$1" q="$2" def="${3:-}" ans
  read -r -p "$q${def:+ [$def]}: " ans
  printf -v "$var" '%s' "${ans:-$def}"
}

# The target database: prefilled via USER_DB (feature 3) or prompted.
db="${USER_DB:-}"
[ -n "$db" ] || ask db "Target database" "$DEFAULT_DB"

dsql() { docker compose exec -T "$SVC" psql -v ON_ERROR_STOP=1 -U postgres -d "$db" "$@"; }
scalar() { docker compose exec -T "$SVC" psql -tA -U postgres -d "$db" -c "$1" | tr -d '[:space:]'; }
gen_passphrase() {
  docker compose exec -T "$SVC" sh -c "shuf -n 12 $WORDLIST | paste -sd- -" | tr -d '\r\n'
}
ensure_registry() { dsql -f - < scripts/users-bootstrap.sql >/dev/null; }

case "${1:-}" in
  create)
    ensure_registry
    schema="${USER_SCHEMA:-}"; [ -n "$schema" ] || ask schema "Schema for the new user" "public"
    uuid="$(scalar 'SELECT gen_random_uuid();')"
    pass="$(gen_passphrase)"
    [ -n "$uuid" ] && [ -n "$pass" ] || { echo "failed to generate user id / passphrase" >&2; exit 1; }
    dsql -v uuid="$uuid" -v pass="$pass" -v schema="$schema" -f - < scripts/user-create.sql
    if [ "${USER_ADMIN:-0}" = "1" ]; then
      dsql -v uuid="$uuid" -v schema="$schema" -v db="$db" -f - < scripts/user-create-admin.sql
      note="admin — owns database '$db'"
    else
      note="schema user — '$schema'"
    fi
    echo "database:   $db"
    echo "schema:     $schema"
    echo "user_id:    $uuid  ($note)"
    echo "passphrase: $pass"
    echo "Save the passphrase now — it is shown only once."
    ;;

  read)
    ensure_registry
    ask uuid "User id (UUID)"
    dsql -v uuid="$uuid" -x -f - < scripts/user-read.sql
    ;;

  update-password)
    ask uuid "User id (UUID)"
    read -r -s -p "New password: " pass; echo
    [ -n "$pass" ] || { echo "password required" >&2; exit 1; }
    dsql -v uuid="$uuid" -v pass="$pass" -f - < scripts/user-update-password.sql
    echo "Password updated for $uuid."
    ;;

  deactivate)
    ensure_registry
    ask uuid "User id (UUID)"
    pass="$(gen_passphrase)"   # random + undisclosed → lockout
    dsql -v uuid="$uuid" -v pass="$pass" -f - < scripts/user-deactivate.sql
    echo "User $uuid deactivated (password reset to an undisclosed passphrase; account + data kept)."
    ;;

  delete)
    ensure_registry
    ask uuid "User id (UUID)"
    read -r -p "This DROPS all objects owned by $uuid in database '$db' and removes the role. Type YES: " c
    [ "$c" = "YES" ] || { echo "aborted."; exit 1; }
    dsql -v uuid="$uuid" -f - < scripts/user-delete.sql
    echo "User $uuid deleted from database '$db' (objects + role removed)."
    ;;

  *)
    echo "usage: users.sh {create|read|update-password|deactivate|delete}" >&2
    exit 1
    ;;
esac
