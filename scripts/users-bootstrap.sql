-- Registry of schema-scoped users for the current database. Postgres roles are
-- cluster-global, so this table records which schema each managed user belongs to (and
-- whether it's active). Created idempotently by scripts/users.sh before any operation.
CREATE SCHEMA IF NOT EXISTS pgusers;
CREATE TABLE IF NOT EXISTS pgusers.schema_users (
    user_id        uuid PRIMARY KEY,          -- also the Postgres role name
    schema_name    text NOT NULL,
    active         boolean NOT NULL DEFAULT true,
    created_at     timestamptz NOT NULL DEFAULT now(),
    deactivated_at timestamptz
);
