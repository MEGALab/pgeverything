#!/usr/bin/env bash
# make replication-enable — authorize a replica on THIS host's running primary.
# Creates the replicator role, sets a WAL buffer, and appends a pg_hba rule for the
# replica's network, then reloads. Idempotent. Run this on the PRIMARY host.
set -euo pipefail
cd "$(dirname "$0")/.."

SERVICE=pgeverything
HBA=/home/postgres/pgdata/data/pg_hba.conf

read -r -p "Replica CIDR allowed to replicate (e.g. 203.0.113.7/32, or 0.0.0.0/0 for any): " CIDR
CIDR="${CIDR:-0.0.0.0/0}"
read -r -s -p "Set replication password (for role 'replicator'): " REPL_PASSWORD; echo
if [ -z "$REPL_PASSWORD" ]; then echo "ERROR: password required." >&2; exit 1; fi
if [ "$CIDR" = "0.0.0.0/0" ]; then
  echo "WARNING: 0.0.0.0/0 allows replication from ANY host — scope this to the replica in production."
fi

echo "Configuring primary for replication ..."
docker compose exec -T "$SERVICE" psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  -v pass="$REPL_PASSWORD" -f - < scripts/replication-enable.sql

# Append the pg_hba rule idempotently (inside the container; postgres owns the file).
docker compose exec -T "$SERVICE" bash -c '
  set -e
  HBA="'"$HBA"'"; CIDR="'"$CIDR"'"
  RULE="host replication replicator ${CIDR} scram-sha-256"
  if ! grep -qF "$RULE" "$HBA"; then echo "$RULE" >> "$HBA"; echo "added pg_hba rule: $RULE"; fi
'

docker compose exec -T "$SERVICE" psql -v ON_ERROR_STOP=1 -U postgres -c "SELECT pg_reload_conf();" >/dev/null

echo
echo "Primary authorized for replication."
echo "On the replica host, run:  make replicant"
echo "  Primary host = this server's reachable IP/DNS   Primary port = the published 5432"
echo "  Replication user = replicator                   Password = (what you just set)"
echo "Ensure the primary's Postgres port is reachable from the replica (firewall)."
