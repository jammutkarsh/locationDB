#!/usr/bin/env bash
set -euo pipefail

# Parse --test flag
TEST_MODE=0
for arg in "$@"; do
    if [ "$arg" = "--test" ]; then
        TEST_MODE=1
    fi
done

if [ "$TEST_MODE" -eq 1 ]; then
    echo "🧪 Test mode: starting docker-compose..."
    docker-compose up -d
    sleep 5
    DB_URL="postgres://root:m23e65to@localhost:5432/account_service?sslmode=disable"
else
    DB_URL="${DATABASE_URL:?Please export DATABASE_URL=postgres://user:pass@host/db}"
fi

STATE_LESS_CITIES_COUNT="$INIT_COUNT"

echo "📥 Downloading Geonames files..."
mkdir -p data
cd data

# Cities
curl -s -O http://download.geonames.org/export/dump/cities15000.zip
unzip -o cities15000.zip

# Admin codes
curl -s -O http://download.geonames.org/export/dump/admin1CodesASCII.txt
curl -s -O http://download.geonames.org/export/dump/admin2Codes.txt
curl -s -O http://download.geonames.org/export/dump/adminCode5.zip
unzip -o adminCode5.zip

cd ..

echo "🛠 Running schema..."
psql "$DB_URL" -f sql/01_schema.sql

echo "📂 Loading raw data..."
psql "$DB_URL" -f sql/02_load.sql

echo "🔍 Validating admin code mappings..."
UNMAPPED_COUNT=$(psql "$DB_URL" -t -A -f sql/03_validate.sql)

if [ "$UNMAPPED_COUNT" -gt "$STATE_LESS_CITIES_COUNT" ]; then
    echo "❌ Validation failed: $UNMAPPED_COUNT unmapped cities"
    exit 1
else
    echo "✅ Validation passed: all cities mapped"
fi

echo "📦 Flattening into final table..."
psql "$DB_URL" -f sql/04_flatten.sql

rm -rf data

echo "🎉 Import completed successfully!"
