# locationDB

A script that downloads the public [GeoNames](https://www.geonames.org/) dataset
and loads it into a local database — ready to query by city name, country, state,
or geographic coordinates.

Supports **PostgreSQL** and **SQLite** out of the box. Adding a new backend
requires only a single driver file; the orchestrator scripts never need to change.

---

## Data source

All geographic data is sourced from **[GeoNames](https://www.geonames.org/)**,
a free geographical database covering all countries and containing over 11 million
place names.

- Website: <https://www.geonames.org/>
- Data licence: [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/)
- Files used:
  - [`cities1000.zip`](https://download.geonames.org/export/dump/cities1000.zip) — all cities with population ≥ 1000
  - [`admin1CodesASCII.txt`](https://download.geonames.org/export/dump/admin1CodesASCII.txt) — first-level admin divisions (states / provinces)
  - [`admin2Codes.txt`](https://download.geonames.org/export/dump/admin2Codes.txt) — second-level admin divisions (counties / districts)
  - [`adminCode5.zip`](https://download.geonames.org/export/dump/adminCode5.zip) — fifth-level admin codes

> **Attribution requirement:** If you use this data in a public product, your
> app or docs must visibly credit GeoNames per the CC BY 4.0 licence, e.g.:
> *"Geographic data © [GeoNames](https://www.geonames.org/), CC BY 4.0"*

---

## Requirements

| Tool | SQLite | PostgreSQL |
|---|---|---|
| `curl` | ✅ | ✅ |
| `unzip` | ✅ | ✅ |
| `sqlite3` | ✅ | — |
| `psql` (PostgreSQL client) | — | ✅ |
| Docker + `docker-compose` | — | only for `--test` mode |

---

## Quick start

### 1 — Clone and configure

```bash
git clone https://github.com/jammutkarsh/locationDB
cd locationDB
cp .env.example .env
# Edit .env — set DB_DRIVER and the matching connection option
```

### 2 — Populate the database

#### SQLite (simplest — no server needed)

```bash
./populate.sh --driver sqlite --db-path ./locationdb.db
```

The `.db` file is created automatically if it doesn't exist.

#### PostgreSQL — remote server

```bash
./populate.sh --driver postgres \
  --db-url "postgres://user:pass@host:5432/dbname?sslmode=disable"
```

#### PostgreSQL — local test server (docker-compose)

```bash
./populate.sh --driver postgres --test
# Starts a Postgres container, runs the import, leaves the container running.
```

#### Using environment variables instead of flags

```bash
export DB_DRIVER=sqlite
export SQLITE_DB_PATH=./locationdb.db
./populate.sh
```

---

## Daily incremental sync

Keeps the database up-to-date with GeoNames' daily modification and deletion
feeds. **PostgreSQL only** — SQLite users re-run `populate.sh`.

```bash
# Remote server
./sync.sh --driver postgres \
  --db-url "postgres://user:pass@host:5432/dbname?sslmode=disable"

# Local test server
./sync.sh --driver postgres --test

# Via env vars
export DB_DRIVER=postgres
export DATABASE_URL="postgres://user:pass@host:5432/dbname?sslmode=disable"
./sync.sh
```

Schedule this as a daily cron job:

```cron
0 3 * * * cd /path/to/locationDB && ./sync.sh --driver postgres >> /var/log/locationdb-sync.log 2>&1
```

---

## Output table

Both backends produce a `geonames_cities` table with the same columns:

| Column | Type | Description |
|---|---|---|
| `id` | integer | Auto-generated primary key |
| `geonameid` | integer | Unique GeoNames identifier |
| `city` | text | City name (English) |
| `country` | text | ISO-3166 country code |
| `country_code` | text | ISO-3166 country code (same as `country`) |
| `region` | text | State / province / first-level admin division |
| `timezone` | text | IANA timezone string (e.g. `Asia/Kolkata`) |
| `population` | integer | Population count |
| `latitude` | numeric | Decimal degrees |
| `longitude` | numeric | Decimal degrees |
| `alternate_city_names` | text[] / text | Other names / transliterations (Postgres: array; SQLite: comma-separated) |
| `inserted_at` | timestamp | Row creation time |
| `updated_at` | timestamp | Last modification time |

---

## Query examples

### City name — exact match

```sql
-- PostgreSQL
SELECT * FROM geonames_cities WHERE LOWER(city) = LOWER('Mumbai');

-- SQLite
SELECT * FROM geonames_cities WHERE city = 'Mumbai' COLLATE NOCASE;
```

### City name — fuzzy / partial (PostgreSQL)

```sql
-- Uses the pg_trgm GIN index automatically
SELECT * FROM geonames_cities WHERE city ILIKE '%bom%' ORDER BY population DESC;

-- Or ranked similarity
SELECT *, similarity(city, 'Bombay') AS score
FROM geonames_cities
WHERE similarity(city, 'Bombay') > 0.3
ORDER BY score DESC;
```

### City name — full-text search (SQLite)

```sql
-- Prefix search (fast, uses FTS5 index)
SELECT gc.*
FROM geonames_cities gc
JOIN geonames_cities_fts fts ON fts.rowid = gc.id
WHERE geonames_cities_fts MATCH 'lond*'
ORDER BY rank;

-- Alternate name match (e.g. "Bombay" finds Mumbai)
SELECT gc.*
FROM geonames_cities gc
JOIN geonames_cities_fts fts ON fts.rowid = gc.id
WHERE geonames_cities_fts MATCH 'bombay'
ORDER BY rank;
```

### Proximity — find cities near a point

```sql
-- Bounding box (uses the lat/lon index — fast)
SELECT *, (latitude - 19.076) * (latitude - 19.076)
        + (longitude - 72.877) * (longitude - 72.877) AS dist_sq
FROM geonames_cities
WHERE latitude  BETWEEN 19.076 - 1.0 AND 19.076 + 1.0
  AND longitude BETWEEN 72.877 - 1.0 AND 72.877 + 1.0
ORDER BY dist_sq
LIMIT 10;
```

### Filter by country

```sql
SELECT * FROM geonames_cities WHERE country_code = 'IN' ORDER BY population DESC;
```

### Filter by state / region

```sql
SELECT * FROM geonames_cities WHERE region = 'Maharashtra' ORDER BY population DESC;
```

### Cities within a state of a country

```sql
SELECT * FROM geonames_cities
WHERE country_code = 'IN' AND region = 'Maharashtra'
ORDER BY population DESC;
```

---

## Indexes on `geonames_cities`

| Index | Columns | Purpose |
|---|---|---|
| `idx_geonames_cities_city_lower` *(PG)* | `LOWER(city)` | Case-insensitive exact lookup |
| `idx_geonames_cities_city_trgm` *(PG)* | `city` GIN trigram | `ILIKE` / `similarity()` fuzzy search |
| `idx_geonames_cities_city` *(SQLite)* | `city COLLATE NOCASE` | Case-insensitive exact lookup |
| `geonames_cities_fts` *(SQLite)* | `city`, `alternate_city_names` | FTS5 full-text / prefix search |
| `idx_geonames_cities_lat_lon` | `(latitude, longitude)` | Bounding-box proximity queries |
| `idx_geonames_cities_country_code` | `country_code` | Filter by country |
| `idx_geonames_cities_region` | `region` | Filter by state |
| `idx_geonames_cities_country_region` | `(country_code, region)` | Filter by country + state |

---

## Environment variables

| Variable | Description | Default |
|---|---|---|
| `DB_DRIVER` | Backend: `postgres` or `sqlite` | — (required) |
| `DATABASE_URL` | PostgreSQL connection URL | — |
| `SQLITE_DB_PATH` | Path for the SQLite `.db` file | `./locationdb.db` |
| `POSTGRES_USER` | docker-compose user *(test mode)* | `locationdb_user` |
| `POSTGRES_PASSWORD` | docker-compose password *(test mode)* | `changeme` |
| `POSTGRES_DB` | docker-compose database name *(test mode)* | `locationdb` |
| `POSTGRES_PORT` | docker-compose host port *(test mode)* | `5432` |

---

## Project layout

```
populate.sh                   Orchestrator — populates the database
sync.sh                       Orchestrator — applies daily GeoNames deltas
lib/
  core.sh                     Shared utilities (logging, download, cleanup)
drivers/
  ADDING_A_DRIVER.md          Guide for adding a new database backend
  postgres/
    driver.sh                 PostgreSQL implementation
    sql/01_schema.sql         Tables, indexes, sync tracker
    sql/02_load.sql           Bulk-load (\copy)
    sql/03_flatten.sql        Flatten staging → geonames_cities
  sqlite/
    driver.sh                 SQLite implementation
    sql/01_schema.sql         Tables, FTS5, indexes, triggers
    sql/03_flatten.sql        Flatten + FTS5 rebuild
docker-compose.yaml           Local PostgreSQL for testing
.env.example                  Configuration template
```

---

## Adding a new database backend

See [`drivers/ADDING_A_DRIVER.md`](drivers/ADDING_A_DRIVER.md).

Create `drivers/<name>/driver.sh` implementing six functions
(`db_name`, `db_check_deps`, `db_init`, `db_load`, `db_flatten`,
`db_supports_sync`, `db_sync`). The orchestrators pick it up automatically —
no other files need to change.

---

## SQLite vs PostgreSQL

| Feature | PostgreSQL | SQLite |
|---|---|---|
| Server required | Yes | No |
| `alternate_city_names` type | `text[]` array | comma-separated `TEXT` |
| Fuzzy city search | `pg_trgm` + `ILIKE` | FTS5 virtual table |
| Incremental sync | ✅ (`sync.sh`) | ❌ re-run `populate.sh` |
| Timestamps | `now()` | `datetime('now')` |

---

## Licence

Scripts in this repository are released under the [MIT Licence](LICENSE).

Geographic data is provided by [GeoNames](https://www.geonames.org/) under the
[Creative Commons Attribution 4.0 International Licence](https://creativecommons.org/licenses/by/4.0/).
