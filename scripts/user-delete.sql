-- Permanently remove a schema user and ALL objects it owns in this database. -v uuid=<role>
-- DROP OWNED BY covers every schema in the CURRENT database (a role owning objects in other
-- databases must be dropped there too before DROP ROLE succeeds cluster-wide).
DROP OWNED BY :"uuid" CASCADE;
DROP ROLE :"uuid";
DELETE FROM pgusers.schema_users WHERE user_id = :'uuid'::uuid;
