IMAGE   ?= pgeverything:0.1.0
DB      ?= pgeverything
PSQL     = docker compose exec -T pgeverything psql -v ON_ERROR_STOP=1 -U postgres -d $(DB)

.PHONY: build up down logs shell smoke clean

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

smoke: up         ## Run the seven-capability smoke suite
	$(PSQL) -f - < test/smoke.sql

clean:            ## Remove container + data volume
	docker compose down -v
