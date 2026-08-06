-- Deactivate a schema user WITHOUT deleting the account or its data: reset the password to
-- a fresh, undisclosed passphrase (so it can't log in) and flag it inactive in the registry.
-- -v uuid=<role> -v pass=<random undisclosed passphrase>
ALTER ROLE :"uuid" WITH PASSWORD :'pass';
UPDATE pgusers.schema_users
   SET active = false, deactivated_at = now()
 WHERE user_id = :'uuid'::uuid;
