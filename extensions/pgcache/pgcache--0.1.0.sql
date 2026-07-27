-- pgcache 0.1.0 — Redis-style key-value cache for PGEverything.
-- jsonb values, optional TTL, backed by an UNLOGGED table. Lazy expiry on read;
-- an active pg_cron sweep (scheduled outside the extension) evicts expired rows.
\echo Use "CREATE EXTENSION pgcache" to load this file. \quit

CREATE SCHEMA IF NOT EXISTS pgcache;

-- UNLOGGED: not WAL-logged, truncated on crash recovery — cache semantics, the
-- closest Postgres analog to Redis.
CREATE UNLOGGED TABLE pgcache.store (
    key        text PRIMARY KEY,
    value      jsonb NOT NULL,
    expires_at timestamptz            -- NULL = never expires
);
CREATE INDEX pgcache_store_expires_at ON pgcache.store (expires_at)
    WHERE expires_at IS NOT NULL;

-- Upsert a key with an optional TTL in seconds (NULL = never expires).
CREATE FUNCTION cache_set(p_key text, p_value jsonb, ttl integer DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO pgcache.store (key, value, expires_at)
    VALUES (p_key, p_value,
            CASE WHEN ttl IS NULL THEN NULL ELSE now() + make_interval(secs => ttl) END)
    ON CONFLICT (key) DO UPDATE
        SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at;
$$;

-- Return a key's value, or NULL if it is missing or expired (lazy expiry).
CREATE FUNCTION cache_get(p_key text)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT value FROM pgcache.store
    WHERE key = p_key AND (expires_at IS NULL OR expires_at > now());
$$;

-- Delete a key; returns true if it existed.
CREATE FUNCTION cache_del(p_key text)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    DELETE FROM pgcache.store WHERE key = p_key;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n > 0;
END $$;

-- Atomic counter. Stores the number as a jsonb scalar and clears any TTL.
CREATE FUNCTION cache_incr(p_key text, delta bigint DEFAULT 1)
RETURNS bigint LANGUAGE sql AS $$
    INSERT INTO pgcache.store (key, value)
    VALUES (p_key, to_jsonb(delta))
    ON CONFLICT (key) DO UPDATE
        SET value = to_jsonb((pgcache.store.value #>> '{}')::bigint + delta),
            expires_at = NULL
    RETURNING (value #>> '{}')::bigint;
$$;

-- Delete all expired rows; returns the count removed. Sweep target for pg_cron.
CREATE FUNCTION pgcache.purge_expired()
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    DELETE FROM pgcache.store WHERE expires_at IS NOT NULL AND expires_at <= now();
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;
