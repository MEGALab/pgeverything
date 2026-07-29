-- create-db.sql — provision an ISOLATED tenant database and its owner role.
-- Piped in by `make create-db`:
--   psql ... -v user=<role> -v pass=<pw> -v db=<newdb> -v maindb=<primary db> -f -
-- psql interpolates :"ident" as a quoted identifier and :'literal' as an escaped
-- string, so names/passwords with odd characters are handled safely. (Note: this
-- interpolation only happens for SQL read from a file/stdin, NOT for psql -c strings.)

-- Tenant role: may log in and owns exactly one database, but holds NO cluster-wide
-- power. It must NOT be a SUPERUSER — a superuser bypasses every CONNECT and RLS
-- check and can read/write all databases, which is the leak this fixes. No CREATEDB
-- or CREATEROLE either, so it cannot provision its way out.
CREATE ROLE :"user" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'pass';
CREATE DATABASE :"db" OWNER :"user";

-- Lock the new database to its owner. Postgres grants CONNECT to PUBLIC by default,
-- so without this any other (current or future) tenant role could connect here.
-- The owner still connects — an object owner implicitly holds all privileges on it.
REVOKE CONNECT ON DATABASE :"db" FROM PUBLIC;

-- Keep tenant roles OUT of the shared databases. These also default to PUBLIC
-- CONNECT — exactly how the new role could otherwise reach the other databases.
-- Superusers bypass CONNECT, so admin/tooling access is unaffected. Re-grant the
-- app role on the primary DB so the pgauth / app_user flow keeps working.
REVOKE CONNECT ON DATABASE :"maindb"  FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres   FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1  FROM PUBLIC;
GRANT  CONNECT ON DATABASE :"maindb"  TO app_user;
