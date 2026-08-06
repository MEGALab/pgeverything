#!/usr/bin/env bash
# Dispatcher for the pgvault `make secrets-*` / `make secret-*` commands. Each subcommand
# prompts, then calls the matching vault.* function via psql (piped over -f - so psql
# interpolates :'var' safely). Target database via DB env (default pgeverything).
set -euo pipefail
cd "$(dirname "$0")/.."

SVC=pgeverything
DEFAULT_DB="${DB:-pgeverything}"
WORDLIST=/usr/share/pgeverything/eff_large_wordlist.txt

ask() {  # ask VAR "Question" [default]
  local var="$1" q="$2" def="${3:-}" ans
  read -r -p "$q${def:+ [$def]}: " ans
  printf -v "$var" '%s' "${ans:-$def}"
}
gen_passphrase() {  # 12-word EFF diceware passphrase, matching the schema-user convention
  docker compose exec -T "$SVC" sh -c "shuf -n 12 $WORDLIST | paste -sd- -" | tr -d '\r\n'
}

# The vault (extension, key, users) is per-database, so every subcommand targets one DB.
cmd="${1:-}"
case "$cmd" in
  init|create|read|update|delete|user-create|user-deactivate|user-passwd|red-alert|stand-down) ;;
  *) echo "usage: secrets.sh {init|create|read|update|delete|user-create|user-deactivate|user-passwd|red-alert|stand-down}" >&2
     exit 1 ;;
esac
ask db "Target database" "$DEFAULT_DB"
vsql()   { docker compose exec -T "$SVC" psql -v ON_ERROR_STOP=1 -U postgres -d "$db" "$@"; }
scalar() { docker compose exec -T "$SVC" psql -tA -U postgres -d "$db" -c "$1" | tr -d '[:space:]'; }

case "$cmd" in
  init)
    if [ -z "${PGE_VAULT_KEY:-}" ]; then
      echo "WARNING: PGE_VAULT_KEY is not set — pgsodium is using an INSECURE default key."
    fi
    # Create the vault (extension + pgsodium key). The key is created once and kept on re-run,
    # so previously stored secrets still decrypt.
    vsql -f - <<'SQL'
      CREATE EXTENSION IF NOT EXISTS pgcrypto;
      -- AGE is in shared_preload_libraries, so its ProcessUtility hook intercepts every
      -- ALTER TABLE cluster-wide and requires ag_catalog.ag_label to exist. pgsodium runs
      -- ALTER TABLE during its own CREATE EXTENSION, so the vault's DB must have AGE first.
      CREATE EXTENSION IF NOT EXISTS age;
      CREATE EXTENSION IF NOT EXISTS pgsodium;
      CREATE EXTENSION IF NOT EXISTS pgvault;
      INSERT INTO vault.config (id, key_id)
      SELECT true, (SELECT id FROM pgsodium.create_key())
      WHERE NOT EXISTS (SELECT 1 FROM vault.config);
SQL
    # Bootstrap the master admin once. If one already exists (re-run), keep it — the passphrase
    # is shown only at creation and cannot be recovered, so we never mint a second admin silently.
    existing="$(scalar "SELECT username FROM vault.users WHERE is_admin ORDER BY created_at LIMIT 1;")"
    if [ -n "$existing" ]; then
      echo "Vault on '$db' already has a master admin ('$existing') — left unchanged."
      exit 0
    fi
    admin="$(scalar 'SELECT gen_random_uuid();')"
    pass="$(gen_passphrase)"
    [ -n "$admin" ] && [ -n "$pass" ] || { echo "failed to generate admin id / passphrase" >&2; exit 1; }
    vsql -v admin="$admin" -v pass="$pass" -f - <<'SQL' >/dev/null
      SELECT vault._create_admin(:'admin', :'pass');
SQL
    echo "Vault initialized on database '$db'."
    echo "admin_user: $admin  (master admin — manages users; cannot read/write secrets)"
    echo "passphrase: $pass"
    echo "Save the passphrase now — it is shown only once and cannot be recovered."
    ;;

  create)
    read -r -p "Vault username (write/both): " u
    read -r -s -p "Password: " p; echo
    read -r -p "Secret name (optional): " name
    read -r -p "Description (optional): " desc
    read -r -s -p "Secret value: " secret; echo
    vsql -v u="$u" -v p="$p" -v name="$name" -v desc="$desc" -v secret="$secret" -f - <<'SQL'
      SELECT vault.create_secret(:'u', :'p', :'secret',
                                 nullif(:'name',''), nullif(:'desc','')) AS secret_id;
SQL
    ;;

  read)
    read -r -p "Vault username (read/both): " u
    read -r -s -p "Password: " p; echo
    read -r -p "Secret UUID: " sid
    vsql -v u="$u" -v p="$p" -v sid="$sid" -f - <<'SQL'
      SELECT vault.reveal_secret(:'u', :'p', :'sid'::uuid) AS secret;
SQL
    ;;

  update)
    read -r -p "Vault username (write/both): " u
    read -r -s -p "Password: " p; echo
    read -r -p "Secret UUID: " sid
    read -r -s -p "New secret value: " secret; echo
    vsql -v u="$u" -v p="$p" -v sid="$sid" -v secret="$secret" -f - <<'SQL'
      SELECT vault.update_secret(:'u', :'p', :'sid'::uuid, :'secret') AS updated;
SQL
    ;;

  delete)
    read -r -p "Vault username (write/both): " u
    read -r -s -p "Password: " p; echo
    read -r -p "Secret UUID: " sid
    vsql -v u="$u" -v p="$p" -v sid="$sid" -f - <<'SQL'
      SELECT vault.delete_secret(:'u', :'p', :'sid'::uuid) AS deleted;
SQL
    ;;

  user-create)
    read -r -p "Vault ADMIN username: " a
    read -r -s -p "Admin password: " ap; echo
    read -r -p "Permission for new user (read/write/both): " perm
    vsql -v a="$a" -v ap="$ap" -v perm="$perm" -f - <<'SQL'
      SELECT * FROM vault.create_user(:'a', :'ap', :'perm');
SQL
    echo "^ Save these credentials now — the password cannot be recovered."
    ;;

  user-deactivate)
    read -r -p "Vault ADMIN username: " a
    read -r -s -p "Admin password: " ap; echo
    read -r -p "Username to deactivate: " target
    vsql -v a="$a" -v ap="$ap" -v t="$target" -f - <<'SQL'
      SELECT vault.deactivate_user(:'a', :'ap', :'t') AS deactivated;
SQL
    ;;

  user-passwd)
    read -r -p "Username: " u
    read -r -s -p "Current password: " cur; echo
    read -r -s -p "New password: " new; echo
    vsql -v u="$u" -v cur="$cur" -v new="$new" -f - <<'SQL'
      SELECT vault.change_password(:'u', :'cur', :'new') AS changed;
SQL
    ;;

  red-alert)
    read -r -p "Vault ADMIN username: " a
    read -r -s -p "Admin password: " ap; echo
    vsql -v a="$a" -v ap="$ap" -f - <<'SQL'
      SELECT vault.red_alert(:'a', :'ap') AS locked;
SQL
    echo "Vault LOCKED — secret access is disabled until stand-down."
    ;;

  stand-down)
    read -r -p "Vault ADMIN username: " a
    read -r -s -p "Admin password: " ap; echo
    vsql -v a="$a" -v ap="$ap" -f - <<'SQL'
      SELECT vault.stand_down(:'a', :'ap') AS active;
SQL
    echo "Vault reactivated."
    ;;

  *)
    echo "usage: secrets.sh {init|create|read|update|delete|user-create|user-deactivate|user-passwd|red-alert|stand-down}" >&2
    exit 1
    ;;
esac
