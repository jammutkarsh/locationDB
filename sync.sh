#!/usr/bin/env bash
set -euo pipefail

TEST_MODE=0
for arg in "$@"; do
  if [ "$arg" = "--test" ]; then TEST_MODE=1; fi
done

if [ "$TEST_MODE" -eq 1 ]; then
  echo "🧪 Test mode: starting docker-compose..."
  docker-compose up -d
  sleep 5
fi

DB_URL="postgres://root:m23e65to@localhost:5432/account_service?sslmode=disable"

mkdir -p data
: > data/mods.txt
: > data/deletes.txt

LAST_SYNC=$(psql "$DB_URL" -t -A -c "SELECT COALESCE((SELECT last_synced FROM sync_state WHERE name='cities1000'),'2025-09-15');")

YESTERDAY=$(date --date="yesterday" +%F)
# YESTERDAY=$(date -u -v-1d +%F)

if [[ "$LAST_SYNC" == "$YESTERDAY" ]]; then
  echo "✅ Already synced up to yesterday ($LAST_SYNC)"
  rm -rf data
  exit 0
fi

echo "⬇️  Fetching GeoNames deltas for $YESTERDAY..."
MOD_URL="http://download.geonames.org/export/dump/modifications-$YESTERDAY.txt"
DEL_URL="http://download.geonames.org/export/dump/deletes-$YESTERDAY.txt"

curl -fsSL "$MOD_URL" -o data/mods.txt || true
curl -fsSL "$DEL_URL" -o data/deletes.txt || true

if [[ ! -s data/mods.txt && ! -s data/deletes.txt ]]; then
  echo "ℹ️  No deltas to apply for $YESTERDAY."
  psql "$DB_URL" -c "INSERT INTO sync_state(name,last_synced) VALUES ('cities1000', DATE '$YESTERDAY')
                     ON CONFLICT (name) DO UPDATE SET last_synced = EXCLUDED.last_synced;"
  exit 0
fi

echo "🛠 Applying deltas..."

# Apply deletions to geonames_cities
if [[ -s data/deletes.txt ]]; then
  echo "  ⛔ Deleting rows from geonames_cities..."
  awk '{print $1}' data/deletes.txt | psql "$DB_URL" -v ON_ERROR_STOP=1 -qAtc "COPY (SELECT 1) FROM STDIN;" >/dev/null 2>&1
  psql "$DB_URL" -c "DELETE FROM geonames_cities WHERE geonameid IN (SELECT geonameid FROM (SELECT unnest(ARRAY[$(awk '{printf "%s,", $1}' data/deletes.txt | sed 's/,$//')])::bigint AS geonameid) AS t);"
fi

# Apply modifications to geonames_cities
if [[ -s data/mods.txt ]]; then
  echo "  ✏️  Upserting rows into geonames_cities..."
  # Prepare a temp table for modifications
  psql "$DB_URL" -c "
    CREATE TABLE IF NOT EXISTS tmp_mods(
      geonameid bigint,
      name text,
      asciiname text,
      alternatenames text,
      latitude double precision,
      longitude double precision,
      feature_class text,
      feature_code text,
      country_code text,
      cc2 text,
      admin1_code text,
      admin2_code text,
      admin3_code text,
      admin4_code text,
      population bigint,
      elevation int,
      dem int,
      timezone text,
      modification_date date
    );"
    psql "$DB_URL" -c "\copy tmp_mods (geonameid, name, asciiname, alternatenames, latitude, longitude, feature_class, feature_code, country_code, cc2, admin1_code, admin2_code, admin3_code, admin4_code, population, elevation, dem, timezone, modification_date) FROM 'data/mods.txt' WITH (FORMAT text, DELIMITER E'\t', NULL '');"

    psql "$DB_URL" -c "INSERT INTO geonames_cities (
      geonameid, city, country, timezone, population, latitude, longitude, country_code, alternate_city_names, region
    )
    SELECT DISTINCT ON (geonameid)
      geonameid, name AS city, country_code AS country, timezone, population, latitude, longitude, country_code, 
      COALESCE(string_to_array(NULLIF(alternatenames, ''), ','), ARRAY[]::text[]) AS alternate_city_names, admin1_code AS region
    FROM tmp_mods v
    ORDER BY geonameid, modification_date DESC
    ON CONFLICT (geonameid) DO UPDATE SET
      city = EXCLUDED.city,
      country = EXCLUDED.country,
      timezone = COALESCE(EXCLUDED.timezone, 'UTC'),
      population = EXCLUDED.population,
      latitude = EXCLUDED.latitude,
      longitude = EXCLUDED.longitude,
      country_code = EXCLUDED.country_code,
      alternate_city_names = COALESCE(EXCLUDED.alternate_city_names, ARRAY[]::text[]),
      region = EXCLUDED.region;"
      
      psql "$DB_URL" -c "DROP TABLE tmp_mods;"
fi

psql "$DB_URL" -c "INSERT INTO sync_state(name,last_synced) VALUES ('cities1000', DATE '$YESTERDAY')
                   ON CONFLICT (name) DO UPDATE SET last_synced = EXCLUDED.last_synced;"

echo "🎉 Sync completed (last_synced=$YESTERDAY)"

rm -rf data