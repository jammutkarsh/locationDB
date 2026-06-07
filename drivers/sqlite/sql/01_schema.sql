-- SQLite schema for locationDB
-- Key differences from Postgres:
--   • No ARRAY type — alternate_city_names stored as comma-separated TEXT
--   • INTEGER PRIMARY KEY AUTOINCREMENT instead of BIGSERIAL
--   • datetime('now') instead of now()
--   • No CASCADE on DROP (SQLite ignores it anyway)

DROP TRIGGER IF EXISTS geonames_cities_ai;
DROP TRIGGER IF EXISTS geonames_cities_ad;
DROP TRIGGER IF EXISTS geonames_cities_au;
DROP TABLE IF EXISTS geonames_cities_fts;
DROP TABLE IF EXISTS cities1000;
DROP TABLE IF EXISTS admin1Codes;
DROP TABLE IF EXISTS admin2Codes;
DROP TABLE IF EXISTS admin5Codes;
DROP TABLE IF EXISTS sync_state;
DROP TABLE IF EXISTS geonames_cities;

-- Raw GeoNames staging tables
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

CREATE TABLE admin5Codes (
    geonameid INTEGER,
    adm5code  TEXT
);

-- Incremental-sync state tracker
CREATE TABLE sync_state (
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
CREATE TABLE geonames_cities (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    city                 TEXT,
    country              TEXT,
    timezone             TEXT,
    population           INTEGER DEFAULT 0,
    latitude             REAL,
    longitude            REAL,
    country_code         TEXT,
    alternate_city_names TEXT,
    inserted_at          TEXT DEFAULT (datetime('now')),
    updated_at           TEXT DEFAULT (datetime('now')),
    region               TEXT,
    geonameid            INTEGER UNIQUE
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
CREATE VIRTUAL TABLE geonames_cities_fts USING fts5(
    city,
    alternate_city_names,
    content='geonames_cities',
    content_rowid='id'
);

-- Triggers keep the FTS5 index in sync with geonames_cities for
-- incremental updates (inserts, deletes, edits after the initial load).
CREATE TRIGGER geonames_cities_ai AFTER INSERT ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(rowid, city, alternate_city_names)
    VALUES (new.id, new.city, new.alternate_city_names);
END;

CREATE TRIGGER geonames_cities_ad AFTER DELETE ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(geonames_cities_fts, rowid, city, alternate_city_names)
    VALUES ('delete', old.id, old.city, old.alternate_city_names);
END;

CREATE TRIGGER geonames_cities_au AFTER UPDATE ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(geonames_cities_fts, rowid, city, alternate_city_names)
    VALUES ('delete', old.id, old.city, old.alternate_city_names);
    INSERT INTO geonames_cities_fts(rowid, city, alternate_city_names)
    VALUES (new.id, new.city, new.alternate_city_names);
END;

-- -------------------------------------------------------------------------
-- Query 2: Proximity / reverse-geocoding by lat & long
--   Bounding box:  WHERE latitude  BETWEEN $lat - $d AND $lat + $d
--                  AND   longitude BETWEEN $lon - $d AND $lon + $d
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_lat_lon
    ON geonames_cities (latitude, longitude);

-- -------------------------------------------------------------------------
-- Query 3: Filter by country
--   WHERE country_code = 'IN'
--   Note: country and country_code both store the ISO-3166 code.
--         Indexing country_code covers both columns.
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_country_code
    ON geonames_cities (country_code);

-- -------------------------------------------------------------------------
-- Query 4: Filter by state / region
--   WHERE region = 'Maharashtra'
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_region
    ON geonames_cities (region);

-- -------------------------------------------------------------------------
-- Query 5: Cities within a specific state of a specific country
--   WHERE country_code = 'IN' AND region = 'Maharashtra'
--   The composite covers single-country filters too (leading column rule).
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_country_region
    ON geonames_cities (country_code, region);
