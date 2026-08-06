#!/usr/bin/env bash
# pgsodium root-key provider. Invoked by pgsodium at server start to obtain the 32-byte
# (64 hex char) server key. Sourced from PGE_VAULT_KEY so the key lives in the container
# environment, NOT in the database (a pg_dump therefore never contains it).
#
# If PGE_VAULT_KEY is unset we emit a FIXED, INSECURE dev key so the cluster still boots
# (pgsodium is in shared_preload_libraries — a missing key would otherwise stop startup).
# Production MUST set PGE_VAULT_KEY (openssl rand -hex 32).
set -euo pipefail

if [ -n "${PGE_VAULT_KEY:-}" ]; then
  printf '%s' "$PGE_VAULT_KEY"
else
  echo "WARNING: PGE_VAULT_KEY unset — using an INSECURE default vault key. Set PGE_VAULT_KEY in production." >&2
  # 64 hex chars = 32 bytes. Obviously-insecure sentinel.
  printf '%s' "0000000000000000000000000000000000000000000000000000000000000000"
fi
