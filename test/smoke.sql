-- PGEverything smoke suite (ten capabilities) — one assertion per capability. Run with:
--   psql -v ON_ERROR_STOP=1 -f test/smoke.sql
-- Any failed assertion RAISEs and aborts with a non-zero exit (CI-ready).

\set ON_ERROR_STOP on

-- 1. SQL
DO $$ BEGIN
  ASSERT (SELECT 1) = 1, 'SQL: SELECT 1 failed';
  RAISE NOTICE '[1/10] SQL              ok';
END $$;

-- 2. NoSQL / document (JSONB containment via GIN)
DO $$ DECLARE n int; BEGIN
  CREATE TEMP TABLE t_doc (doc jsonb);
  INSERT INTO t_doc VALUES ('{"k":"v","tags":["a","b"]}');
  SELECT count(*) INTO n FROM t_doc WHERE doc @> '{"tags":["a"]}';
  ASSERT n = 1, 'JSONB: containment query failed';
  RAISE NOTICE '[2/10] JSONB document   ok';
END $$;

-- 3. Graph (Apache AGE / openCypher)
LOAD 'age';
SET search_path = ag_catalog, "$user", public;
DO $$ BEGIN
  PERFORM create_graph('smoke_graph');
  RAISE NOTICE '[3/10] Graph (AGE)      ok';
END $$;
SELECT * FROM cypher('smoke_graph', $$ CREATE (:N {id: 1}) RETURN 1 $$) AS (r agtype);
SELECT drop_graph('smoke_graph', true);

-- 4. Time-series (TimescaleDB)
DO $$ DECLARE b timestamptz; BEGIN
  CREATE TABLE t_ts (ts timestamptz NOT NULL, v double precision);
  PERFORM create_hypertable('t_ts', 'ts');
  INSERT INTO t_ts VALUES (now(), 1.0), (now(), 2.0);
  SELECT time_bucket('1 minute', ts) INTO b FROM t_ts LIMIT 1;
  ASSERT b IS NOT NULL, 'TimescaleDB: time_bucket failed';
  DROP TABLE t_ts;
  RAISE NOTICE '[4/10] Time-series      ok';
END $$;

-- 5. Pub/Sub (pgmq durable queue)
DO $$ DECLARE msg_id bigint; got jsonb; BEGIN
  PERFORM pgmq.create('smoke_q');
  SELECT pgmq.send('smoke_q', '{"hello":"world"}') INTO msg_id;
  SELECT message INTO got FROM pgmq.read('smoke_q', 30, 1) LIMIT 1;
  ASSERT got->>'hello' = 'world', 'pgmq: send/read roundtrip failed';
  PERFORM pgmq.drop_queue('smoke_q');
  RAISE NOTICE '[5/10] Pub/Sub (pgmq)   ok';
END $$;

-- 6. Vector (pgvector nearest-neighbor)
DO $$ DECLARE nearest text; BEGIN
  CREATE TEMP TABLE t_vec (content text, embedding vector(3));
  INSERT INTO t_vec VALUES ('a','[1,0,0]'), ('b','[0,1,0]'), ('c','[0,0,1]');
  SELECT content INTO nearest FROM t_vec ORDER BY embedding <-> '[0.9,0.1,0]' LIMIT 1;
  ASSERT nearest = 'a', 'pgvector: nearest-neighbor wrong result';
  RAISE NOTICE '[6/10] Vector           ok';
END $$;

-- 7. Key-value cache (pgcache set/get/expiry)
DO $$ DECLARE got jsonb; BEGIN
  PERFORM cache_set('smoke:k', '{"v":1}'::jsonb, ttl => 60);
  SELECT cache_get('smoke:k') INTO got;
  ASSERT got->>'v' = '1', 'pgcache: set/get roundtrip failed';
  PERFORM cache_set('smoke:gone', '{"v":2}'::jsonb, ttl => -1);   -- already expired
  ASSERT cache_get('smoke:gone') IS NULL, 'pgcache: expired key still visible';
  ASSERT cache_del('smoke:k') = true, 'pgcache: del did not report existing key';
  RAISE NOTICE '[7/10] Key-value cache  ok';
END $$;

-- 8. Full-text search (core tsvector / tsquery)
DO $$ DECLARE n int; BEGIN
  CREATE TEMP TABLE t_fts (
    body text,
    fts  tsvector GENERATED ALWAYS AS (to_tsvector('english', body)) STORED
  );
  INSERT INTO t_fts (body) VALUES ('the quick brown fox'), ('lazy dogs sleep');
  SELECT count(*) INTO n FROM t_fts WHERE fts @@ to_tsquery('english', 'quick & fox');
  ASSERT n = 1, 'FTS: tsvector match failed';
  RAISE NOTICE '[8/10] Full-text search  ok';
END $$;

-- 9. Partitioning (pg_partman — range-partition a table, confirm a child partition exists)
DO $$ DECLARE n int; BEGIN
  -- Schema-qualified: capability 3 (Graph) left search_path pointed at ag_catalog first, so an
  -- unqualified CREATE TABLE here would land there instead of public.
  CREATE TABLE public.t_part (ts timestamptz NOT NULL, v int) PARTITION BY RANGE (ts);
  PERFORM partman.create_parent(
    p_parent_table => 'public.t_part',
    p_control      => 'ts',
    p_interval     => '1 day'
  );
  INSERT INTO public.t_part (ts, v) VALUES (now(), 1);
  SELECT count(*) INTO n FROM pg_inherits WHERE inhparent = 'public.t_part'::regclass;
  ASSERT n > 0, 'pg_partman: no child partitions created';
  SELECT count(*) INTO n FROM public.t_part;
  ASSERT n = 1, 'pg_partman: insert did not route into a partition';
  DELETE FROM partman.part_config WHERE parent_table = 'public.t_part';
  DROP TABLE public.t_part CASCADE;
  -- create_parent() also leaves a template table (copies indexes/permissions onto future
  -- partitions) in the partman schema — drop it too so re-running this suite stays idempotent.
  DROP TABLE IF EXISTS partman.template_public_t_part;
  RAISE NOTICE '[9/10] Partitioning (pg_partman) ok';
END $$;

-- 10. Authentication / RLS (bcrypt + JWT + row-level security).
-- Wrapped in a transaction we roll back, so the suite stays idempotent (no persisted users).
BEGIN;
DO $$
DECLARE alice uuid; bob uuid; jwt_a text; jwt_b text; n int;
BEGIN
  alice := auth.register('alice@smoke.test', 'pw-alice');
  bob   := auth.register('bob@smoke.test',   'pw-bob');

  -- Alice authenticates, then (as the app role, so RLS applies) inserts a note.
  jwt_a := auth.login('alice@smoke.test', 'pw-alice');
  ASSERT jwt_a IS NOT NULL, 'auth: valid login returned no token';
  ASSERT auth.authenticate(jwt_a), 'auth: authenticate rejected a valid token';
  ASSERT auth.uid() = alice, 'auth: uid() does not match the logged-in user';
  SET LOCAL ROLE app_user;
  INSERT INTO notes (body) VALUES ('alice secret');
  SELECT count(*) INTO n FROM notes;
  ASSERT n = 1, 'RLS: owner cannot see own row';
  RESET ROLE;

  -- Bob authenticates; under RLS he must NOT see Alice's row.
  jwt_b := auth.login('bob@smoke.test', 'pw-bob');
  ASSERT auth.authenticate(jwt_b), 'auth: authenticate rejected a valid token';
  SET LOCAL ROLE app_user;
  SELECT count(*) INTO n FROM notes;
  ASSERT n = 0, 'RLS: user can see another user''s rows';
  RESET ROLE;

  -- Wrong password must fail.
  ASSERT auth.login('alice@smoke.test', 'wrong') IS NULL, 'auth: bad password was accepted';

  RAISE NOTICE '[10/10] Auth + RLS      ok';
END $$;
ROLLBACK;

\echo '=== PGEverything: all ten capabilities verified ==='
