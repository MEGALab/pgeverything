-- Create a schema-scoped Postgres login role. Piped by scripts/users.sh create:
--   psql ... -v uuid=<role> -v pass=<passphrase> -v schema=<schema> -f -
-- The role is scoped: it may use the one schema and CRUD its tables, nothing cluster-wide.

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = :'schema') THEN
    RAISE EXCEPTION 'schema % does not exist in this database', :'schema';
  END IF;
END $$;

CREATE ROLE :"uuid" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'pass';

GRANT USAGE ON SCHEMA :"schema" TO :"uuid";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"schema" TO :"uuid";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"schema" TO :"uuid";
ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema"
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"uuid";
ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema"
  GRANT USAGE, SELECT ON SEQUENCES TO :"uuid";

INSERT INTO pgusers.schema_users (user_id, schema_name) VALUES (:'uuid', :'schema');
