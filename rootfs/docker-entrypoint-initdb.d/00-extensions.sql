-- PGEverything — enable all bundled extensions on first boot.
-- Runs once, in POSTGRES_DB, via the postgres docker-entrypoint init phase.

CREATE EXTENSION IF NOT EXISTS timescaledb;      -- time-series
CREATE EXTENSION IF NOT EXISTS vector;           -- pgvector (vectors)
CREATE EXTENSION IF NOT EXISTS vectorscale;      -- pgvectorscale (fast ANN)
CREATE EXTENSION IF NOT EXISTS age;              -- graph (openCypher)
CREATE EXTENSION IF NOT EXISTS pgmq;             -- durable pub/sub queues
CREATE EXTENSION IF NOT EXISTS pg_cron;          -- scheduled SQL
CREATE EXTENSION IF NOT EXISTS pgcache;          -- Redis-style key-value cache
CREATE EXTENSION IF NOT EXISTS pg_trgm;          -- fuzzy text search
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;         -- hashing / UUIDs (also used by pgjwt/pgauth)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgjwt;            -- JWT sign/verify (requires pgcrypto)
CREATE EXTENSION IF NOT EXISTS pgauth;           -- JWT auth + RLS helpers (requires pgjwt)

-- Non-superuser application role. RLS only enforces for non-superusers, so apps must
-- connect (or SET ROLE) as this role; the secret table stays invisible to it.
-- Enable LOGIN + a password at first boot via PGE_APP_USER_PASSWORD (see 20-auth.sh).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user NOLOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA auth TO app_user;

-- AGE needs its catalog on the search_path to be usable. The docker-entrypoint runs
-- this file with --dbname but does NOT expose it as a psql variable, so derive the
-- current database name at runtime instead of interpolating one.
LOAD 'age';
DO $$ BEGIN
  EXECUTE format('ALTER DATABASE %I SET search_path = ag_catalog, "$user", public',
                 current_database());
END $$;

-- Actively evict expired cache entries once a minute (lazy expiry covers reads between runs).
SELECT cron.schedule('pgcache-sweep', '* * * * *', $$SELECT pgcache.purge_expired()$$);

-- Routine bloat control for the high-churn cache table. UNLOGGED skips WAL but not MVCC, so
-- constant upserts + per-minute purge DELETEs still leave dead tuples. pg_cron can't express
-- a 25-hour interval directly (intervals are seconds-only; cron is calendar-based; and VACUUM
-- can't be gated inside a function/transaction), so we drift a daily job's fire-hour +1 each
-- day — making consecutive runs land 25h apart and rotate around the clock.
CREATE OR REPLACE FUNCTION pgcache.drift_vacuum_hour() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE cur_sched text; cur_hour int; new_hour int;
BEGIN
  SELECT schedule INTO cur_sched FROM cron.job WHERE jobname = 'pgcache-vacuum';
  IF cur_sched IS NULL THEN RETURN; END IF;         -- vacuum job missing; nothing to drift
  cur_hour := split_part(cur_sched, ' ', 2)::int;   -- 2nd cron field = hour
  new_hour := (cur_hour + 1) % 24;
  PERFORM cron.schedule('pgcache-vacuum',
                        format('0 %s * * *', new_hour),
                        'VACUUM (ANALYZE) pgcache.store');
END $$;

-- Plain VACUUM (ANALYZE) on the cache table only — no blocking lock, unlike VACUUM FULL.
SELECT cron.schedule('pgcache-vacuum',       '0 4 * * *',  $$VACUUM (ANALYZE) pgcache.store$$);
-- Once-daily hour bump → true 25h spacing between vacuums.
SELECT cron.schedule('pgcache-vacuum-drift', '30 4 * * *', $$SELECT pgcache.drift_vacuum_hour()$$);
