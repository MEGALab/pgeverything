-- Update a schema user's password. -v uuid=<role> -v pass=<new password>
ALTER ROLE :"uuid" WITH PASSWORD :'pass';
