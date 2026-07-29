-- pgauth 0.1.0 — JWT-based per-user auth + Row-Level-Security helpers for PGEverything.
-- Passwords are bcrypt-hashed with pgcrypto; sessions are signed/verified JWTs (pgjwt).
-- The HMAC signing secret lives in a protected table that only SECURITY DEFINER functions
-- can read, so an application role can never read it and forge tokens.
\echo Use "CREATE EXTENSION pgauth" to load this file. \quit

CREATE SCHEMA IF NOT EXISTS auth;

-- ---------------------------------------------------------------------------
-- Tables. Marked as extension config tables so pg_dump preserves their DATA
-- (these hold real user/secret data, not extension boilerplate).
-- ---------------------------------------------------------------------------
CREATE TABLE auth.users (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email      text UNIQUE NOT NULL,
    pass_hash  text NOT NULL,
    role       text NOT NULL DEFAULT 'app_user',
    created_at timestamptz NOT NULL DEFAULT now()
);
SELECT pg_catalog.pg_extension_config_dump('auth.users', '');

-- Single-row table holding the JWT signing secret. Locked down: only the owner
-- (i.e. SECURITY DEFINER functions) may read it.
CREATE TABLE auth.secret (
    id    boolean PRIMARY KEY DEFAULT true CHECK (id),   -- enforces exactly one row
    value text NOT NULL
);
REVOKE ALL ON auth.secret FROM PUBLIC;
SELECT pg_catalog.pg_extension_config_dump('auth.secret', '');

-- ---------------------------------------------------------------------------
-- Internal: read the signing secret. SECURITY DEFINER so callers need no direct
-- access to auth.secret; not granted to PUBLIC.
-- ---------------------------------------------------------------------------
CREATE FUNCTION auth._secret() RETURNS text
LANGUAGE sql SECURITY DEFINER SET search_path = auth, pg_temp AS $$
    SELECT value FROM auth.secret WHERE id;
$$;
REVOKE ALL ON FUNCTION auth._secret() FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Password hashing (bcrypt, cost 10).
-- ---------------------------------------------------------------------------
CREATE FUNCTION auth.hash_password(pw text) RETURNS text
LANGUAGE sql AS $$
    SELECT crypt(pw, gen_salt('bf', 10));
$$;

-- ---------------------------------------------------------------------------
-- Register a user; returns the new id. SECURITY DEFINER so app roles need no
-- direct write access to auth.users.
-- ---------------------------------------------------------------------------
CREATE FUNCTION auth.register(p_email text, p_password text, p_role text DEFAULT 'app_user')
RETURNS uuid
LANGUAGE sql SECURITY DEFINER SET search_path = auth, public, pg_temp AS $$
    INSERT INTO auth.users (email, pass_hash, role)
    VALUES (lower(p_email), auth.hash_password(p_password), p_role)
    RETURNING id;
$$;

-- ---------------------------------------------------------------------------
-- Log in: verify the bcrypt hash and return a signed JWT (1h expiry), or NULL
-- on bad credentials.
-- ---------------------------------------------------------------------------
CREATE FUNCTION auth.login(p_email text, p_password text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = auth, public, pg_temp AS $$
DECLARE u auth.users;
BEGIN
    SELECT * INTO u FROM auth.users WHERE email = lower(p_email);
    IF NOT FOUND OR u.pass_hash <> crypt(p_password, u.pass_hash) THEN
        RETURN NULL;   -- invalid email or password
    END IF;
    RETURN sign(
        json_build_object(
            'user_id', u.id,
            'role',    u.role,
            'exp',     (extract(epoch FROM now())::int + 3600)   -- 1 hour
        ),
        auth._secret()
    );
END $$;

-- ---------------------------------------------------------------------------
-- Validate a JWT and load its claims into the session (transaction-local) so
-- RLS policies can read them via auth.uid()/auth.role(). Returns true if valid.
-- ---------------------------------------------------------------------------
CREATE FUNCTION auth.authenticate(token text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = auth, public, pg_temp AS $$
DECLARE v record;
BEGIN
    SELECT * INTO v FROM verify(token, auth._secret());
    IF NOT FOUND OR v.valid IS NOT TRUE
       OR (v.payload->>'exp')::int < extract(epoch FROM now())::int THEN
        PERFORM set_config('auth.claims', '', true);
        RETURN false;
    END IF;
    PERFORM set_config('auth.claims', v.payload::text, true);   -- lasts this transaction
    RETURN true;
END $$;

-- ---------------------------------------------------------------------------
-- Session accessors for use in RLS policies. NULL when unauthenticated.
-- ---------------------------------------------------------------------------
CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT (nullif(current_setting('auth.claims', true), '')::json ->> 'user_id')::uuid;
$$;

CREATE FUNCTION auth.role() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('auth.claims', true), '')::json ->> 'role';
$$;

-- Safe, pre-auth-callable surface. The secret accessor and tables stay locked down.
GRANT USAGE ON SCHEMA auth TO PUBLIC;
GRANT EXECUTE ON FUNCTION
    auth.register(text, text, text),
    auth.login(text, text),
    auth.authenticate(text),
    auth.uid(),
    auth.role(),
    auth.hash_password(text)
TO PUBLIC;
