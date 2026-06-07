# Geonames DB Sync Script

## Initial full import (as before)

TEST: `bash migrate.sh --test`

PROD: `export DATABASE_URL=...; ./migrate.sh`

## Daily incremental sync

TEST: `bash sync.sh --test`
PROD: `export DATABASE_URL=...; ./sync.sh`
