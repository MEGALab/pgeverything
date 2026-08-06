IMAGE   ?= pgeverything:0.1.0
DB      ?= pgeverything
PSQL     = docker compose exec -T pgeverything psql -v ON_ERROR_STOP=1 -U postgres -d $(DB)

# Args for `make create-db` (override on the command line).
NEW_DB       ?=
NEW_USER     ?=
NEW_PASSWORD ?=

.PHONY: build up down logs shell smoke clean create-db \
        replication-enable replicant replicant-smoke replica-status \
        secrets-init secrets-create secret-read secrets-update secret-delete \
        secret-user-create secret-user-deactivate secret-user-passwd \
        secret-red-alert secret-stand-down secrets-smoke \
        user-create user-read user-update-password user-deactivate user-delete \
        database-create

build:            ## Build the image
	docker build -t $(IMAGE) .

up:  build             ## Start the container (detached) and wait for health
	docker compose up -d
	@echo "Waiting for healthy..." && \
	 until [ "$$(docker inspect -f '{{.State.Health.Status}}' pgeverything 2>/dev/null)" = "healthy" ]; do sleep 2; done && \
	 echo "ready."

down:             ## Stop and remove the container
	docker compose down

logs:             ## Tail logs
	docker compose logs -f

shell:            ## psql into the database
	docker compose exec pgeverything psql -U postgres -d $(DB)

smoke: up         ## Run the nine-capability smoke suite
	$(PSQL) -f - < test/smoke.sql

clean:            ## Remove container + data volume
	docker compose down -v

create-db:        ## Create an isolated tenant DB + owner role: make create-db NEW_DB=x NEW_USER=y NEW_PASSWORD=z
	@test -n "$(NEW_DB)"       || { echo "Usage: make create-db NEW_DB=<db> NEW_USER=<user> NEW_PASSWORD=<pw>"; exit 1; }
	@test -n "$(NEW_USER)"     || { echo "Usage: make create-db NEW_DB=<db> NEW_USER=<user> NEW_PASSWORD=<pw>"; exit 1; }
	@test -n "$(NEW_PASSWORD)" || { echo "Usage: make create-db NEW_DB=<db> NEW_USER=<user> NEW_PASSWORD=<pw>"; exit 1; }
	@# Pipe the provisioning script via stdin (-f -): psql only interpolates :vars for
	@# file/stdin input, not for -c strings. See scripts/create-db.sql for the isolation.
	docker compose exec -T pgeverything psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
	  -v user="$(NEW_USER)" -v pass="$(NEW_PASSWORD)" -v db="$(NEW_DB)" -v maindb="$(DB)" \
	  -f - < scripts/create-db.sql
	@echo "Created isolated database '$(NEW_DB)' owned by '$(NEW_USER)' — no access to other databases."

# --- Physical replication (see README "Physical replication") -------------------------
replication-enable: ## (PRIMARY host) authorize a replica: role + pg_hba + wal_keep_size
	@bash scripts/replication-enable.sh

replicant:          ## (REPLICA host) set up a streaming replica of a remote primary (prompts)
	@bash scripts/replicant.sh

replicant-smoke:    ## Verify replication (standby, streaming, read-only, propagation) — separate from `smoke`
	@bash scripts/replicant-smoke.sh

replica-status:     ## Quick replication status (recovery + wal receiver)
	@docker compose -f docker-compose.replica.yml exec -T replica \
	  psql -x -U postgres -d pgeverything \
	  -c "SELECT pg_is_in_recovery() AS in_recovery;" \
	  -c "SELECT status, sender_host, sender_port, conninfo IS NOT NULL AS has_conninfo FROM pg_stat_wal_receiver;"

# --- Secrets vault (pgvault). All honor DB ?= to target any database. See README. --------
secrets-init:            ## Set up the vault; prompts for the DB, autogenerates the admin UUID + passphrase
	@bash scripts/secrets.sh init
secrets-create:          ## Add a secret (prompts for a write/both user + the secret)
	@bash scripts/secrets.sh create
secret-read:             ## Reveal a secret's plaintext by UUID (prompts for a read/both user)
	@bash scripts/secrets.sh read
secrets-update:          ## Update a secret by UUID (prompts)
	@bash scripts/secrets.sh update
secret-delete:           ## Delete a secret by UUID (prompts)
	@bash scripts/secrets.sh delete
secret-user-create:      ## Admin creates a read/write/both user (autogen creds; prompts)
	@bash scripts/secrets.sh user-create
secret-user-deactivate:  ## Admin deactivates a secrets user (prompts)
	@bash scripts/secrets.sh user-deactivate
secret-user-passwd:      ## Change a user's password (prompts: user, current, new)
	@bash scripts/secrets.sh user-passwd
secret-red-alert:        ## Admin locks the entire vault (prompts)
	@bash scripts/secrets.sh red-alert
secret-stand-down:       ## Admin reactivates the vault (prompts)
	@bash scripts/secrets.sh stand-down
secrets-smoke:           ## Verify the vault end-to-end on an ephemeral DB — separate from `smoke`
	@bash scripts/secrets-smoke.sh

# --- Schema-scoped users (real Postgres roles). Each prompts for the target database. -----
user-create:          ## Create a schema user (prompts db + schema; autogen UUID + passphrase)
	@bash scripts/users.sh create
user-read:            ## Show a schema user's record (prompts db + user id)
	@bash scripts/users.sh read
user-update-password: ## Set a schema user's password (prompts db + user id + new password)
	@bash scripts/users.sh update-password
user-deactivate:      ## Lock a schema user out (random undisclosed passphrase; keeps data)
	@bash scripts/users.sh deactivate
user-delete:          ## Delete a schema user + all its objects in the DB (prompts, confirms)
	@bash scripts/users.sh delete

# --- Databases -------------------------------------------------------------------------
database-create:      ## Create a new database + bootstrap its admin user (prompts)
	@bash scripts/database-create.sh
