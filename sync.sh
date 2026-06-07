#!/usr/bin/env bash
# sync.sh — Apply daily GeoNames delta files (modifications + deletions).
#
# Sync support depends on the driver. SQLite users should re-run populate.sh.
#
# Usage
# -----
#   ./sync.sh --driver postgres --db-url "postgres://user:pass@host/db"
#   ./sync.sh --driver postgres --test    # start docker-compose automatically
#   ./sync.sh --help
#
# Environment variables
# ---------------------
#   DB_DRIVER      — backend name
#   DATABASE_URL   — postgres connection URL
#   SQLITE_DB_PATH — sqlite file path
#
# Adding a new backend
# --------------------
#   See drivers/ADDING_A_DRIVER.md — implement db_supports_sync and db_sync.
#   You never need to edit this file.

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
  exit 1
fi

export DRIVER_DIR DATABASE_URL SQLITE_PATH

# shellcheck disable=SC1090
source "$DRIVER_DIR/driver.sh"

# ---------------------------------------------------------------------------
# Test-mode bootstrap
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
# Check sync support
# ---------------------------------------------------------------------------
log_info "Driver : $(db_name)"

if ! db_supports_sync; then
  log_warn "$(db_name) does not support incremental sync."
  log_warn "Re-run populate.sh to refresh the database from scratch."
  exit 1
fi

db_check_deps

# ---------------------------------------------------------------------------
# Run sync for yesterday's delta
# ---------------------------------------------------------------------------
DATE=$(yesterday)
log_info "Syncing delta for: $DATE"

db_sync "$DATE"

cleanup