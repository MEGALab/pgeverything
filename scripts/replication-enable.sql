-- replication-enable.sql — authorize streaming replication on the primary.
-- Piped in by scripts/replication-enable.sh:  psql ... -v pass=<replpw> -f -
-- psql interpolates :'pass' as an escaped string literal.

-- Replication role (idempotent create, then (re)set the password).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH REPLICATION LOGIN;
  END IF;
END $$;
ALTER ROLE replicator WITH REPLICATION LOGIN PASSWORD :'pass';

-- Keep a WAL buffer so a briefly-disconnected standby can catch up without a re-seed.
ALTER SYSTEM SET wal_keep_size = '512MB';

-- Fail loudly if the server can't stream (would need a restart with -c wal_level=replica).
DO $$ BEGIN
  ASSERT current_setting('wal_level') IN ('replica', 'logical'),
    'wal_level is too low for replication — recreate the primary with -c wal_level=replica';
END $$;
