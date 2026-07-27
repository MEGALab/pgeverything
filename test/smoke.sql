-- PGEverything smoke suite — one assertion per capability. Run with:
--   psql -v ON_ERROR_STOP=1 -f test/smoke.sql
-- Any failed assertion RAISEs and aborts with a non-zero exit (CI-ready).

\set ON_ERROR_STOP on

-- 1. SQL
DO $$ BEGIN
  ASSERT (SELECT 1) = 1, 'SQL: SELECT 1 failed';
  RAISE NOTICE '[1/7] SQL              ok';
END $$;

-- 2. NoSQL / document (JSONB containment via GIN)
DO $$ DECLARE n int; BEGIN
  CREATE TEMP TABLE t_doc (doc jsonb);
  INSERT INTO t_doc VALUES ('{"k":"v","tags":["a","b"]}');
  SELECT count(*) INTO n FROM t_doc WHERE doc @> '{"tags":["a"]}';
  ASSERT n = 1, 'JSONB: containment query failed';
  RAISE NOTICE '[2/7] JSONB document   ok';
END $$;

-- 3. Graph (Apache AGE / openCypher)
LOAD 'age';
SET search_path = ag_catalog, "$user", public;
DO $$ BEGIN
  PERFORM create_graph('smoke_graph');
  RAISE NOTICE '[3/7] Graph (AGE)      ok';
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
  RAISE NOTICE '[4/7] Time-series      ok';
END $$;

-- 5. Pub/Sub (pgmq durable queue)
DO $$ DECLARE msg_id bigint; got jsonb; BEGIN
  PERFORM pgmq.create('smoke_q');
  SELECT pgmq.send('smoke_q', '{"hello":"world"}') INTO msg_id;
  SELECT message INTO got FROM pgmq.read('smoke_q', 30, 1) LIMIT 1;
  ASSERT got->>'hello' = 'world', 'pgmq: send/read roundtrip failed';
  PERFORM pgmq.drop_queue('smoke_q');
  RAISE NOTICE '[5/7] Pub/Sub (pgmq)   ok';
END $$;

-- 6. Vector (pgvector nearest-neighbor)
DO $$ DECLARE nearest text; BEGIN
  CREATE TEMP TABLE t_vec (content text, embedding vector(3));
  INSERT INTO t_vec VALUES ('a','[1,0,0]'), ('b','[0,1,0]'), ('c','[0,0,1]');
  SELECT content INTO nearest FROM t_vec ORDER BY embedding <-> '[0.9,0.1,0]' LIMIT 1;
  ASSERT nearest = 'a', 'pgvector: nearest-neighbor wrong result';
  RAISE NOTICE '[6/7] Vector           ok';
END $$;

-- 7. Key-value cache (pgcache set/get/expiry)
DO $$ DECLARE got jsonb; BEGIN
  PERFORM cache_set('smoke:k', '{"v":1}'::jsonb, ttl => 60);
  SELECT cache_get('smoke:k') INTO got;
  ASSERT got->>'v' = '1', 'pgcache: set/get roundtrip failed';
  PERFORM cache_set('smoke:gone', '{"v":2}'::jsonb, ttl => -1);   -- already expired
  ASSERT cache_get('smoke:gone') IS NULL, 'pgcache: expired key still visible';
  ASSERT cache_del('smoke:k') = true, 'pgcache: del did not report existing key';
  RAISE NOTICE '[7/7] Key-value cache  ok';
END $$;

\echo '=== PGEverything: all seven capabilities verified ==='
