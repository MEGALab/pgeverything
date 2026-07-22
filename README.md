# PGEverything

**One PostgreSQL 16 image with everything a developer needs to build a modern AI Foundry.**

Instead of running six databases — Postgres, MongoDB, Neo4j, InfluxDB, Redis, Pinecone —
PGEverything gives you one PostgreSQL server, one port, six workloads. Everything is a
Postgres extension, so it is all transactional, backed up together, and queried in one SQL
dialect.

| Capability | Powered by |
|---|---|
| **SQL** | Core PostgreSQL 16 |
| **NoSQL / document** | Native JSONB + GIN |
| **Graph** | Apache AGE (openCypher) |
| **Time-series** | TimescaleDB |
| **Pub/Sub** | pgmq (durable queues) + `LISTEN`/`NOTIFY` |
| **Vector** | pgvector + pgvectorscale |

Plus `pg_cron`, `pg_trgm`, `pgcrypto`, `pg_stat_statements`, and optional **PostGIS**.

## Quick start

```bash
make build      # build the image (compiles AGE + pgmq)
make up         # start it, wait for healthy
make smoke      # verify all six capabilities
make shell      # psql in
```

Connect: `postgres://postgres:postgres@localhost:5432/pgeverything`

## Examples

**Document (JSONB)**
```sql
CREATE TABLE docs (id bigserial, doc jsonb);
CREATE INDEX ON docs USING gin (doc jsonb_path_ops);
SELECT * FROM docs WHERE doc @> '{"status":"active"}';
```

**Graph (AGE)**
```sql
LOAD 'age'; SET search_path = ag_catalog, "$user", public;
SELECT * FROM cypher('g', $$ MATCH (a)-[:KNOWS]->(b) RETURN a,b $$) AS (a agtype, b agtype);
```

**Time-series (TimescaleDB)**
```sql
SELECT create_hypertable('metrics', 'ts');
SELECT time_bucket('5 minutes', ts) AS bucket, avg(value) FROM metrics GROUP BY bucket;
```

**Pub/Sub (pgmq)**
```sql
SELECT pgmq.create('jobs');
SELECT pgmq.send('jobs', '{"task":"embed"}');
SELECT * FROM pgmq.read('jobs', vt => 30, qty => 1);   -- read with 30s visibility timeout
```

**Vector (pgvector)**
```sql
CREATE TABLE items (id bigserial, embedding vector(1536));
CREATE INDEX ON items USING hnsw (embedding vector_l2_ops);
SELECT id FROM items ORDER BY embedding <-> '[...]' LIMIT 5;
```

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `POSTGRES_PASSWORD` | `postgres` | superuser password |
| `POSTGRES_DB` | `pgeverything` | initial database |
| `PGE_PORT` | `5432` | host port |
| `PGE_ENABLE_POSTGIS` | `false` | enable PostGIS at first boot |

## Design

Built on `timescale/timescaledb-ha:pg16` (which bundles TimescaleDB + pgvector +
pgvectorscale); Apache AGE and pgmq are compiled from source in a builder stage. PostgreSQL
16 is the highest major where all six extensions have working builds today — Apache AGE is
the version limiter.

Full design spec: [docs/specs/v0.1.0.md](docs/specs/v0.1.0.md).
