#!/usr/bin/env bash
# lib/core.sh — Shared utilities for locationDB orchestrators.
# Source this file; do not execute it directly.

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()    { echo "ℹ️   $*"; }
log_success() { echo "✅  $*"; }
log_warn()    { echo "⚠️   $*" >&2; }
log_error()   { echo "❌  $*" >&2; }
log_step()    { echo ""; echo "▶   $*"; }

# ---------------------------------------------------------------------------
# Download and unpack GeoNames source files into ./data/
# ---------------------------------------------------------------------------
download_geonames_data() {
  log_step "Downloading GeoNames files..."
  mkdir -p data

  if [[ "${CACHE:-0}" -eq 1 ]] \
     && [[ -f data/cities1000.txt ]] \
     && [[ -f data/admin1CodesASCII.txt ]] \
     && [[ -f data/admin2Codes.txt ]] \
     && [[ -f data/countryInfo.txt ]]; then
    log_info "Cache hit — reusing downloaded files in ./data/"
    return 0
  fi

  (
    cd data
    curl -fsSL -O http://download.geonames.org/export/dump/cities1000.zip
    unzip -o cities1000.zip

    curl -fsSL -O http://download.geonames.org/export/dump/admin1CodesASCII.txt
    curl -fsSL -O http://download.geonames.org/export/dump/admin2Codes.txt

    # countryInfo.txt ships with a ~50-line licence/header comment block.
    # Strip it so the file is pure TSV and loadable by \copy / .import.
    curl -fsSL http://download.geonames.org/export/dump/countryInfo.txt \
      | grep -v '^#' > countryInfo.txt
  )
  log_success "GeoNames data ready in ./data/"
}

# ---------------------------------------------------------------------------
# Download only the daily delta files for a given date (YYYY-MM-DD)
# Outputs: data/mods.txt  data/deletes.txt  (may be empty)
# ---------------------------------------------------------------------------
download_geonames_delta() {
  local date="$1"
  log_step "Fetching GeoNames deltas for $date..."
  mkdir -p data
  : > data/mods.txt
  : > data/deletes.txt
  curl -fsSL "http://download.geonames.org/export/dump/modifications-${date}.txt" \
       -o data/mods.txt    || true
  curl -fsSL "http://download.geonames.org/export/dump/deletes-${date}.txt" \
       -o data/deletes.txt || true
}

# ---------------------------------------------------------------------------
# Remove the temporary data directory
# ---------------------------------------------------------------------------
cleanup() {
  rm -rf data
}

# ---------------------------------------------------------------------------
# Resolve yesterday's date portably (Linux + macOS)
# ---------------------------------------------------------------------------
yesterday() {
  if date --date="yesterday" +%F 2>/dev/null; then
    :   # GNU date (Linux)
  else
    date -u -v-1d +%F   # BSD date (macOS)
  fi
}

# ---------------------------------------------------------------------------
# Validate that a required binary is on PATH
# ---------------------------------------------------------------------------
require_cmd() {
  local cmd="$1"
  local hint="${2:-Please install '$cmd' and try again.}"
  if ! command -v "$cmd" &>/dev/null; then
    log_error "Required command not found: $cmd"
    log_error "$hint"
    exit 1
  fi
}
