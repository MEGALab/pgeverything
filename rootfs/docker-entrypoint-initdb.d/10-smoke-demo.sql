-- PGEverything — seed one demo object per capability so a fresh container is
-- immediately explorable. Safe to drop; purely illustrative.

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

-- 3. Graph (Apache AGE)
LOAD 'age';
SET search_path = ag_catalog, "$user", public;
SELECT create_graph('demo_graph');
SELECT * FROM cypher('demo_graph', $$
    CREATE (:Agent {name: 'scout'})-[:USES]->(:Tool {name: 'postgres'})
$$) AS (v agtype);
