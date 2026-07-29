# syntax=docker/dockerfile:1
#
# PGEverything — one PostgreSQL 16 image with SQL, JSONB documents, graph (AGE),
# time-series (TimescaleDB), pub/sub (pgmq), and vectors (pgvector/pgvectorscale).
#
# Strategy: stand on Timescale's HA base (already ships TimescaleDB + pgvector +
# pgvectorscale on PG16), then compile the two extensions it lacks — Apache AGE and
# pgmq — in a throwaway builder stage and copy only the artifacts into the final image.

ARG BASE_IMAGE=timescale/timescaledb-ha:pg16

##############################################################################
# Stage 1 — builder: compile Apache AGE (C/PGXS) and pgmq (Rust/pgrx)
##############################################################################
FROM ${BASE_IMAGE} AS builder
USER root
ENV DEBIAN_FRONTEND=noninteractive

# Pin exact upstream refs for reproducible builds.
# NOTE: Apache AGE never tagged a final PG16/v1.5.0; the release-candidate tag
# (PG16/v1.5.0-rc0) is the pinned artifact for the 1.5.x line. Bump to
# PG16/v1.6.0-rc0 when moving to 1.6.x.
ARG AGE_REF=PG16/v1.5.0-rc0
ARG PGMQ_REF=v1.4.4
# pgjwt has no release tags; pin to a commit on master.
ARG PGJWT_REF=f3d82fd30151e754e19ce5d6a06c71c20689ce3d

# postgresql-server-dev-16 supplies the server headers (postgres.h, PGXS). The HA
# base ships the server binaries but NOT these headers; without it AGE/pgmq can't
# compile. PGDG's dev package matches the installed server version exactly (same ABI).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential git ca-certificates flex bison \
        libreadline-dev zlib1g-dev pkg-config \
        postgresql-server-dev-16 \
    && rm -rf /var/lib/apt/lists/*

# The base image's pg_config drives install prefix + server ABI. Build against it so
# the artifacts land in the right dirs and load into this exact PG16 server.
RUN PG_CONFIG="$(command -v pg_config)"; echo "Using pg_config: ${PG_CONFIG}"; "${PG_CONFIG}" --version

# --- Apache AGE (graph / openCypher) ---
RUN git clone --depth 1 --branch "${AGE_REF}" https://github.com/apache/age.git /tmp/age \
 && cd /tmp/age \
 && make PG_CONFIG="$(command -v pg_config)" \
 && make PG_CONFIG="$(command -v pg_config)" install

# --- pgmq (durable pub/sub queues) ---
# As of v1.4.x the pgmq extension is pure PL/pgSQL, built with plain PGXS — no Rust,
# no pgrx, no compiled .so. (The Rust code now lives in the separate pgmq-rs client
# crate.) A standard make + make install just stages the SQL and control files.
RUN git clone --depth 1 --branch "${PGMQ_REF}" https://github.com/tembo-io/pgmq.git /tmp/pgmq \
 && cd /tmp/pgmq/pgmq-extension \
 && make PG_CONFIG="$(command -v pg_config)" \
 && make PG_CONFIG="$(command -v pg_config)" install

# --- pgjwt (JWT sign/verify; pure SQL, depends on pgcrypto) ---
RUN git clone https://github.com/michelp/pgjwt.git /tmp/pgjwt \
 && cd /tmp/pgjwt \
 && git checkout "${PGJWT_REF}" \
 && make PG_CONFIG="$(command -v pg_config)" install

##############################################################################
# Stage 2 — final image
##############################################################################
FROM ${BASE_IMAGE}
LABEL org.opencontainers.image.title="PGEverything" \
      org.opencontainers.image.description="One Postgres for SQL, documents, graph, time-series, pub/sub, vectors, and key-value cache." \
      org.opencontainers.image.version="0.1.0"

# Copy compiled extension artifacts (AGE + pgmq) from the builder. The lib and
# extension dirs are the standard PG16 install locations on this base.
COPY --from=builder /usr/lib/postgresql/16/lib/ /usr/lib/postgresql/16/lib/
COPY --from=builder /usr/share/postgresql/16/extension/ /usr/share/postgresql/16/extension/

# pgcache — first-party Redis-style KV cache extension (pure SQL, no compile).
COPY extensions/pgcache/pgcache.control extensions/pgcache/pgcache--0.1.0.sql \
     /usr/share/postgresql/16/extension/

# pgauth — first-party JWT auth + RLS helper extension (pure SQL, no compile).
COPY extensions/pgauth/pgauth.control extensions/pgauth/pgauth--0.1.0.sql \
     /usr/share/postgresql/16/extension/

# Init scripts + config.
COPY rootfs/ /
