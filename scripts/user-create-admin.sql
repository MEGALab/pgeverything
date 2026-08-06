-- Elevate a freshly-created schema role to per-DATABASE admin. Piped by database-create
-- (USER_ADMIN=1):  psql -d <db> -v uuid=<role> -v schema=<schema> -v db=<db> -f -
-- The role becomes the database owner + can create objects, but is still NOSUPERUSER /
-- NOCREATEROLE — its power is scoped to this database, not the cluster.
ALTER DATABASE :"db" OWNER TO :"uuid";
GRANT CREATE ON DATABASE :"db" TO :"uuid";
GRANT ALL ON SCHEMA :"schema" TO :"uuid";
