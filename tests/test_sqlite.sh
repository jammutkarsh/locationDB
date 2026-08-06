#!/usr/bin/env bash
# tests/test_sqlite.sh — Run the SQLite pipeline against tiny fixtures and
# assert that cities, states, countries and the `locations` view line up.
#
#   ./tests/test_sqlite.sh
#
# No network, no downloads: the fixtures below mimic the GeoNames TSV layout.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/lib/core.sh"

export DRIVER_DIR="$REPO_DIR/drivers/sqlite"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export SQLITE_PATH="$TMP_DIR/test.db"

# db_load reads relative paths under ./data
cd "$TMP_DIR"
mkdir -p data

# cities1000: geonameid name asciiname alternatenames lat lon fclass fcode cc
#             cc2 admin1 admin2 admin3 admin4 population elevation dem tz mod
printf '%s\n' \
  $'1275339\tMumbai\tMumbai\tBombay,Mumbai\t19.07283\t72.88261\tP\tPPLA\tIN\t\t16\t517\t\t\t12691836\t\t8\tAsia/Kolkata\t2019-09-15' \
  $'5128581\tNew York City\tNew York City\tNYC,New York\t40.71427\t-74.00597\tP\tPPL\tUS\t\tNY\t\t\t\t8804190\t\t10\tAmerica/New_York\t2023-03-01' \
  > data/cities1000.txt

printf '%s\n' \
  $'IN.16\tMaharashtra\tMaharashtra\t1264418' \
  $'US.NY\tNew York\tNew York\t5128638' \
  > data/admin1CodesASCII.txt

printf '%s\n' $'IN.16.517\tMumbai Suburban\tMumbai Suburban\t7778677' > data/admin2Codes.txt

# countryInfo: iso iso3 isonum fips country capital area pop continent tld
#              currency currencyname phone postalformat postalregex langs
#              geonameid neighbours equivfips
printf '%s\n' \
  $'IN\tIND\t356\tIN\tIndia\tNew Delhi\t3287590\t1352617328\tAS\t.in\tINR\tRupee\t91\t### ###\t^(\\d{6})$\ten-IN,hi\t1269750\tCN,BD,NP\t' \
  $'US\tUSA\t840\tUS\tUnited States\tWashington\t9629091\t327167434\tNA\t.us\tUSD\tDollar\t1\t#####-####\t^\\d{5}(-\\d{4})?$\ten-US,es-US\t6252001\tCA,MX,CU\t' \
  > data/countryInfo.txt

# shellcheck disable=SC1090
source "$DRIVER_DIR/driver.sh"
db_init
db_load
db_flatten

q() { sqlite3 "$SQLITE_PATH" "$1"; }

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    echo "FAIL: $3"
    echo "  expected: $2"
    echo "  actual  : $1"
    exit 1
  fi
}

assert_eq "$(q 'SELECT COUNT(*) FROM geonames_cities;')"    "2" "cities loaded"
assert_eq "$(q 'SELECT COUNT(*) FROM geonames_states;')"    "2" "states loaded"
assert_eq "$(q 'SELECT COUNT(*) FROM geonames_countries;')" "2" "countries loaded"

# The point of the feature: one row carries city + state + country names.
assert_eq "$(q "SELECT city || '|' || state || '|' || country || '|' || population
                FROM geonames_cities WHERE city = 'Mumbai';")" \
          "Mumbai|Maharashtra|India|12691836" "names resolved into geonames_cities"

# region keeps the finer admin2 name where GeoNames has one …
assert_eq "$(q "SELECT region FROM geonames_cities WHERE city = 'Mumbai';")" \
          "Mumbai Suburban" "region = admin2 name when present"

# … and falls back to the state when it does not (New York City has no admin2)
assert_eq "$(q "SELECT region || '|' || state FROM geonames_cities WHERE city = 'New York City';")" \
          "New York|New York" "region = state when GeoNames has no admin2"

assert_eq "$(q "SELECT city || '|' || region || '|' || state || '|' || country
                     || '|' || latitude || '|' || longitude || '|' || population
                     || '|' || alternate_names
                FROM locations WHERE city = 'Mumbai';")" \
          "Mumbai|Mumbai Suburban|Maharashtra|India|19.07283|72.88261|12691836|Bombay,Mumbai" \
          "locations exposes the simple column set"

assert_eq "$(q "SELECT state_code FROM geonames_cities WHERE city = 'New York City';")" \
          "US.NY" "state_code built from country_code + admin1_code"

assert_eq "$(q "SELECT country || '|' || state FROM locations WHERE city = 'New York City';")" \
          "United States|New York" "country name resolved, not just the ISO code"

# FTS5 still finds cities by alternate name, and the view joins onto it.
assert_eq "$(q "SELECT l.city FROM locations l
                JOIN geonames_cities_fts f ON f.rowid = l.id
                WHERE geonames_cities_fts MATCH 'bombay';")" \
          "Mumbai" "FTS5 alternate-name search"

# Staging tables must not survive the import.
assert_eq "$(q "SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name IN ('cities1000','admin1Codes','admin2Codes','admin5Codes');")" \
          "0" "staging tables dropped after flatten"

# geonames_states content
assert_eq "$(q "SELECT state FROM geonames_states WHERE code = 'IN.16';")" \
          "Maharashtra" "geonames_states resolves state name"

assert_eq "$(q "SELECT country_code FROM geonames_states WHERE code = 'US.NY';")" \
          "US" "geonames_states carries country_code"

# geonames_countries content
assert_eq "$(q "SELECT country || '|' || capital || '|' || continent FROM geonames_countries WHERE country_code = 'IN';")" \
          "India|New Delhi|AS" "geonames_countries resolves country name"

assert_eq "$(q "SELECT iso3 || '|' || currency_code FROM geonames_countries WHERE country_code = 'US';")" \
          "USA|USD" "geonames_countries iso3 and currency"

# JOIN cities to states via state_code
assert_eq "$(q "SELECT s.state FROM geonames_cities c
                JOIN geonames_states s ON s.code = c.state_code
                WHERE c.city = 'Mumbai';")" \
          "Maharashtra" "geonames_cities JOIN geonames_states via state_code"

# Trigram index for typo-tolerant search
assert_eq "$(q "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='geonames_trigrams';")" \
          "1" "geonames_trigrams table exists"
assert_eq "$(q "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='idx_trigram_lookup';")" \
          "1" "trigram index exists"

TRIGRAM_COUNT=$(q 'SELECT COUNT(*) FROM geonames_trigrams;')
if [[ "$TRIGRAM_COUNT" -lt 15 ]]; then
  echo "FAIL: expected >=15 trigrams for 2 test cities, got $TRIGRAM_COUNT"
  exit 1
fi
# Spot-check known trigrams
assert_eq "$(q "SELECT COUNT(*) FROM geonames_trigrams WHERE city_id=1 AND trigram='mum';")" \
          "1" "trigram 'mum' for Mumbai"
assert_eq "$(q "SELECT COUNT(*) FROM geonames_trigrams WHERE city_id=1 AND trigram='bom';")" \
          "1" "trigram 'bom' for Mumbai (from alt Bombay)"
assert_eq "$(q "SELECT COUNT(*) FROM geonames_trigrams WHERE city_id=2 AND trigram='new';")" \
          "1" "trigram 'new' for New York City"
assert_eq "$(q "SELECT COUNT(*) FROM geonames_trigrams WHERE city_id=2 AND trigram='nyc';")" \
          "1" "trigram 'nyc' for New York City (from alt NYC)"

# --cache: cleanup must be skippable so downloaded Geonames files survive.
# Simulate a fresh data/ dir (the real cleanup deleted the one from db_load).
mkdir -p data && touch data/testfile.txt
cleanup
if [[ -d data ]]; then
  echo "FAIL: cleanup should remove data/"
  exit 1
fi

# With CACHE=1, the gate skips cleanup.
mkdir -p data && touch data/testfile.txt
CACHE=1
if [[ "$CACHE" -ne 1 ]]; then cleanup; fi   # skip cleanup when CACHE=1
if [[ ! -f data/testfile.txt ]]; then
  echo "FAIL: --cache should preserve data/ (CACHE=1 skips cleanup)"
  exit 1
fi
rm -rf data

echo "PASS: all checks green"
