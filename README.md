# PGEverything

**One PostgreSQL 16 image with everything a developer needs to build a modern AI Foundry.**

Instead of running nine databases and services — Postgres, MongoDB, Neo4j, InfluxDB, Redis,
Pinecone, Elasticsearch, Auth0, plus a cache — PGEverything gives you one PostgreSQL server,
one port, nine workloads. Everything is a Postgres extension, so it is all transactional,
backed up together, and queried in one SQL dialect.

| Capability | Powered by |
|---|---|
| **SQL** | Core PostgreSQL 16 |
| **NoSQL / document** | Native JSONB + GIN |
| **Graph** | Apache AGE (openCypher) |
| **Time-series** | TimescaleDB |
| **Pub/Sub** | pgmq (durable queues) + `LISTEN`/`NOTIFY` |
| **Vector** | pgvector + pgvectorscale |
| **Key-value cache** | pgcache (jsonb values, TTL) |
| **Full-text search** | core tsvector + GIN |
| **Auth / RLS** | pgauth (JWT via pgjwt) + Row-Level Security |

Plus `pg_cron`, `pg_trgm`, `pgcrypto`, `pgjwt`, `pg_stat_statements`, and optional **PostGIS**.

## Quick start

```bash
make build      # build the image (compiles AGE + pgmq)
make up         # start it, wait for healthy
make smoke      # verify all nine capabilities
make shell      # psql in
```

Connect: `postgres://postgres:postgres@localhost:5432/pgeverything`

### Provisioning isolated databases

Create a new database with its own **isolated** owner role (all three args required):

```bash
make create-db NEW_DB=analytics NEW_USER=analyst NEW_PASSWORD=changeme
```

Creates a plain `LOGIN` role (no `SUPERUSER`/`CREATEDB`/`CREATEROLE`) that owns the new
database and **can connect to that database only** — it is denied access to the primary DB,
the `postgres` maintenance DB, and every other tenant's database. See
[scripts/create-db.sql](scripts/create-db.sql) for how the isolation works (revoking the
default `PUBLIC` `CONNECT` privilege). The container must be running (`make up` first).

> Isolation relies on `CONNECT` privileges, which superusers bypass by design — so the
> `postgres` superuser still administers every database. Provisioning a tenant also locks
> the shared databases against `PUBLIC`, keeping `app_user` access to the primary DB intact.

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

**Key-value cache (pgcache)**
```sql
SELECT cache_set('user:1', '{"name":"alice"}'::jsonb, ttl => 60);  -- ttl seconds, NULL = forever
SELECT cache_get('user:1');    -- {"name": "alice"}, or NULL once expired
SELECT cache_incr('hits');     -- atomic counter, returns new value
SELECT cache_del('user:1');    -- true if the key existed
```

**Full-text search (core tsvector)** — no extension needed
```sql
CREATE TABLE articles (
  id   bigserial,
  body text,
  fts  tsvector GENERATED ALWAYS AS (to_tsvector('english', body)) STORED
);
CREATE INDEX ON articles USING gin (fts);
SELECT id FROM articles WHERE fts @@ to_tsquery('english', 'quick & fox');
```

## Authentication & Row-Level Security

`pgauth` gives you bcrypt password hashing (pgcrypto), JWT sessions (pgjwt), and per-user row
isolation via PostgreSQL Row-Level Security — no external auth service required.

> ⚠️ **Two things that make or break RLS:**
> 1. **Connect as a non-superuser role.** Superusers *bypass* RLS. PGEverything ships an
>    `app_user` role for exactly this — your app connects as it (set `PGE_APP_USER_PASSWORD`),
>    or you `SET ROLE app_user`. As `postgres` you will see every row.
> 2. **Set `PGE_JWT_SECRET`.** The default is insecure and public. Anyone with the secret can
>    forge sessions. The secret is stored in a protected table only `SECURITY DEFINER`
>    functions can read — `app_user` cannot read it.

**The users table** (created for you by the `pgauth` extension):
```sql
-- auth.users(id uuid pk, email text unique, pass_hash text, role text, created_at timestamptz)
SELECT auth.register('alice@example.com', 's3cret');   -- bcrypt-hashes the password, returns the new uuid
```

**Log in → validate the session on the server:**
```sql
SELECT auth.login('alice@example.com', 's3cret');      -- returns a signed JWT (1h expiry), or NULL if wrong
SELECT auth.authenticate('<that jwt>');                -- verifies signature + expiry, loads claims into the session
SELECT auth.uid();                                     -- alice's uuid, or NULL if unauthenticated
```

**Per-user data with RLS** — every row belongs to its creator, and users only ever see their own:
```sql
CREATE TABLE notes (
  id       bigserial PRIMARY KEY,
  owner_id uuid NOT NULL DEFAULT auth.uid(),            -- auto-stamped with the logged-in user
  body     text NOT NULL
);
ALTER TABLE notes ENABLE ROW LEVEL SECURITY;
CREATE POLICY notes_owner ON notes
  USING (owner_id = auth.uid())                         -- read: only my rows
  WITH CHECK (owner_id = auth.uid());                   -- write: can't create rows for others
GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO app_user;
```

**Putting it together** (as the application role):
```sql
SELECT auth.authenticate(auth.login('alice@example.com', 's3cret'));
SET ROLE app_user;                                      -- RLS now applies
INSERT INTO notes (body) VALUES ('only alice can see this');
SELECT * FROM notes;                                    -- returns only alice's rows
```

`notes` is a working example baked into the image; `auth.role()` exposes the JWT `role` claim
for role-based policies. (Open registration and 1-hour non-refreshable tokens are dev defaults
— restrict `auth.register` and add refresh tokens for production.)

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `POSTGRES_PASSWORD` | `postgres` | superuser password |
| `POSTGRES_DB` | `pgeverything` | initial database |
| `PGE_PORT` | `5432` | host port |
| `PGE_ENABLE_POSTGIS` | `false` | enable PostGIS at first boot |
| `PGE_SHARED_BUFFERS` | `256MB` | shared_buffers — set to ≈25% of RAM |
| `PGE_WORK_MEM` | `16MB` | work_mem per sort/hash operation |
| `PGE_MAX_CONNECTIONS` | `100` | max concurrent connections |
| `PGE_JWT_SECRET` | *(insecure default)* | pgauth JWT signing secret — **change this** |
| `PGE_APP_USER_PASSWORD` | *(empty)* | set to enable direct `app_user` logins (else NOLOGIN) |

> ⚠️ **If you change `POSTGRES_DB`**, you must also update `cron.database_name` in
> `docker-compose.yml` (and `rootfs/postgresql.conf.d/pgeverything.conf`) to the same value.
> pg_cron requires them to match — otherwise first-boot init fails with
> *"CREATE EXTENSION pg_cron must be run in the database named by cron.database_name"*.

## Design

Built on `timescale/timescaledb-ha:pg16` (which bundles TimescaleDB + pgvector +
pgvectorscale); Apache AGE and pgmq are compiled from source in a builder stage, and
`pgcache` and `pgauth` are first-party pure-SQL extensions staged into the image, and
`pgjwt` (JWT sign/verify) is installed from source in the builder stage. PostgreSQL 16 is the
highest major where all the third-party extensions have working builds today — Apache AGE
is the version limiter.

Full design spec: [docs/specs/v0.1.0.md](docs/specs/v0.1.0.md).
