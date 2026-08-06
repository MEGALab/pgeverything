-- pgvault 0.1.0 — encrypted secrets manager for PGEverything.
-- Secrets are encrypted with pgsodium authenticated encryption (AEAD); the key is referenced
-- by a UUID whose raw material is derived from the server root key (kept OUTSIDE the DB), so a
-- dump contains only ciphertext + key ids. App-level RBAC: admins manage "secrets users";
-- read/write/both users manage secrets. A global kill switch (red_alert) can lock the vault.
-- Passwords for vault users are bcrypt-hashed with pgcrypto.
\echo Use "CREATE EXTENSION pgvault" to load this file. \quit

CREATE SCHEMA IF NOT EXISTS vault;

-- ---------------------------------------------------------------------------
-- Tables (config-dumped so real data survives pg_dump).
-- ---------------------------------------------------------------------------
-- The pgsodium key UUID for this vault. Populated by `make secrets-init`.
CREATE TABLE vault.config (
    id     boolean PRIMARY KEY DEFAULT true CHECK (id),   -- exactly one row
    key_id uuid NOT NULL
);
REVOKE ALL ON vault.config FROM PUBLIC;
SELECT pg_catalog.pg_extension_config_dump('vault.config', '');

-- Global kill switch. When active=false, all secret + user ops are refused.
CREATE TABLE vault.state (
    id     boolean PRIMARY KEY DEFAULT true CHECK (id),
    active boolean NOT NULL DEFAULT true
);
INSERT INTO vault.state (id, active) VALUES (true, true) ON CONFLICT DO NOTHING;
SELECT pg_catalog.pg_extension_config_dump('vault.state', '');

-- Vault users (application-level principals, NOT Postgres roles).
CREATE TABLE vault.users (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username   text UNIQUE NOT NULL,
    pass_hash  text NOT NULL,
    perm       text CHECK (perm IN ('read', 'write', 'both')),  -- NULL for admins
    is_admin   boolean NOT NULL DEFAULT false,
    active     boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON vault.users FROM PUBLIC;
SELECT pg_catalog.pg_extension_config_dump('vault.users', '');

-- Encrypted secrets. secret_enc is pgsodium AEAD ciphertext; name is the associated data.
CREATE TABLE vault.secrets (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text UNIQUE,
    description text,
    secret_enc  bytea NOT NULL,
    key_id      uuid NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON vault.secrets FROM PUBLIC;
SELECT pg_catalog.pg_extension_config_dump('vault.secrets', '');

-- ---------------------------------------------------------------------------
-- Internal helpers (SECURITY DEFINER, locked away from PUBLIC).
-- ---------------------------------------------------------------------------
CREATE FUNCTION vault._key_id() RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, pg_temp AS $$
DECLARE k uuid;
BEGIN
    SELECT key_id INTO k FROM vault.config WHERE id;
    IF k IS NULL THEN
        RAISE EXCEPTION 'vault is not initialized — run: make secrets-init';
    END IF;
    RETURN k;
END $$;
REVOKE ALL ON FUNCTION vault._key_id() FROM PUBLIC;

CREATE FUNCTION vault.hash_password(pw text) RETURNS text
LANGUAGE sql AS $$ SELECT crypt(pw, gen_salt('bf', 10)); $$;

-- Authenticate a vault user by username+password. Verifies the bcrypt hash and that the
-- account is active. Does NOT consider the kill switch (so admins can still recover).
CREATE FUNCTION vault._auth(p_user text, p_pass text) RETURNS vault.users
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE u vault.users;
BEGIN
    SELECT * INTO u FROM vault.users WHERE username = p_user;
    IF NOT FOUND OR NOT u.active OR u.pass_hash <> crypt(p_pass, u.pass_hash) THEN
        RAISE EXCEPTION 'vault: invalid credentials or inactive user';
    END IF;
    RETURN u;
END $$;
REVOKE ALL ON FUNCTION vault._auth(text, text) FROM PUBLIC;

CREATE FUNCTION vault._require_active() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, pg_temp AS $$
BEGIN
    IF NOT (SELECT active FROM vault.state WHERE id) THEN
        RAISE EXCEPTION 'vault is locked (red alert) — an admin must run: make secret-stand-down';
    END IF;
END $$;
REVOKE ALL ON FUNCTION vault._require_active() FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Secret operations. Authenticate a user, enforce the kill switch + permission.
-- Admins have perm=NULL, so the perm checks below reject them (they cannot touch secrets).
-- ---------------------------------------------------------------------------
CREATE FUNCTION vault.create_secret(p_user text, p_pass text, p_secret text,
                                    p_name text DEFAULT NULL, p_description text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE u vault.users; kid uuid; new_id uuid;
BEGIN
    u := vault._auth(p_user, p_pass);
    PERFORM vault._require_active();
    IF coalesce(u.perm, '') NOT IN ('write', 'both') THEN
        RAISE EXCEPTION 'vault: user % lacks write permission', p_user;
    END IF;
    kid := vault._key_id();
    INSERT INTO vault.secrets (name, description, secret_enc, key_id)
    VALUES (p_name, p_description,
            pgsodium.crypto_aead_det_encrypt(convert_to(p_secret, 'utf8'),
                                             convert_to(coalesce(p_name, ''), 'utf8'), kid),
            kid)
    RETURNING id INTO new_id;
    RETURN new_id;
END $$;

CREATE FUNCTION vault.update_secret(p_user text, p_pass text, p_id uuid, p_secret text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE u vault.users; s vault.secrets; n int;
BEGIN
    u := vault._auth(p_user, p_pass);
    PERFORM vault._require_active();
    IF coalesce(u.perm, '') NOT IN ('write', 'both') THEN
        RAISE EXCEPTION 'vault: user % lacks write permission', p_user;
    END IF;
    SELECT * INTO s FROM vault.secrets WHERE id = p_id;
    IF NOT FOUND THEN RETURN false; END IF;
    UPDATE vault.secrets
       SET secret_enc = pgsodium.crypto_aead_det_encrypt(
               convert_to(p_secret, 'utf8'), convert_to(coalesce(s.name, ''), 'utf8'), s.key_id),
           updated_at = now()
     WHERE id = p_id;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n > 0;
END $$;

CREATE FUNCTION vault.delete_secret(p_user text, p_pass text, p_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE u vault.users; n int;
BEGIN
    u := vault._auth(p_user, p_pass);
    PERFORM vault._require_active();
    IF coalesce(u.perm, '') NOT IN ('write', 'both') THEN
        RAISE EXCEPTION 'vault: user % lacks write permission', p_user;
    END IF;
    DELETE FROM vault.secrets WHERE id = p_id;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n > 0;
END $$;

CREATE FUNCTION vault.reveal_secret(p_user text, p_pass text, p_id uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE u vault.users; s vault.secrets;
BEGIN
    u := vault._auth(p_user, p_pass);
    PERFORM vault._require_active();
    IF coalesce(u.perm, '') NOT IN ('read', 'both') THEN
        RAISE EXCEPTION 'vault: user % lacks read permission', p_user;
    END IF;
    SELECT * INTO s FROM vault.secrets WHERE id = p_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    RETURN convert_from(
        pgsodium.crypto_aead_det_decrypt(s.secret_enc,
                                         convert_to(coalesce(s.name, ''), 'utf8'), s.key_id),
        'utf8');
END $$;

-- Metadata only — never returns plaintext.
CREATE FUNCTION vault.list_secrets(p_user text, p_pass text)
RETURNS TABLE (id uuid, name text, description text, created_at timestamptz, updated_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE u vault.users;
BEGIN
    u := vault._auth(p_user, p_pass);
    PERFORM vault._require_active();
    IF coalesce(u.perm, '') NOT IN ('read', 'both') THEN
        RAISE EXCEPTION 'vault: user % lacks read permission', p_user;
    END IF;
    RETURN QUERY SELECT s.id, s.name, s.description, s.created_at, s.updated_at
                 FROM vault.secrets s ORDER BY s.created_at;
END $$;

-- ---------------------------------------------------------------------------
-- User management (admin only).
-- ---------------------------------------------------------------------------
CREATE FUNCTION vault.create_user(p_admin text, p_admin_pass text, p_perm text)
RETURNS TABLE (username text, password text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE a vault.users; gen_user text; gen_pass text;
BEGIN
    a := vault._auth(p_admin, p_admin_pass);
    PERFORM vault._require_active();
    IF NOT a.is_admin THEN RAISE EXCEPTION 'vault: only an admin may manage users'; END IF;
    IF p_perm NOT IN ('read', 'write', 'both') THEN
        RAISE EXCEPTION 'vault: perm must be read, write, or both';
    END IF;
    gen_user := 'vu_' || substr(md5(gen_random_uuid()::text), 1, 10);
    gen_pass := encode(gen_random_bytes(18), 'base64');
    INSERT INTO vault.users (username, pass_hash, perm, is_admin)
    VALUES (gen_user, vault.hash_password(gen_pass), p_perm, false);
    username := gen_user; password := gen_pass;
    RETURN NEXT;
END $$;

CREATE FUNCTION vault.deactivate_user(p_admin text, p_admin_pass text, p_username text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE a vault.users; n int;
BEGIN
    a := vault._auth(p_admin, p_admin_pass);
    PERFORM vault._require_active();
    IF NOT a.is_admin THEN RAISE EXCEPTION 'vault: only an admin may manage users'; END IF;
    UPDATE vault.users SET active = false WHERE username = p_username AND NOT is_admin;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n > 0;
END $$;

-- Self-service password change (any user changes their own).
CREATE FUNCTION vault.change_password(p_username text, p_current text, p_new text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE u vault.users;
BEGIN
    u := vault._auth(p_username, p_current);
    PERFORM vault._require_active();
    UPDATE vault.users SET pass_hash = vault.hash_password(p_new) WHERE id = u.id;
    RETURN true;
END $$;

-- Bootstrap the first admin. Locked to PUBLIC — called by `make secrets-init` as superuser.
CREATE FUNCTION vault._create_admin(p_username text, p_password text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE new_id uuid;
BEGIN
    INSERT INTO vault.users (username, pass_hash, perm, is_admin)
    VALUES (p_username, vault.hash_password(p_password), NULL, true)
    RETURNING id INTO new_id;
    RETURN new_id;
END $$;
REVOKE ALL ON FUNCTION vault._create_admin(text, text) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Kill switch (admin only; deliberately NOT gated by _require_active so recovery works).
-- ---------------------------------------------------------------------------
CREATE FUNCTION vault.red_alert(p_admin text, p_admin_pass text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE a vault.users;
BEGIN
    a := vault._auth(p_admin, p_admin_pass);
    IF NOT a.is_admin THEN RAISE EXCEPTION 'vault: only an admin may trigger red alert'; END IF;
    UPDATE vault.state SET active = false WHERE id;
    RETURN true;
END $$;

CREATE FUNCTION vault.stand_down(p_admin text, p_admin_pass text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = vault, public, pg_temp AS $$
DECLARE a vault.users;
BEGIN
    a := vault._auth(p_admin, p_admin_pass);
    IF NOT a.is_admin THEN RAISE EXCEPTION 'vault: only an admin may stand down'; END IF;
    UPDATE vault.state SET active = true WHERE id;
    RETURN true;
END $$;

-- ---------------------------------------------------------------------------
-- Public-callable surface (each function self-authenticates). Internal _-fns + tables
-- stay REVOKE'd from PUBLIC above.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA vault TO PUBLIC;
GRANT EXECUTE ON FUNCTION
    vault.create_secret(text, text, text, text, text),
    vault.update_secret(text, text, uuid, text),
    vault.delete_secret(text, text, uuid),
    vault.reveal_secret(text, text, uuid),
    vault.list_secrets(text, text),
    vault.create_user(text, text, text),
    vault.deactivate_user(text, text, text),
    vault.change_password(text, text, text),
    vault.red_alert(text, text),
    vault.stand_down(text, text)
TO PUBLIC;
