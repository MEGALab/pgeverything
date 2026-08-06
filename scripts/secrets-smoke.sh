#!/usr/bin/env bash
# make secrets-smoke — end-to-end pgvault verification against an EPHEMERAL database
# (vault_smoke), dropped at the end. Kept SEPARATE from `make smoke`. Exits non-zero on
# any failure. Runs as the postgres superuser; the vault functions self-authenticate.
set -uo pipefail
cd "$(dirname "$0")/.."

SVC=pgeverything
SMOKE_DB=vault_smoke
ADMIN=smoke_admin
ADMIN_PW=smoke_admin_pw

pg()  { docker compose exec -T "$SVC" psql -v ON_ERROR_STOP=1 -U postgres "$@"; }        # arbitrary db via -d
vdb() { docker compose exec -T "$SVC" psql -v ON_ERROR_STOP=1 -U postgres -d "$SMOKE_DB" "$@"; }
q()   { vdb -tA -c "$1" 2>/dev/null | tr -d '[:space:]'; }   # scalar query
fail(){ echo "FAIL: $1"; cleanup; exit 1; }
cleanup(){ pg -d postgres -c "DROP DATABASE IF EXISTS $SMOKE_DB WITH (FORCE);" >/dev/null 2>&1 || true; }

# 0. Fresh throwaway DB + vault bootstrap.
cleanup
pg -d postgres -c "CREATE DATABASE $SMOKE_DB;" >/dev/null || fail "could not create $SMOKE_DB"
vdb -v admin="$ADMIN" -v pass="$ADMIN_PW" -f - <<'SQL' >/dev/null || fail "vault bootstrap failed"
  CREATE EXTENSION IF NOT EXISTS pgcrypto;
  -- AGE (in shared_preload_libraries) hooks every ALTER TABLE and needs ag_catalog.ag_label;
  -- pgsodium's CREATE EXTENSION runs ALTER TABLE, so this throwaway DB must have AGE first.
  CREATE EXTENSION IF NOT EXISTS age;
  CREATE EXTENSION IF NOT EXISTS pgsodium;
  CREATE EXTENSION IF NOT EXISTS pgvault;
  INSERT INTO vault.config (id, key_id)
  SELECT true, (SELECT id FROM pgsodium.create_key())
  WHERE NOT EXISTS (SELECT 1 FROM vault.config);
  INSERT INTO vault.users (username, pass_hash, perm, is_admin)
  SELECT :'admin', vault.hash_password(:'pass'), NULL, true
  WHERE NOT EXISTS (SELECT 1 FROM vault.users WHERE username = :'admin');
SQL
echo "[1/6] bootstrap (extension + key + admin)   ok"

# 2. Admin creates a read/write user.
creds="$(vdb -tA -v a="$ADMIN" -v ap="$ADMIN_PW" -f - <<'SQL' 2>/dev/null | tr -d '[:space:]'
SELECT username || '|' || password FROM vault.create_user(:'a', :'ap', 'both');
SQL
)"
USER="${creds%%|*}"; PASS="${creds##*|}"
[ -n "$USER" ] && [ -n "$PASS" ] || fail "admin could not create a user"
echo "[2/6] admin created secrets user            ok"

# 3. That user stores + reveals a secret (round-trips exactly).
SID="$(vdb -tA -v u="$USER" -v p="$PASS" -f - <<'SQL' 2>/dev/null | tr -d '[:space:]'
SELECT vault.create_secret(:'u', :'p', 'hunter2', 'api', 'smoke');
SQL
)"
[ -n "$SID" ] || fail "user could not create a secret"
revealed="$(vdb -tA -v u="$USER" -v p="$PASS" -v sid="$SID" -f - <<'SQL' 2>/dev/null | tr -d '[:space:]'
SELECT vault.reveal_secret(:'u', :'p', :'sid'::uuid);
SQL
)"
[ "$revealed" = "hunter2" ] || fail "reveal returned '$revealed', expected 'hunter2'"
echo "[3/6] encrypt + reveal round-trip           ok"

# 4. RBAC: the admin (perm NULL) must NOT be able to create a secret; wrong password rejected.
if vdb -v a="$ADMIN" -v ap="$ADMIN_PW" -f - >/dev/null 2>&1 <<'SQL'
SELECT vault.create_secret(:'a', :'ap', 'x');
SQL
then fail "admin was allowed to create a secret (RBAC broken)"; fi
if vdb -v u="$USER" -f - >/dev/null 2>&1 <<'SQL'
SELECT vault.reveal_secret(:'u', 'wrong-password', gen_random_uuid());
SQL
then fail "wrong password was accepted"; fi
echo "[4/6] RBAC + bad-password rejection         ok"

# 5. At rest: stored ciphertext is not the plaintext.
enc="$(q "SELECT encode(secret_enc,'escape') FROM vault.secrets WHERE id = '$SID';")"
case "$enc" in *hunter2*) fail "plaintext found in stored ciphertext";; esac
echo "[5/6] ciphertext at rest (no plaintext)     ok"

# 6. Kill switch: red_alert blocks reveal; stand_down restores it.
# psql interpolates :'var' only for stdin/file input, not -c strings — so pipe these via -f -.
vdb -tA -v a="$ADMIN" -v ap="$ADMIN_PW" -f - >/dev/null 2>&1 <<'SQL'
SELECT vault.red_alert(:'a', :'ap');
SQL
if vdb -v u="$USER" -v p="$PASS" -v sid="$SID" -f - >/dev/null 2>&1 <<'SQL'
SELECT vault.reveal_secret(:'u', :'p', :'sid'::uuid);
SQL
then fail "reveal worked while vault was in red alert"; fi
vdb -tA -v a="$ADMIN" -v ap="$ADMIN_PW" -f - >/dev/null 2>&1 <<'SQL'
SELECT vault.stand_down(:'a', :'ap');
SQL
again="$(vdb -tA -v u="$USER" -v p="$PASS" -v sid="$SID" -f - <<'SQL' 2>/dev/null | tr -d '[:space:]'
SELECT vault.reveal_secret(:'u', :'p', :'sid'::uuid);
SQL
)"
[ "$again" = "hunter2" ] || fail "reveal did not recover after stand-down"
echo "[6/6] kill switch (red-alert/stand-down)    ok"

cleanup
echo "=== PGEverything: vault verified ==="
