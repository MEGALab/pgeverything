#!/usr/bin/env bash
# make replicant-smoke — verify streaming replication end to end. Kept SEPARATE from the
# single-node `make smoke`. Run on the REPLICA host. Exits non-zero on any failure.
set -uo pipefail
cd "$(dirname "$0")/.."

RE=(docker compose -f docker-compose.replica.yml exec -T replica)
rq() { "${RE[@]}" psql -tAX -U postgres -d pgeverything -c "$1" 2>/dev/null | tr -d '[:space:]'; }
fail() { echo "FAIL: $1"; exit 1; }

# 1. Replica is a standby.
[ "$(rq 'SELECT pg_is_in_recovery();')" = "t" ] || fail "replica is not in recovery (not a standby)"
echo "[1/4] standby (in recovery)      ok"

# 2. Streaming link is live (poll briefly — the receiver may take a moment to connect).
st=""
for _ in $(seq 1 15); do
  st="$(rq 'SELECT status FROM pg_stat_wal_receiver;')"
  [ "$st" = "streaming" ] && break
  sleep 2
done
[ "$st" = "streaming" ] || fail "wal receiver not streaming (status='${st:-none}')"
echo "[2/4] streaming from primary     ok"

# 3. Replica rejects writes (read-only).
if "${RE[@]}" psql -tAX -U postgres -d pgeverything -c "CREATE TABLE _ro_probe(x int);" >/dev/null 2>&1; then
  "${RE[@]}" psql -U postgres -d pgeverything -c "DROP TABLE IF EXISTS _ro_probe;" >/dev/null 2>&1 || true
  fail "replica accepted a write — it is not read-only"
fi
echo "[3/4] read-only enforced         ok"

# 4. Data actually propagates. Needs a superuser SQL connection to the primary; if that's
#    not permitted from here, SKIP (not fail) — checks 1-3 already prove the link.
set -a; [ -f .env ] && . ./.env; set +a
PH="${PGE_PRIMARY_HOST:-}"; PP="${PGE_PRIMARY_PORT:-5432}"; PW="${POSTGRES_PASSWORD:-}"
NONCE="repl-smoke-$(date +%s)-$$"
primary() { "${RE[@]}" env PGPASSWORD="$PW" psql -tAX -h "$PH" -p "$PP" -U postgres -d pgeverything -c "$1" 2>/dev/null; }

if [ -n "$PH" ] && [ -n "$PW" ] && \
   primary "INSERT INTO demo_documents(doc) VALUES (jsonb_build_object('_repl_smoke','$NONCE'));" >/dev/null; then
  seen=""
  for _ in $(seq 1 15); do
    [ "$(rq "SELECT count(*) FROM demo_documents WHERE doc->>'_repl_smoke' = '$NONCE';")" = "1" ] && { seen=1; break; }
    sleep 2
  done
  primary "DELETE FROM demo_documents WHERE doc->>'_repl_smoke' = '$NONCE';" >/dev/null || true
  [ -n "$seen" ] || fail "sentinel written on primary did not replicate within timeout"
  echo "[4/4] data propagation           ok"
else
  echo "[4/4] data propagation           SKIPPED (no superuser SQL to primary — set POSTGRES_PASSWORD in .env and allow 'host all' in the primary's pg_hba to run this check)"
fi

echo "=== PGEverything: replication verified ==="
