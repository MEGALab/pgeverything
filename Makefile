IMAGE   ?= pgeverything:0.1.0
DB      ?= pgeverything
PSQL     = docker compose exec -T pgeverything psql -v ON_ERROR_STOP=1 -U postgres -d $(DB)

# Args for `make create-db` (override on the command line).
NEW_DB       ?=
NEW_USER     ?=
NEW_PASSWORD ?=

.PHONY: build up down logs shell smoke clean create-db \
        replication-enable replicant replicant-smoke replica-status

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
