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
  DB_URL="postgres://root:m23e65to@localhost:5432/account_service?sslmode=disable"
else
  DB_URL="${DATABASE_URL:?Please export DATABASE_URL=postgres://user:pass@host/db}"
fi

mkdir -p data
: > data/mods.txt
: > data/deletes.txt

LAST_SYNC=$(psql "$DB_URL" -t -A -c "SELECT COALESCE((SELECT last_synced FROM sync_state WHERE name='cities1000'),'2025-09-18');")

YESTERDAY=$(date -u -v-1d +%F)

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
psql "$DB_URL" -f sql/05_apply_sync.sql

echo "📦 Refreshing flattened table..."
psql "$DB_URL" -f sql/04_flatten.sql

psql "$DB_URL" -c "INSERT INTO sync_state(name,last_synced) VALUES ('cities1000', DATE '$YESTERDAY')
                   ON CONFLICT (name) DO UPDATE SET last_synced = EXCLUDED.last_synced;"

echo "🎉 Sync completed (last_synced=$YESTERDAY)"

rm -rf data