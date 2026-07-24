#!/usr/bin/env bash
# drivers/mysql/driver.sh — MySQL implementation of the locationDB driver interface.
#
# This file is sourced by populate.sh and sync.sh.
# It must NOT be executed directly.
#
# Expected environment variables (set by the orchestrator):
#   DRIVER_DIR   — absolute path to this driver's directory
#   DATABASE_URL — mysql connection string (optional, see below)
#
# Two ways to point this driver at a database:
#   1. Standard MYSQL_* variables — MYSQL_HOST, MYSQL_PORT, MYSQL_USER,
#      MYSQL_PASSWORD, MYSQL_DATABASE.
#      Leave DATABASE_URL empty and the mysql CLI picks them up.
#   2. A connection string via DATABASE_URL or --db-url:
#      mysql://user:pass@host:port/dbname
# If both are given, DATABASE_URL wins.

# ---------------------------------------------------------------------------
# Interface implementation
# ---------------------------------------------------------------------------

db_name() { echo "MySQL"; }

db_check_deps() {
  require_cmd "mysql" "Install MySQL client tools."
  require_cmd "curl" "Install curl to download GeoNames data."
  require_cmd "unzip"
  require_cmd "awk"   # needed for URL parsing

  if [[ -n "${DATABASE_URL:-}" ]]; then
    log_info "Connecting via DATABASE_URL"
  elif [[ -n "${MYSQL_HOST:-}${MYSQL_USER:-}${MYSQL_DATABASE:-}" ]]; then
    log_info "Connecting via MYSQL_* environment variables"
  else
    log_error "No MySQL connection configured. Use either:"
    log_error "  1. MYSQL_* variables — export MYSQL_HOST/MYSQL_USER/MYSQL_PASSWORD/MYSQL_DATABASE"
    log_error "  2. A connection string — export DATABASE_URL or pass --db-url <mysql://user:pass@host:port/db>"
    exit 1
  fi
}

# Run mysql against the configured target.
# With DATABASE_URL set, parse it into CLI args;
# otherwise let the mysql CLI resolve from MYSQL_* env vars / ~/.my.cnf.
_my() {
  if [[ -n "${DATABASE_URL:-}" ]]; then
    local url="${DATABASE_URL}"
    # strip mysql:// prefix
    local rest="${url#mysql://}"
    # user:pass@host:port/db  or  user:pass@host/db  or  user@host/db
    local user_pass host_port_db host_port db
    user_pass="${rest%%@*}"
    host_port_db="${rest#*@}"
    db="${host_port_db##*/}"
    host_port="${host_port_db%/*}"
    local user pass host port
    user="${user_pass%%:*}"
    pass="${user_pass#*:}"
    [[ "$pass" == "$user" ]] && pass=""

    if [[ "$host_port" == *:* ]]; then
      host="${host_port%:*}"
      port="${host_port##*:}"
    else
      host="$host_port"
      port=""
    fi

    local args=(--local-infile=1 -h "$host" -D "$db")
    [[ -n "$user" ]] && args+=(-u "$user")
    [[ -n "$pass" ]] && args+=("-p$pass")
    [[ -n "$port" ]] && args+=(-P "$port")
    mysql "${args[@]}" "$@"
  else
    mysql --local-infile=1 "$@"
  fi
}

# Create schema (staging tables + final output table + sync tracker)
db_init() {
  log_step "Creating schema..."
  _my < "$DRIVER_DIR/sql/01_schema.sql"
}

# Bulk-load raw GeoNames TSV files into staging tables
db_load() {
  log_step "Loading raw data..."
  _my < "$DRIVER_DIR/sql/02_load.sql"
}

# Flatten staging tables into the final geonames_cities table
db_flatten() {
  log_step "Flattening into final table..."
  _my < "$DRIVER_DIR/sql/03_flatten.sql"
}

# MySQL supports incremental daily sync
db_supports_sync() { return 0; }

# Apply a single day's GeoNames delta (modifications + deletions)
db_sync() {
  local date="$1"

  # Check whether we are already up-to-date
  local last_sync
  last_sync=$(_my -N -B -e \
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
    _my_record_sync "$date"
    return 0
  fi

  log_step "Applying deltas..."

  # Apply deletions
  if [[ -s data/deletes.txt ]]; then
    log_info "Deleting removed rows from geonames_cities..."
    local ids
    ids=$(awk '{printf "%s,", $1}' data/deletes.txt | sed 's/,$//')
    _my -e \
      "DELETE FROM geonames_cities
       WHERE geonameid IN (${ids});"
  fi

  # Upsert modifications
  if [[ -s data/mods.txt ]]; then
    log_info "Upserting modified rows into geonames_cities..."
    _my <<EOF
      CREATE TEMPORARY TABLE tmp_mods (
        geonameid       BIGINT,
        name            TEXT,
        asciiname       TEXT,
        alternatenames  TEXT,
        latitude        DOUBLE,
        longitude       DOUBLE,
        feature_class   TEXT,
        feature_code    TEXT,
        country_code    TEXT,
        cc2             TEXT,
        admin1_code     TEXT,
        admin2_code     TEXT,
        admin3_code     TEXT,
        admin4_code     TEXT,
        population      BIGINT,
        elevation       INT,
        dem             INT,
        timezone        TEXT,
        modification_date DATE
      );

      LOAD DATA LOCAL INFILE 'data/mods.txt'
      INTO TABLE tmp_mods
      CHARACTER SET utf8mb4
      FIELDS TERMINATED BY '\t' ESCAPED BY '\\\\'
      LINES TERMINATED BY '\n';

      INSERT INTO geonames_cities (
        city, region, state, country, latitude, longitude, population,
        alternate_city_names, timezone, country_code, state_code, geonameid
      )
      SELECT
        m.name,
        COALESCE(s.state, m.admin1_code),
        COALESCE(s.state, m.admin1_code),
        COALESCE(o.country, m.country_code),
        m.latitude, m.longitude, m.population,
        NULLIF(m.alternatenames, ''),
        m.timezone, m.country_code,
        CONCAT(m.country_code, '.', m.admin1_code),
        m.geonameid
      FROM tmp_mods m
      LEFT JOIN geonames_states s
        ON s.code = CONCAT(m.country_code, '.', m.admin1_code)
      LEFT JOIN geonames_countries o
        ON o.country_code = m.country_code
      WHERE m.geonameid NOT IN (
        SELECT m2.geonameid FROM tmp_mods m2
        WHERE m2.geonameid = m.geonameid AND m2.modification_date > m.modification_date
      )
      ON DUPLICATE KEY UPDATE
        city                 = VALUES(city),
        state                = VALUES(state),
        country              = VALUES(country),
        timezone             = COALESCE(VALUES(timezone), 'UTC'),
        population           = VALUES(population),
        latitude             = VALUES(latitude),
        longitude            = VALUES(longitude),
        country_code         = VALUES(country_code),
        alternate_city_names = COALESCE(VALUES(alternate_city_names), ''),
        region               = CASE WHEN geonames_cities.region = geonames_cities.state
                                    THEN VALUES(region)
                                    ELSE geonames_cities.region END,
        state_code           = VALUES(state_code),
        updated_at           = CURRENT_TIMESTAMP;

      DROP TEMPORARY TABLE tmp_mods;
EOF
  fi

  _my_record_sync "$date"
  log_success "Sync complete (last_synced=$date)"
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------
_my_record_sync() {
  _my -e "
    INSERT INTO sync_state (name, last_synced)
    VALUES ('cities1000', DATE '$1')
    ON DUPLICATE KEY UPDATE last_synced = VALUES(last_synced);"
}
