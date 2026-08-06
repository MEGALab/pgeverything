-- Return a schema user's registry record + role login status. -v uuid=<role>
SELECT su.user_id,
       su.schema_name,
       su.active           AS registry_active,
       su.created_at,
       su.deactivated_at,
       r.rolcanlogin       AS can_login,
       r.rolvaliduntil     AS valid_until
FROM pgusers.schema_users su
LEFT JOIN pg_roles r ON r.rolname = su.user_id::text
WHERE su.user_id = :'uuid'::uuid;
