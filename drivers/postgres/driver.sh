#!/usr/bin/env bash
# drivers/postgres/driver.sh — PostgreSQL implementation of the locationDB driver interface.
#
# This file is sourced by populate.sh and sync.sh.
# It must NOT be executed directly.
#
# Expected environment variables (set by the orchestrator):
#   DRIVER_DIR   — absolute path to this driver's directory
#   DATABASE_URL — postgres connection string (optional, see below)
#
# Two ways to point this driver at a database:
#   1. Standard libpq variables — PGHOST, PGPORT, PGUSER, PGPASSWORD,
#      PGDATABASE, PGSERVICE, PGSSLMODE, ~/.pgpass, ~/.pg_service.conf.
#      Leave DATABASE_URL empty and psql picks them up itself.
#   2. A connection string via DATABASE_URL or --db-url.
# If both are given, DATABASE_URL wins.

# ---------------------------------------------------------------------------
# Interface implementation
# ---------------------------------------------------------------------------

# Human-readable name shown in log output
db_name() { echo "PostgreSQL"; }

# Verify required system tools are present
db_check_deps() {
  require_cmd "psql" "Install PostgreSQL client tools: https://www.postgresql.org/download/"
  require_cmd "curl" "Install curl to download GeoNames data."
  require_cmd "unzip"

  if [[ -n "${DATABASE_URL:-}" ]]; then
    log_info "Connecting via DATABASE_URL"
  elif [[ -n "${PGSERVICE:-}${PGHOST:-}${PGDATABASE:-}${PGUSER:-}" ]]; then
    log_info "Connecting via PG* environment variables (PGHOST=${PGHOST:-local socket}, PGDATABASE=${PGDATABASE:-$(id -un)})"
  else
    log_error "No PostgreSQL connection configured. Use either:"
    log_error "  1. PG* variables — export PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE"
    log_error "  2. A connection string — export DATABASE_URL or pass --db-url <postgres://user:pass@host/db>"
    exit 1
  fi
}

# Run psql against the configured target.
# With DATABASE_URL set, pass it explicitly; otherwise pass nothing and let
# psql resolve the connection from PG* / .pgpass / .pg_service.conf itself.
_pg() {
  if [[ -n "${DATABASE_URL:-}" ]]; then
    psql "$DATABASE_URL" "$@"
  else
    psql "$@"
  fi
}

# Create schema (staging tables + final output table + sync tracker)
db_init() {
  log_step "Creating schema..."
  _pg -v ON_ERROR_STOP=1 -f "$DRIVER_DIR/sql/01_schema.sql"
}

# Bulk-load raw GeoNames TSV files into staging tables
db_load() {
  log_step "Loading raw data..."
  _pg -v ON_ERROR_STOP=1 -f "$DRIVER_DIR/sql/02_load.sql"
}

# Flatten staging tables into the final geonames_cities table
db_flatten() {
  log_step "Flattening into final table..."
  _pg -v ON_ERROR_STOP=1 -f "$DRIVER_DIR/sql/03_flatten.sql"
}

# Postgres supports incremental daily sync
db_supports_sync() { return 0; }

# Apply a single day's GeoNames delta (modifications + deletions)
# Arguments: $1 = date string YYYY-MM-DD
# Note: only geonames_cities is delta-synced. geonames_states and
#       geonames_countries change a handful of times a year — re-run
#       populate.sh to refresh them.
db_sync() {
  local date="$1"

  # Check whether we are already up-to-date
  local last_sync
  last_sync=$(_pg -t -A -c \
    "SELECT COALESCE(
       (SELECT last_synced FROM sync_state WHERE name='cities1000'),
       '2025-09-15'
     );")

  if [[ "$last_sync" == "$date" ]]; then
    log_success "Already synced up to $date"
    return 0
  fi

  download_geonames_delta "$date"

  if [[ ! -s data/mods.txt && ! -s data/deletes.txt ]]; then
    log_info "No deltas available for $date — marking as synced."
    _pg_record_sync "$date"
    return 0
  fi

  log_step "Applying deltas..."

  # Apply deletions
  if [[ -s data/deletes.txt ]]; then
    log_info "Deleting removed rows from geonames_cities..."
    local ids
    ids=$(awk '{printf "%s,", $1}' data/deletes.txt | sed 's/,$//')
    _pg -c \
      "DELETE FROM geonames_cities
       WHERE geonameid IN (SELECT unnest(ARRAY[${ids}]::bigint[]));"
  fi

  # Upsert modifications
  if [[ -s data/mods.txt ]]; then
    log_info "Upserting modified rows into geonames_cities..."
    _pg -v ON_ERROR_STOP=1 <<EOF
      CREATE TEMP TABLE tmp_mods (
        geonameid       bigint,
        name            text,
        asciiname       text,
        alternatenames  text,
        latitude        double precision,
        longitude       double precision,
        feature_class   text,
        feature_code    text,
        country_code    text,
        cc2             text,
        admin1_code     text,
        admin2_code     text,
        admin3_code     text,
        admin4_code     text,
        population      bigint,
        elevation       int,
        dem             int,
        timezone        text,
        modification_date date
      );

      \copy tmp_mods FROM 'data/mods.txt' WITH (FORMAT text, DELIMITER E'\t', NULL '');

      INSERT INTO geonames_cities (
        city, region, state, country, latitude, longitude, population,
        alternate_city_names, timezone, country_code, state_code, geonameid
      )
      SELECT DISTINCT ON (m.geonameid)
        m.name,
        -- Resolve state and country names from the reference tables; fall back
        -- to the raw codes when GeoNames has no matching row. The delta feed
        -- carries no admin2 name, so region tracks the state here.
        COALESCE(s.state, m.admin1_code),
        COALESCE(s.state, m.admin1_code),
        COALESCE(o.country, m.country_code),
        m.latitude, m.longitude, m.population,
        COALESCE(string_to_array(NULLIF(m.alternatenames,''),','), ARRAY[]::text[]),
        m.timezone, m.country_code,
        m.country_code || '.' || m.admin1_code,
        m.geonameid
      FROM tmp_mods m
      LEFT JOIN geonames_states s
        ON s.code = m.country_code || '.' || m.admin1_code
      LEFT JOIN geonames_countries o
        ON o.country_code = m.country_code
      ORDER BY m.geonameid, m.modification_date DESC
      ON CONFLICT (geonameid) DO UPDATE SET
        city                 = EXCLUDED.city,
        state                = EXCLUDED.state,
        country              = EXCLUDED.country,
        timezone             = COALESCE(EXCLUDED.timezone, 'UTC'),
        population           = EXCLUDED.population,
        latitude             = EXCLUDED.latitude,
        longitude            = EXCLUDED.longitude,
        country_code         = EXCLUDED.country_code,
        alternate_city_names = COALESCE(EXCLUDED.alternate_city_names, ARRAY[]::text[]),
        -- ponytail: delta has no admin2, keep existing when resolved beyond state
        region               = CASE WHEN geonames_cities.region = geonames_cities.state
                                    THEN EXCLUDED.region
                                    ELSE geonames_cities.region END,
        state_code           = EXCLUDED.state_code,
        updated_at           = now();
EOF
  fi

  _pg_record_sync "$date"
  log_success "Sync complete (last_synced=$date)"
}

# ---------------------------------------------------------------------------
# Private helpers (prefix with _pg_ to avoid collisions across drivers)
# ---------------------------------------------------------------------------
_pg_record_sync() {
  _pg -c "
    INSERT INTO sync_state (name, last_synced)
    VALUES ('cities1000', DATE '$1')
    ON CONFLICT (name) DO UPDATE SET last_synced = EXCLUDED.last_synced;"
}
