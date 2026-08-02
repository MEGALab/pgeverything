#!/usr/bin/env bash
# PGEverything — replica entrypoint. On first boot (empty PGDATA) it clones the remote
# primary with pg_basebackup and starts as a streaming hot standby; on later boots it just
# starts Postgres, which resumes streaming from where it left off.
#
# Invoked as the container entrypoint; the compose `command:` (postgres -c ...) is passed
# through as "$@" so preload/config match the primary exactly.
set -euo pipefail

PGDATA="${PGDATA:-/home/postgres/pgdata/data}"
: "${PGE_PRIMARY_HOST:?PGE_PRIMARY_HOST is required for a replica}"
: "${PGE_REPL_PASSWORD:?PGE_REPL_PASSWORD is required for a replica}"
PORT="${PGE_PRIMARY_PORT:-5432}"
REPL_USER="${PGE_REPL_USER:-replicator}"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "replica: waiting for primary ${PGE_PRIMARY_HOST}:${PORT} to accept connections ..."
  until pg_isready -h "$PGE_PRIMARY_HOST" -p "$PORT" -U "$REPL_USER" -q; do sleep 2; done

  echo "replica: cloning primary via pg_basebackup ..."
  rm -rf "${PGDATA:?}"/* 2>/dev/null || true
  # -R writes standby.signal + primary_conninfo (incl. password); -Xs streams WAL during the
  # backup via a temporary slot; -P shows progress.
  PGPASSWORD="$PGE_REPL_PASSWORD" pg_basebackup \
      -h "$PGE_PRIMARY_HOST" -p "$PORT" -U "$REPL_USER" \
      -D "$PGDATA" -Fp -Xs -R -P
  echo "replica: base backup complete; starting as hot standby."
fi

exec "$@"
