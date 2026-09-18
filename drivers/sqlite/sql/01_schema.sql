-- SQLite schema for locationDB
-- Key differences from Postgres:
--   • No ARRAY type — alternate_city_names stored as comma-separated TEXT
--   • geonames_cities.id IS the GeoNames geonameid — stable across builds
--   • datetime('now') instead of now()
--   • No CASCADE on DROP (SQLite ignores it anyway)

--   • Idempotent: final tables are CREATE IF NOT EXISTS and 03_flatten.sql
--     upserts into them, so running the pipeline over an existing .db keeps
--     every row (and its id) and only adds/updates. Only staging is dropped.

-- Schema version. driver.sh discards a .db whose user_version differs
-- v2: ids = geonameid (older builds had unstable AUTOINCREMENT ids).
-- v3: geonames_trigrams is WITHOUT ROWID.
PRAGMA user_version = 3;

DROP VIEW IF EXISTS locations;
DROP TABLE IF EXISTS cities1000;
DROP TABLE IF EXISTS admin1Codes;
DROP TABLE IF EXISTS admin2Codes;

-- Raw GeoNames staging tables — dropped again at the end of 03_flatten.sql,
-- they only exist while the import runs.
CREATE TABLE cities1000 (
    geonameid     INTEGER PRIMARY KEY,
    name          TEXT,
    asciiname     TEXT,
    alternatenames TEXT,
    latitude      REAL,
    longitude     REAL,
    feature_class TEXT,
    feature_code  TEXT,
    country_code  TEXT,
    cc2           TEXT,
    admin1_code   TEXT,
    admin2_code   TEXT,
    admin3_code   TEXT,
    admin4_code   TEXT,
    population    INTEGER,
    elevation     TEXT,
    dem           TEXT,
    timezone      TEXT,
    modification  TEXT
);

CREATE TABLE admin1Codes (
    code      TEXT PRIMARY KEY,
    name      TEXT,
    asciiname TEXT,
    geonameid INTEGER
);

CREATE TABLE admin2Codes (
    code      TEXT PRIMARY KEY,
    name      TEXT,
    asciiname TEXT,
    geonameid INTEGER
);

-- Incremental-sync state tracker
CREATE TABLE IF NOT EXISTS sync_state (
    name        TEXT PRIMARY KEY,
    last_synced TEXT NOT NULL   -- ISO-8601 date string
);

INSERT OR IGNORE INTO sync_state (name, last_synced)
VALUES ('cities1000', '2025-09-18');

-- Indexes for join performance
CREATE INDEX IF NOT EXISTS idx_cities_admin1 ON cities1000 (country_code, admin1_code);
CREATE INDEX IF NOT EXISTS idx_cities_admin2 ON cities1000 (country_code, admin1_code, admin2_code);
CREATE INDEX IF NOT EXISTS idx_cities_cc     ON cities1000 (country_code);

-- Final flattened output table
-- alternate_city_names: comma-separated TEXT (SQLite has no array type)
CREATE TABLE IF NOT EXISTS geonames_cities (
    id                   INTEGER PRIMARY KEY,  -- = geonameid; never reassigned
    city                 TEXT,
    region               TEXT,   -- admin2 name if present, else the state
    state                TEXT,   -- resolved admin1 name, e.g. 'Maharashtra'
    country              TEXT,   -- resolved country name, e.g. 'India'
    latitude             REAL,
    longitude            REAL,
    population           INTEGER DEFAULT 0,
    alternate_city_names TEXT,
    timezone             TEXT,
    country_code         TEXT,
    state_code           TEXT,   -- 'IN.16' — joins to geonames_states.code
    geonameid            INTEGER UNIQUE,
    inserted_at          TEXT DEFAULT (datetime('now')),
    updated_at           TEXT DEFAULT (datetime('now'))
);

-- -------------------------------------------------------------------------
-- Countries — loaded directly from GeoNames countryInfo.txt (19 columns,
-- in file order: .import maps them positionally, so do not reorder).
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS geonames_countries (
    country_code       TEXT PRIMARY KEY,   -- ISO-3166 alpha-2
    iso3               TEXT,
    iso_numeric        TEXT,
    fips               TEXT,
    country            TEXT,
    capital            TEXT,
    area_sqkm          REAL,
    population         INTEGER,
    continent          TEXT,               -- AF AS EU NA OC SA AN
    tld                TEXT,
    currency_code      TEXT,
    currency_name      TEXT,
    phone              TEXT,
    postal_code_format TEXT,
    postal_code_regex  TEXT,
    languages          TEXT,               -- comma-separated locale codes
    geonameid          INTEGER,
    neighbours         TEXT,               -- comma-separated country codes
    equivalent_fips    TEXT
);

-- Countries are .import-ed straight into this table (no staging), so clear
-- it first; country_code is the key and is stable, so nothing is lost.
DELETE FROM geonames_countries;

-- -------------------------------------------------------------------------
-- States / provinces — GeoNames first-level admin divisions (admin1).
-- Filled from the admin1Codes staging table in 03_flatten.sql.
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS geonames_states (
    code         TEXT PRIMARY KEY,   -- 'IN.16'  (country_code . admin1_code)
    country_code TEXT,
    admin1_code  TEXT,
    state        TEXT,
    ascii_state  TEXT,
    geonameid    INTEGER
);

-- -------------------------------------------------------------------------
-- Query 1a: Exact / case-insensitive city name lookup
--   WHERE city = $1 COLLATE NOCASE
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_city
    ON geonames_cities (city COLLATE NOCASE);

-- -------------------------------------------------------------------------
-- Query 1b: Full-text / fuzzy city search via FTS5
--
-- FTS5 external-content table — no data duplication.
-- The index stores search tokens only; text is read from geonames_cities.
--
-- Example queries:
--   Prefix:     SELECT gc.* FROM geonames_cities gc
--               JOIN geonames_cities_fts fts ON fts.rowid = gc.id
--               WHERE geonames_cities_fts MATCH 'lond*'
--               ORDER BY rank;
--
--   Exact word: WHERE geonames_cities_fts MATCH 'london'
--   Phrase:     WHERE geonames_cities_fts MATCH '"new york"'
--   Any column: WHERE geonames_cities_fts MATCH 'mumbai OR bombay'
-- -------------------------------------------------------------------------
CREATE VIRTUAL TABLE IF NOT EXISTS geonames_cities_fts USING fts5(
    city,
    alternate_city_names,
    state,
    region,
    content='geonames_cities',
    content_rowid='id'
);

-- Triggers keep the FTS5 index in sync with geonames_cities for
-- incremental updates (inserts, deletes, edits after the initial load).
CREATE TRIGGER IF NOT EXISTS geonames_cities_ai AFTER INSERT ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(rowid, city, alternate_city_names, state, region)
    VALUES (new.id, new.city, new.alternate_city_names, new.state, new.region);
END;

CREATE TRIGGER IF NOT EXISTS geonames_cities_ad AFTER DELETE ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(geonames_cities_fts, rowid, city, alternate_city_names, state, region)
    VALUES ('delete', old.id, old.city, old.alternate_city_names, old.state, old.region);
END;

CREATE TRIGGER IF NOT EXISTS geonames_cities_au AFTER UPDATE ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(geonames_cities_fts, rowid, city, alternate_city_names, state, region)
    VALUES ('delete', old.id, old.city, old.alternate_city_names, old.state, old.region);
    INSERT INTO geonames_cities_fts(rowid, city, alternate_city_names, state, region)
    VALUES (new.id, new.city, new.alternate_city_names, new.state, new.region);
END;

-- ---------------------------------------------------------------------------
-- Query 1c: Trigram index for typo-tolerant fuzzy search
--
-- Each city name + its alternates are decomposed into all 3-char substrings
-- (trigrams). The wandersort client decomposes the user's query the same way
-- and finds matches via overlapping trigrams:
--
--   SELECT gc.*, COUNT(*) as score
--   FROM geonames_trigrams gt
--   JOIN geonames_cities gc ON gc.id = gt.city_id
--   WHERE gt.trigram IN (' ka','kat','ath','thm','hma','man','and','ndu','du ')
--   GROUP BY gt.city_id
--   ORDER BY score DESC LIMIT 8
--
-- WITHOUT ROWID: the table is stored once, as a B-tree ordered by its primary
-- key, instead of a rowid table plus a separate index copying both columns.
-- Lookups by trigram use that key directly (trigram is its leading column),
-- so no extra index is needed. Cut the published .db from 414 MB to 177 MB.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS geonames_trigrams (
    trigram  TEXT    NOT NULL,
    city_id  INTEGER NOT NULL,
    PRIMARY KEY (trigram, city_id)
) WITHOUT ROWID;

-- ---------------------------------------------------------------------------
-- Query 2: Proximity / reverse-geocoding by lat & long
--   Bounding box:  WHERE latitude  BETWEEN $lat - $d AND $lat + $d
--                  AND   longitude BETWEEN $lon - $d AND $lon + $d
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_lat_lon
    ON geonames_cities (latitude, longitude);

-- -------------------------------------------------------------------------
-- Query 3: Filter by country
--   WHERE country_code = 'IN'
--   `country` holds the resolved name ('India'), `country_code` the ISO
--   code ('IN'). Filter on country_code — it is the indexed one.
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_country_code
    ON geonames_cities (country_code);

-- -------------------------------------------------------------------------
-- Query 4: Filter by state, or by the finer region (admin2)
--   WHERE state  = 'Maharashtra'     COLLATE NOCASE
--   WHERE region = 'Mumbai Suburban' COLLATE NOCASE
--   region equals state for cities GeoNames gives no admin2 for.
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_state
    ON geonames_cities (state COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_geonames_cities_region
    ON geonames_cities (region COLLATE NOCASE);

-- -------------------------------------------------------------------------
-- Query 5: Cities within a specific state of a specific country
--   WHERE country_code = 'IN' AND state = 'Maharashtra'
--   The composite covers single-country filters too (leading column rule).
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_country_state
    ON geonames_cities (country_code, state);

-- -------------------------------------------------------------------------
-- The eight columns most callers actually want, nothing else.
-- Plain projection of geonames_cities — no joins, so it uses that table's
-- indexes directly:
--   SELECT * FROM locations WHERE city = 'Mumbai' COLLATE NOCASE;
-- -------------------------------------------------------------------------
CREATE VIEW locations AS
SELECT
    id,
    city,
    region,
    state,
    country,
    latitude,
    longitude,
    population,
    alternate_city_names AS alternate_names
FROM geonames_cities;
