-- PGEverything — seed one demo object per capability so a fresh container is
-- immediately explorable. Safe to drop; purely illustrative.

-- The database default search_path puts ag_catalog first (for AGE); pin unqualified
-- demo tables to public so they land where a user exploring the container looks.
-- The graph block below sets its own ag_catalog search_path.
SET search_path = public;

-- 2. NoSQL / document (JSONB + GIN)
CREATE TABLE IF NOT EXISTS demo_documents (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc   jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS demo_documents_doc_gin
    ON demo_documents USING gin (doc jsonb_path_ops);
INSERT INTO demo_documents (doc)
VALUES ('{"type":"agent","name":"scout","tags":["ai","foundry"]}');

-- 4. Time-series (TimescaleDB hypertable)
CREATE TABLE IF NOT EXISTS demo_metrics (
    ts      timestamptz NOT NULL DEFAULT now(),
    sensor  text        NOT NULL,
    value   double precision
);
SELECT create_hypertable('demo_metrics', 'ts', if_not_exists => TRUE);
INSERT INTO demo_metrics (sensor, value) VALUES ('cpu', 0.42), ('cpu', 0.55);

-- 6. Vector (pgvector)
CREATE TABLE IF NOT EXISTS demo_embeddings (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    content   text,
    embedding vector(3)
);
INSERT INTO demo_embeddings (content, embedding)
VALUES ('hello', '[1,0,0]'), ('world', '[0,1,0]');

-- 5. Pub/Sub (pgmq durable queue)
SELECT pgmq.create('demo_queue');
SELECT pgmq.send('demo_queue', '{"event":"hello"}');

-- 8. Full-text search (core tsvector + GIN). Created while search_path is still public,
-- before the graph block below switches to ag_catalog.
CREATE TABLE IF NOT EXISTS demo_articles (
    id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    body  text NOT NULL,
    fts   tsvector GENERATED ALWAYS AS (to_tsvector('english', body)) STORED
);
CREATE INDEX IF NOT EXISTS demo_articles_fts_gin ON demo_articles USING gin (fts);
INSERT INTO demo_articles (body) VALUES
  ('PostgreSQL powers the modern AI foundry'),
  ('One database for vectors, graphs, and search');

-- 9. Auth / Row-Level Security — per-user data isolation. owner_id defaults to the
-- authenticated user (auth.uid()); the policy limits every row to its owner. Apps must
-- connect as the non-superuser app_user for the policy to apply (superusers bypass RLS).
CREATE TABLE IF NOT EXISTS notes (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id uuid NOT NULL DEFAULT auth.uid(),
    body     text NOT NULL
);
ALTER TABLE notes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notes_owner ON notes;
CREATE POLICY notes_owner ON notes
    USING (owner_id = auth.uid())
    WITH CHECK (owner_id = auth.uid());
GRANT SELECT, INSERT, UPDATE, DELETE ON notes TO app_user;

-- 3. Graph (Apache AGE)
LOAD 'age';
SET search_path = ag_catalog, "$user", public;
SELECT create_graph('demo_graph');
SELECT * FROM cypher('demo_graph', $$
    CREATE (:Agent {name: 'scout'})-[:USES]->(:Tool {name: 'postgres'})
$$) AS (v agtype);

-- 7. Key-value cache (pgcache)
SELECT cache_set('demo:greeting', '{"msg":"hello from pgcache"}'::jsonb, ttl => 3600);
