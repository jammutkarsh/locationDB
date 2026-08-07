# locationDB

A script that downloads the public [GeoNames](https://www.geonames.org/) dataset
and loads it into a local database — ready to query by city name, country, state,
or geographic coordinates.

Supports **PostgreSQL**, **SQLite**, and **MySQL** out of the box. Adding a new
backend requires only a single driver file; the orchestrator scripts never need to change.

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
  - [`countryInfo.txt`](https://download.geonames.org/export/dump/countryInfo.txt) — countries (ISO codes, capital, continent, currency, languages, …)

> **Attribution requirement:** If you use this data in a public product, your
> app or docs must visibly credit GeoNames per the CC BY 4.0 licence, e.g.:
> *"Geographic data © [GeoNames](https://www.geonames.org/), CC BY 4.0"*

---

## Requirements

| Tool | SQLite | PostgreSQL | MySQL |
|---|---|---|---|
| `curl` | ✅ | ✅ | ✅ |
| `unzip` | ✅ | ✅ | ✅ |
| `sqlite3` | ✅ | — | — |
| `psql` (PostgreSQL client) | — | ✅ | — |
| `mysql` (MySQL client) | — | — | ✅ |
| Docker + `docker-compose` | — | only for `--test` mode | — |

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

Pass `--cache` to skip re-downloading GeoNames files when `data/` already has
them, and to keep `data/` after the import (by default it is deleted):

```bash
./populate.sh --driver sqlite --db-path ./locationdb.db --cache
```

#### PostgreSQL — remote server

Two ways to point it at a database; `DATABASE_URL` wins if both are set.

```bash
# 1 — standard libpq variables (also honours ~/.pgpass, PGSERVICE, PGSSLMODE)
export PGHOST=db.example.com PGPORT=5432 \
       PGUSER=locationdb_user PGPASSWORD=secret PGDATABASE=locationdb
./populate.sh --driver postgres

# 2 — a connection string
./populate.sh --driver postgres \
  --db-url "postgres://user:pass@host:5432/dbname?sslmode=disable"
```

#### PostgreSQL — local test server (docker-compose)

```bash
./populate.sh --driver postgres --test
# Starts a Postgres container, runs the import, leaves the container running.
```

#### MySQL — remote server

Two ways to point it at a database; `DATABASE_URL` wins if both are set.

```bash
# 1 — standard MYSQL_* variables (also honours ~/.my.cnf)
export MYSQL_HOST=db.example.com MYSQL_USER=locationdb_user \
       MYSQL_PASSWORD=secret MYSQL_DATABASE=locationdb
./populate.sh --driver mysql

# 2 — a connection string
./populate.sh --driver mysql \
  --db-url "mysql://user:pass@host:3306/dbname"
```

#### Pre-built SQLite database (skip the import)

A compressed, ready-to-use SQLite database is published daily to Cloudflare R2
and served via CDN. It includes all tables, indexes, and the trigram index.

```bash
curl -O https://locationdb.utkarshchourasia.in/location.db.zst
zstd -d location.db.zst
# location.db is ~400 MB decompressed, ready for queries
```

Metadata available at `https://locationdb.utkarshchourasia.in/location.json`:
row counts, SHA-256 checksums, last-updated timestamp.

#### Using environment variables instead of flags

```bash
export DB_DRIVER=sqlite
export SQLITE_DB_PATH=./locationdb.db
./populate.sh
```

---

## Daily incremental sync

Keeps the database up-to-date with GeoNames' daily modification and deletion
feeds. **PostgreSQL and MySQL** — SQLite users re-run `populate.sh` or download
the pre-built database.

```bash
# Remote server
./sync.sh --driver postgres \
  --db-url "postgres://user:pass@host:5432/dbname?sslmode=disable"

# Local test server
./sync.sh --driver postgres --test

# Via env vars — connection string
export DB_DRIVER=postgres
export DATABASE_URL="postgres://user:pass@host:5432/dbname?sslmode=disable"
./sync.sh

# Via env vars — libpq style
export DB_DRIVER=postgres
export PGHOST=db.example.com PGUSER=locationdb_user PGDATABASE=locationdb
./sync.sh

# MySQL
./sync.sh --driver mysql \
  --db-url "mysql://user:pass@host:3306/dbname"
```

Only `geonames_cities` is delta-synced. States and countries change a handful
of times a year — re-run `populate.sh` to refresh them.

`--cache` works the same as in `populate.sh` — keeps downloaded delta files
in `data/` instead of deleting them.

Schedule this as a daily cron job:

```cron
0 3 * * * cd /path/to/locationDB && ./sync.sh --driver postgres >> /var/log/locationdb-sync.log 2>&1
```

---

## Output tables

Both backends produce the same three tables plus one flat view:

| Object | Rows | What it is |
|---|---|---|
| `geonames_cities` | ~150k | Cities with population ≥ 1000 |
| `geonames_states` | ~4k | First-level admin divisions (states / provinces) |
| `geonames_countries` | 252 | Countries — ISO codes, capital, continent, currency, languages |
| `locations` *(view)* | ~150k | The columns most callers want — slim projection of `geonames_cities` |

Plus `sync_state` (one row, tracks the last applied delta) and, on SQLite,
the `geonames_cities_fts` index and `geonames_trigrams` table for fuzzy search.
The raw GeoNames staging tables exist only while `populate.sh` runs; they are
dropped at the end of the import (SQLite also `VACUUM`s), so the finished
database contains nothing else.

`geonames_cities` already carries the resolved **state** and **country
names** — no join needed for the common case:

```sql
SELECT city, region, state, country, population FROM geonames_cities
WHERE city = 'Mumbai' COLLATE NOCASE;      -- SQLite
-- WHERE LOWER(city) = LOWER('Mumbai');    -- PostgreSQL
-- WHERE city = 'Mumbai';                  -- MySQL (collation handles case)

-- city    | region          | state       | country | population
-- Mumbai  | Mumbai Suburban | Maharashtra | India   | 12691836
```

How the GeoNames pieces correlate, and how the import resolves them:

```
cities1000.country_code                          -> countryInfo.ISO   -> country  ('India')
cities1000.country_code || '.' || admin1_code    -> admin1Codes.code  -> state    ('Maharashtra')
   … || '.' || admin2_code                       -> admin2Codes.code  -> region   ('Mumbai Suburban')
```

That concatenated admin1 key is stored as `state_code` (`IN.16`), which is
also the primary key of `geonames_states` — so the reference tables stay
joinable while the city row is readable on its own.

### `locations` (view)

Straight off `geonames_cities` (no joins, so it uses that table's indexes):

| Column | Notes |
|---|---|
| `id` | Primary key of `geonames_cities` (also the FTS5 rowid) |
| `city` | City name |
| `region` | District / county (admin2). Equals `state` when GeoNames has no admin2 |
| `state` | State / province name (admin1) |
| `country` | Country name |
| `alternate_names` | `alternate_city_names` — Postgres array, SQLite comma-separated |
| `population` | |
| `latitude`, `longitude` | Decimal degrees |

```sql
SELECT * FROM locations WHERE state = 'Maharashtra' ORDER BY population DESC;
```

### `geonames_states`

| Column | Type | Description |
|---|---|---|
| `code` | text | Primary key — `country_code . admin1_code`, e.g. `IN.16` |
| `country_code` | text | ISO-3166 country code |
| `admin1_code` | text | GeoNames first-level admin code |
| `state` | text | State / province name |
| `ascii_state` | text | ASCII form of the name |
| `geonameid` | integer | GeoNames identifier of the state itself |

### `geonames_countries`

Loaded straight from `countryInfo.txt`: `country_code` (PK), `iso3`,
`iso_numeric`, `fips`, `country`, `capital`, `area_sqkm`, `population`,
`continent`, `tld`, `currency_code`, `currency_name`, `phone`,
`postal_code_format`, `postal_code_regex`, `languages`, `geonameid`,
`neighbours`, `equivalent_fips`.

### `geonames_cities`

| Column | Type | Description |
|---|---|---|
| `id` | integer | Auto-generated primary key |
| `city` | text | City name (English) |
| `region` | text | District / county (admin2) — `Mumbai Suburban`. Equals `state` when GeoNames has no admin2 for the city |
| `state` | text | State / province name, resolved from admin1 (`Maharashtra`) |
| `country` | text | Country name, resolved from `countryInfo.txt` (`India`) |
| `latitude` | numeric | Decimal degrees |
| `longitude` | numeric | Decimal degrees |
| `population` | integer | Population count |
| `alternate_city_names` | text[] / text | Other names / transliterations (Postgres: array; SQLite: comma-separated) |
| `timezone` | text | IANA timezone string (e.g. `Asia/Kolkata`) |
| `country_code` | text | ISO-3166 country code (`IN`) |
| `state_code` | text | `IN.16` — foreign key to `geonames_states.code` |
| `geonameid` | integer | Unique GeoNames identifier |
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

-- MySQL (utf8mb4_unicode_ci handles case-insensitivity automatically)
SELECT * FROM geonames_cities WHERE city = 'Mumbai';
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

### City name — fuzzy (MySQL)

```sql
-- Uses the FULLTEXT index automatically
SELECT *, MATCH(city, alternate_city_names, state, region)
       AGAINST('bombay' IN NATURAL LANGUAGE MODE) AS score
FROM geonames_cities
WHERE MATCH(city, alternate_city_names, state, region)
      AGAINST('bombay' IN NATURAL LANGUAGE MODE)
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

### City name — typo-tolerant trigram search (SQLite)

```sql
-- Decomposes query into 3-char trigrams, ranks by overlap count.
-- Handles typos and partial matches (e.g. "kathmandu" → Kathmandu).
SELECT gc.*, COUNT(*) AS score
FROM geonames_trigrams gt
JOIN geonames_cities gc ON gc.id = gt.city_id
WHERE gt.trigram IN (' ka','kat','ath','thm','hma','man','and','ndu','du ')
GROUP BY gt.city_id
ORDER BY score DESC
LIMIT 8;
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

### Filter by state, or by the finer region

`state` is always the admin1 name. `region` is the admin2 name (district /
county) when GeoNames has one, and falls back to the state when it does not —
so the two are equal for cities with no admin2 row.

```sql
-- Every city in the state
SELECT * FROM geonames_cities WHERE state = 'Maharashtra' ORDER BY population DESC;

-- Narrower: just the district
SELECT * FROM geonames_cities WHERE region = 'Mumbai Suburban' ORDER BY population DESC;
```

### Cities within a state of a country

```sql
-- By state code (exact, index-backed)
SELECT * FROM geonames_cities WHERE state_code = 'IN.16' ORDER BY population DESC;

-- By name
SELECT * FROM geonames_cities
WHERE country_code = 'IN' AND state = 'Maharashtra'
ORDER BY population DESC;
```

### List states of a country

```sql
SELECT code, state FROM geonames_states WHERE country_code = 'IN' ORDER BY state;
```

### Countries

```sql
-- All countries in a continent
SELECT country_code, country, capital, population
FROM geonames_countries WHERE continent = 'AS' ORDER BY population DESC;

-- Look up a country by name
SELECT * FROM geonames_countries WHERE country = 'India' COLLATE NOCASE;  -- SQLite
-- MySQL: case-insensitive via utf8mb4_unicode_ci, no COLLATE needed
```

### Fuzzy city search, with state and country attached

```sql
-- SQLite (FTS5)
SELECT c.city, c.state, c.country
FROM geonames_cities c
JOIN geonames_cities_fts f ON f.rowid = c.id
WHERE geonames_cities_fts MATCH 'bombay';

-- SQLite (trigram — typo-tolerant)
SELECT c.city, c.state, c.country, COUNT(*) AS score
FROM geonames_trigrams t
JOIN geonames_cities c ON c.id = t.city_id
WHERE t.trigram IN (' bo','bom','omb','mba','bay','ay ')
GROUP BY t.city_id
ORDER BY score DESC LIMIT 8;

-- MySQL (FULLTEXT)
SELECT c.city, c.state, c.country,
       MATCH(c.city, c.alternate_city_names) AGAINST('bombay') AS score
FROM geonames_cities c
WHERE MATCH(c.city, c.alternate_city_names) AGAINST('bombay')
ORDER BY score DESC;
```

---

## Indexes on `geonames_cities`

| Index | Columns | Purpose |
|---|---|---|
| `idx_geonames_cities_city_lower` *(PG)* | `LOWER(city)` | Case-insensitive exact lookup |
| `idx_geonames_cities_city_trgm` *(PG)* | `city` GIN trigram | `ILIKE` / `similarity()` fuzzy search |
| `idx_geonames_cities_city` *(SQLite)* | `city COLLATE NOCASE` | Case-insensitive exact lookup |
| `idx_geonames_cities_city` *(MySQL)* | `city(191)` | Case-insensitive exact lookup (via `utf8mb4_unicode_ci`) |
| `geonames_cities_fts` *(SQLite)* | `city`, `alternate_city_names`, `state`, `region` | FTS5 full-text / prefix search |
| `geonames_trigrams` *(SQLite)* | `(trigram, city_id)` composite PK + lookup index | Typo-tolerant fuzzy search via 3-char sliding windows |
| `idx_geonames_cities_city_ft` *(MySQL)* | `city`, `alternate_city_names`, `state`, `region` | FULLTEXT fuzzy search |
| `idx_geonames_cities_lat_lon` | `(latitude, longitude)` | Bounding-box proximity queries |
| `idx_geonames_cities_country_code` | `country_code` | Filter by country |
| `idx_geonames_cities_state` | `state` | Filter by state name |
| `idx_geonames_cities_region` | `region` | Filter by district / county |
| `idx_geonames_cities_country_state` | `(country_code, state)` | Filter by country + state |

---

## Environment variables

| Variable | Description | Default |
|---|---|---|
| `DB_DRIVER` | Backend: `postgres`, `sqlite`, or `mysql` | — (required) |
| `DATABASE_URL` | PostgreSQL or MySQL connection URL — takes precedence over `PG*`/`MYSQL_*` | — |
| `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSERVICE`, … | Standard libpq variables, used when `DATABASE_URL` is empty | psql defaults |
| `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE` | Standard MySQL variables, used when `DATABASE_URL` is empty | mysql defaults |
| `SQLITE_DB_PATH` | Path for the SQLite `.db` file | `./locationdb.db` |
| `POSTGRES_USER` | docker-compose user *(test mode)* | `locationdb_user` |
| `POSTGRES_PASSWORD` | docker-compose password *(test mode)* | `changeme` |
| `POSTGRES_DB` | docker-compose database name *(test mode)* | `locationdb` |
| `POSTGRES_PORT` | docker-compose host port *(test mode)* | `5432` |
| `CACHE` | Set to `1` to keep downloaded files in `data/` | `0` (delete after import) |

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
    sql/03_flatten.sql        Flatten staging → final tables, drop staging
  sqlite/
    driver.sh                 SQLite implementation
    sql/01_schema.sql         Tables, FTS5, indexes, triggers
    sql/03_flatten.sql        Flatten + FTS5 rebuild, trigram index, drop staging, VACUUM
  mysql/
    driver.sh                 MySQL implementation
    sql/01_schema.sql         Tables, FULLTEXT indexes, view
    sql/02_load.sql           Bulk-load (LOAD DATA LOCAL INFILE)
    sql/03_flatten.sql        Flatten staging → final tables, drop staging
tests/
  test_sqlite.sh              Offline pipeline check on tiny fixtures
  test_postgres.sh            Same checks against a real Postgres (--test for docker)
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

## SQLite vs PostgreSQL vs MySQL

| Feature | PostgreSQL | SQLite | MySQL |
|---|---|---|---|
| Server required | Yes | No | Yes |
| `alternate_city_names` type | `text[]` array | comma-separated `TEXT` | comma-separated `TEXT` |
| Fuzzy city search | `pg_trgm` + `ILIKE` | FTS5 + trigram index | FULLTEXT |
| Incremental sync | ✅ (`sync.sh`) | ❌ re-run `populate.sh` | ✅ (`sync.sh`) |
| Timestamps | `now()` | `datetime('now')` | `CURRENT_TIMESTAMP` |
| Pre-built download | — | ✅ (xz compressed, daily) | — |

---

## Licence

Scripts in this repository are released under the [MIT Licence](LICENSE).

Geographic data is provided by [GeoNames](https://www.geonames.org/) under the
[Creative Commons Attribution 4.0 International Licence](https://creativecommons.org/licenses/by/4.0/).
