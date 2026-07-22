-- PGEverything — enable all bundled extensions on first boot.
-- Runs once, in POSTGRES_DB, via the postgres docker-entrypoint init phase.

CREATE EXTENSION IF NOT EXISTS timescaledb;      -- time-series
CREATE EXTENSION IF NOT EXISTS vector;           -- pgvector (vectors)
CREATE EXTENSION IF NOT EXISTS vectorscale;      -- pgvectorscale (fast ANN)
CREATE EXTENSION IF NOT EXISTS age;              -- graph (openCypher)
CREATE EXTENSION IF NOT EXISTS pgmq;             -- durable pub/sub queues
CREATE EXTENSION IF NOT EXISTS pg_cron;          -- scheduled SQL
CREATE EXTENSION IF NOT EXISTS pg_trgm;          -- fuzzy text search
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;         -- hashing / UUIDs
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- AGE needs its catalog on the search_path to be usable.
LOAD 'age';
ALTER DATABASE :"POSTGRES_DB" SET search_path = ag_catalog, "$user", public;
