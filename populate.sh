#!/usr/bin/env bash
# populate.sh — Download GeoNames data and populate a database.
#
# The database backend is selected via --driver (or DB_DRIVER env var).
# Each backend is a self-contained plugin in drivers/<name>/driver.sh.
#
# Usage
# -----
#   ./populate.sh --driver sqlite --db-path ./locationdb.db
#   ./populate.sh --driver postgres --db-url "postgres://user:pass@host/db"
#   ./populate.sh --driver postgres --test    # start docker-compose automatically
#   ./populate.sh --help
#
# Environment variables
# ---------------------
#   DB_DRIVER       — backend name (postgres | sqlite | ...)
#   DATABASE_URL    — postgres connection URL
#   SQLITE_DB_PATH  — sqlite file path  (default: ./locationdb.db)
#
# Adding a new backend
# --------------------
#   See drivers/ADDING_A_DRIVER.md — you never need to edit this file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Load shared utilities
# ---------------------------------------------------------------------------
# shellcheck source=lib/core.sh
source "$SCRIPT_DIR/lib/core.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DRIVER="${DB_DRIVER:-}"
DATABASE_URL="${DATABASE_URL:-}"
SQLITE_PATH="${SQLITE_DB_PATH:-./locationdb.db}"
TEST_MODE=0

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --driver)  DRIVER="$2";       shift 2 ;;
    --db-url)  DATABASE_URL="$2"; shift 2 ;;
    --db-path) SQLITE_PATH="$2";  shift 2 ;;
    --test)    TEST_MODE=1;       shift   ;;
    -h|--help) usage ;;
    *) log_error "Unknown flag: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate and resolve driver
# ---------------------------------------------------------------------------
if [[ -z "$DRIVER" ]]; then
  log_error "No driver specified."
  log_error "Use --driver <name> or export DB_DRIVER=<name>"
  log_error "Available drivers: $(ls "$SCRIPT_DIR/drivers" | grep -v '\.md' | tr '\n' ' ')"
  exit 1
fi

DRIVER_DIR="$SCRIPT_DIR/drivers/$DRIVER"

if [[ ! -f "$DRIVER_DIR/driver.sh" ]]; then
  log_error "Driver '$DRIVER' not found (expected: $DRIVER_DIR/driver.sh)"
  log_error "Available drivers: $(ls "$SCRIPT_DIR/drivers" | grep -v '\.md' | tr '\n' ' ')"
  log_error "See drivers/ADDING_A_DRIVER.md to create a new one."
  exit 1
fi

# Export so driver.sh can read them
export DRIVER_DIR DATABASE_URL SQLITE_PATH

# Source the driver — loads db_name, db_check_deps, db_init, db_load,
#                     db_flatten, db_supports_sync, db_sync
# shellcheck disable=SC1090
source "$DRIVER_DIR/driver.sh"

# ---------------------------------------------------------------------------
# Test-mode bootstrap (postgres only, but drivers may override this behaviour)
# ---------------------------------------------------------------------------
if [[ "$TEST_MODE" -eq 1 ]]; then
  log_info "Test mode: starting docker-compose..."
  POSTGRES_USER="${POSTGRES_USER:-locationdb_user}" \
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-changeme}" \
  POSTGRES_DB="${POSTGRES_DB:-locationdb}" \
  docker-compose -f "$SCRIPT_DIR/docker-compose.yaml" up -d
  sleep 5
  if [[ -z "$DATABASE_URL" ]]; then
    PG_USER="${POSTGRES_USER:-locationdb_user}"
    PG_PASS="${POSTGRES_PASSWORD:-changeme}"
    PG_DB="${POSTGRES_DB:-locationdb}"
    PG_PORT="${POSTGRES_PORT:-5432}"
    DATABASE_URL="postgres://${PG_USER}:${PG_PASS}@localhost:${PG_PORT}/${PG_DB}?sslmode=disable"
    export DATABASE_URL
  fi
fi

# ---------------------------------------------------------------------------
# Run pipeline
# ---------------------------------------------------------------------------
log_info "Driver : $(db_name)"

db_check_deps
download_geonames_data
db_init
db_load
db_flatten
cleanup

echo ""
log_success "Import complete!"
