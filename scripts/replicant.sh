#!/usr/bin/env bash
# make replicant — interactively configure and launch a read-replica of a REMOTE primary.
# Prompts for the primary's connection details, persists them to .env, then brings the
# replica container up (docker-compose.replica.yml). Run this on the REPLICA host.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=".env"
[ -f "$ENV_FILE" ] || touch "$ENV_FILE"

# Read an existing value from .env (for prompt defaults).
cur() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# Upsert KEY=VALUE into .env.
put() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # Use a temp file for portable in-place edit (macOS/Linux sed differ).
    grep -vE "^${key}=" "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
}

prompt() {  # prompt VAR "Question" "default"
  local var="$1" q="$2" def="$3" ans
  read -r -p "$q [${def}]: " ans
  printf -v "$var" '%s' "${ans:-$def}"
}

echo "=== Configure a PGEverything read-replica of a remote primary ==="
def_host="$(cur PGE_PRIMARY_HOST)"
def_port="$(cur PGE_PRIMARY_PORT)";  def_port="${def_port:-5432}"
def_user="$(cur PGE_REPL_USER)";     def_user="${def_user:-replicator}"
def_rport="$(cur PGE_REPLICA_PORT)"; def_rport="${def_rport:-5432}"

prompt PRIMARY_HOST "Primary host/IP"   "$def_host"
prompt PRIMARY_PORT "Primary port"      "$def_port"
prompt REPL_USER    "Replication user"  "$def_user"
read -r -s -p "Replication password: " REPL_PASSWORD; echo
prompt REPLICA_PORT "Replica host port" "$def_rport"

if [ -z "$PRIMARY_HOST" ] || [ -z "$REPL_PASSWORD" ]; then
  echo "ERROR: primary host and replication password are required." >&2
  exit 1
fi

put PGE_PRIMARY_HOST "$PRIMARY_HOST"
put PGE_PRIMARY_PORT "$PRIMARY_PORT"
put PGE_REPL_USER    "$REPL_USER"
put PGE_REPL_PASSWORD "$REPL_PASSWORD"
put PGE_REPLICA_PORT "$REPLICA_PORT"

echo "Wrote replication settings to $ENV_FILE. Building + starting the replica ..."
docker compose -f docker-compose.replica.yml up -d --build

echo
echo "Replica 'pgeverything-replica' is starting on host port ${REPLICA_PORT}."
echo "It will pg_basebackup from ${PRIMARY_HOST}:${PRIMARY_PORT} on first boot (watch: docker logs -f pgeverything-replica)."
echo "Verify with:  make replicant-smoke"
