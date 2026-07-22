#!/usr/bin/env bash
# PGEverything — optional PostGIS (geospatial).
# Binaries already ship in the Timescale base, so enabling is just CREATE EXTENSION.
# Gated on the PGE_ENABLE_POSTGIS env flag (default: false).
set -euo pipefail

if [ "${PGE_ENABLE_POSTGIS:-false}" = "true" ]; then
  echo "PGE_ENABLE_POSTGIS=true → enabling PostGIS"
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<-'SQL'
    CREATE EXTENSION IF NOT EXISTS postgis;
    CREATE EXTENSION IF NOT EXISTS postgis_topology;
SQL
else
  echo "PGE_ENABLE_POSTGIS not set → skipping PostGIS"
fi
