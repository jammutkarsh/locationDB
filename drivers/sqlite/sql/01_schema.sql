-- SQLite schema for locationDB
-- Key differences from Postgres:
--   • No ARRAY type — alternate_city_names stored as comma-separated TEXT
--   • INTEGER PRIMARY KEY AUTOINCREMENT instead of BIGSERIAL
--   • datetime('now') instead of now()
--   • No CASCADE on DROP (SQLite ignores it anyway)

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
-- Query 1: City name search
--   Exact / case-insensitive:  WHERE city = $1 COLLATE NOCASE
--   Note: SQLite has no trigram extension. For full fuzzy search, consider
--         creating an FTS5 virtual table on top of geonames_cities.
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_city
    ON geonames_cities (city COLLATE NOCASE);

-- -------------------------------------------------------------------------
-- Query 2: Proximity / reverse-geocoding by lat & long
--   Bounding box:  WHERE latitude  BETWEEN $lat - $d AND $lat + $d
--                  AND   longitude BETWEEN $lon - $d AND $lon + $d
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_lat_lon
    ON geonames_cities (latitude, longitude);
