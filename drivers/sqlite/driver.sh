#!/usr/bin/env bash
# drivers/sqlite/driver.sh — SQLite implementation of the locationDB driver interface.
#
# This file is sourced by populate.sh and sync.sh.
# It must NOT be executed directly.
#
# Expected environment variables (set by the orchestrator):
#   DRIVER_DIR   — absolute path to this driver's directory
#   SQLITE_PATH  — path to the .db file (will be created if absent)

# ---------------------------------------------------------------------------
# Interface implementation
# ---------------------------------------------------------------------------

# Human-readable name shown in log output
db_name() { echo "SQLite"; }

# Verify required system tools are present
db_check_deps() {
  require_cmd "sqlite3" "Install SQLite3: https://www.sqlite.org/download.html"
  require_cmd "curl"    "Install curl to download GeoNames data."
  require_cmd "unzip"

  if [[ -z "${SQLITE_PATH:-}" ]]; then
    log_error "SQLITE_PATH is not set."
    log_error "Export SQLITE_DB_PATH or pass --db-path <file.db>"
    exit 1
  fi
}

# Create schema (all tables + indexes)
db_init() {
  log_step "Creating schema..."
  sqlite3 "$SQLITE_PATH" < "$DRIVER_DIR/sql/01_schema.sql"
}

# Bulk-load raw GeoNames TSV files using sqlite3 .import
# sqlite3 has no \copy equivalent, so we drive it from the shell.
db_load() {
  log_step "Loading raw data..."
  _sqlite_import "data/cities1000.txt"       "cities1000"
  _sqlite_import "data/admin1CodesASCII.txt" "admin1Codes"
  _sqlite_import "data/admin2Codes.txt"      "admin2Codes"
  _sqlite_import "data/adminCode5.txt"       "admin5Codes"
}

# Flatten staging tables into the final geonames_cities table
db_flatten() {
  log_step "Flattening into final table..."
  sqlite3 "$SQLITE_PATH" < "$DRIVER_DIR/sql/03_flatten.sql"
}

# SQLite does not support incremental sync
db_supports_sync() { return 1; }

# Called when the user tries to run sync against SQLite
db_sync() {
  log_warn "Incremental sync is not supported for SQLite."
  log_warn "Re-run populate.sh to refresh the database from scratch."
  exit 1
}

# ---------------------------------------------------------------------------
# Private helpers (prefix with _sqlite_ to avoid collisions across drivers)
# ---------------------------------------------------------------------------
_sqlite_import() {
  local file="$1"
  local table="$2"
  sqlite3 "$SQLITE_PATH" <<EOF
.separator "\t"
.import ${file} ${table}
EOF
}
