#!/usr/bin/env bash
# drivers/postgres/driver.sh — PostgreSQL implementation of the locationDB driver interface.
#
# This file is sourced by populate.sh and sync.sh.
# It must NOT be executed directly.
#
# Expected environment variables (set by the orchestrator):
#   DRIVER_DIR   — absolute path to this driver's directory
#   DATABASE_URL — postgres connection string

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

  if [[ -z "${DATABASE_URL:-}" ]]; then
    log_error "DATABASE_URL is not set."
    log_error "Export it or pass --db-url <postgres://user:pass@host/db>"
    exit 1
  fi
}

# Create schema (staging tables + final output table + sync tracker)
db_init() {
  log_step "Creating schema..."
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$DRIVER_DIR/sql/01_schema.sql"
}

# Bulk-load raw GeoNames TSV files into staging tables
db_load() {
  log_step "Loading raw data..."
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$DRIVER_DIR/sql/02_load.sql"
}

# Flatten staging tables into the final geonames_cities table
db_flatten() {
  log_step "Flattening into final table..."
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$DRIVER_DIR/sql/03_flatten.sql"
}

# Postgres supports incremental daily sync
db_supports_sync() { return 0; }

# Apply a single day's GeoNames delta (modifications + deletions)
# Arguments: $1 = date string YYYY-MM-DD
db_sync() {
  local date="$1"

  # Check whether we are already up-to-date
  local last_sync
  last_sync=$(psql "$DATABASE_URL" -t -A -c \
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
    psql "$DATABASE_URL" -c \
      "DELETE FROM geonames_cities
       WHERE geonameid IN (SELECT unnest(ARRAY[${ids}]::bigint[]));"
  fi

  # Upsert modifications
  if [[ -s data/mods.txt ]]; then
    log_info "Upserting modified rows into geonames_cities..."
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 <<EOF
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
        geonameid, city, country, timezone, population,
        latitude, longitude, country_code, alternate_city_names, region
      )
      SELECT DISTINCT ON (geonameid)
        geonameid, name, country_code, timezone, population,
        latitude, longitude, country_code,
        COALESCE(string_to_array(NULLIF(alternatenames,''),','), ARRAY[]::text[]),
        admin1_code
      FROM tmp_mods
      ORDER BY geonameid, modification_date DESC
      ON CONFLICT (geonameid) DO UPDATE SET
        city                 = EXCLUDED.city,
        country              = EXCLUDED.country,
        timezone             = COALESCE(EXCLUDED.timezone, 'UTC'),
        population           = EXCLUDED.population,
        latitude             = EXCLUDED.latitude,
        longitude            = EXCLUDED.longitude,
        country_code         = EXCLUDED.country_code,
        alternate_city_names = COALESCE(EXCLUDED.alternate_city_names, ARRAY[]::text[]),
        region               = EXCLUDED.region,
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
  psql "$DATABASE_URL" -c "
    INSERT INTO sync_state (name, last_synced)
    VALUES ('cities1000', DATE '$1')
    ON CONFLICT (name) DO UPDATE SET last_synced = EXCLUDED.last_synced;"
}
