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
CREATE EXTENSION IF NOT EXISTS pgcrypto;         -- hashing / UUIDs
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

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
