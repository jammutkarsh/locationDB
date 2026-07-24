-- Postgres schema for locationDB
-- Raw GeoNames staging tables + final output table + sync tracker.

DROP TABLE IF EXISTS cities1000 CASCADE;
DROP TABLE IF EXISTS admin1Codes CASCADE;
DROP TABLE IF EXISTS admin2Codes CASCADE;
DROP TABLE IF EXISTS geonames_countries CASCADE;

-- Raw GeoNames staging tables — dropped again at the end of 03_flatten.sql,
-- they only exist while the import runs.
CREATE TABLE cities1000 (
    geonameid     BIGINT PRIMARY KEY,
    name          TEXT,
    asciiname     TEXT,
    alternatenames TEXT,
    latitude      DOUBLE PRECISION,
    longitude     DOUBLE PRECISION,
    feature_class TEXT,
    feature_code  TEXT,
    country_code  TEXT,
    cc2           TEXT,
    admin1_code   TEXT,
    admin2_code   TEXT,
    admin3_code   TEXT,
    admin4_code   TEXT,
    population    BIGINT,
    elevation     TEXT,
    dem           TEXT,
    timezone      TEXT,
    modification  TEXT
);

CREATE TABLE admin1Codes (
    code      TEXT PRIMARY KEY,
    name      TEXT,
    asciiname TEXT,
    geonameid BIGINT
);

CREATE TABLE admin2Codes (
    code      TEXT PRIMARY KEY,
    name      TEXT,
    asciiname TEXT,
    geonameid BIGINT
);

-- Incremental-sync state tracker
CREATE TABLE IF NOT EXISTS sync_state (
    name        TEXT PRIMARY KEY,
    last_synced DATE NOT NULL
);

INSERT INTO sync_state (name, last_synced)
VALUES ('cities1000', '2025-09-18')
ON CONFLICT (name) DO NOTHING;

-- Indexes for join performance
CREATE INDEX IF NOT EXISTS idx_cities_admin1 ON cities1000 (country_code, admin1_code);
CREATE INDEX IF NOT EXISTS idx_cities_admin2 ON cities1000 (country_code, admin1_code, admin2_code);
CREATE INDEX IF NOT EXISTS idx_cities_cc     ON cities1000 (country_code);

-- Final flattened output table
CREATE TABLE IF NOT EXISTS geonames_cities (
    id                   BIGSERIAL PRIMARY KEY,
    city                 TEXT,
    region               TEXT,   -- admin2 name if present, else the state
    state                TEXT,   -- resolved admin1 name, e.g. 'Maharashtra'
    country              TEXT,   -- resolved country name, e.g. 'India'
    latitude             NUMERIC,
    longitude            NUMERIC,
    population           BIGINT DEFAULT 0,
    alternate_city_names TEXT[],
    timezone             TEXT,
    country_code         TEXT,
    state_code           TEXT,   -- 'IN.16' — joins to geonames_states.code
    geonameid            BIGINT UNIQUE,
    inserted_at          TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT now(),
    updated_at           TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT now()
);

-- Column order only applies to freshly created tables; Postgres cannot
-- reorder an existing one. Drop the table if you want the new layout.

-- Older databases created before these columns existed
ALTER TABLE geonames_cities ADD COLUMN IF NOT EXISTS state_code TEXT;
ALTER TABLE geonames_cities ADD COLUMN IF NOT EXISTS state      TEXT;

-- -------------------------------------------------------------------------
-- Countries — loaded directly from GeoNames countryInfo.txt (19 columns,
-- in file order: \copy maps them positionally, so do not reorder).
-- -------------------------------------------------------------------------
CREATE TABLE geonames_countries (
    country_code       TEXT PRIMARY KEY,   -- ISO-3166 alpha-2
    iso3               TEXT,
    iso_numeric        TEXT,
    fips               TEXT,
    country            TEXT,
    capital            TEXT,
    area_sqkm          DOUBLE PRECISION,
    population         BIGINT,
    continent          TEXT,               -- AF AS EU NA OC SA AN
    tld                TEXT,
    currency_code      TEXT,
    currency_name      TEXT,
    phone              TEXT,
    postal_code_format TEXT,
    postal_code_regex  TEXT,
    languages          TEXT,               -- comma-separated locale codes
    geonameid          BIGINT,
    neighbours         TEXT,               -- comma-separated country codes
    equivalent_fips    TEXT
);

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
    geonameid    BIGINT
);

-- -------------------------------------------------------------------------
-- Query 1: City name search
--   Exact / prefix:  WHERE LOWER(city) = LOWER($1)
--   Fuzzy / ILIKE:   WHERE city ILIKE '%london%'  (uses pg_trgm)
-- -------------------------------------------------------------------------
-- Enable trigram extension for fuzzy / ILIKE search
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Case-insensitive exact / prefix lookup
CREATE INDEX IF NOT EXISTS idx_geonames_cities_city_lower
    ON geonames_cities (LOWER(city));

-- Trigram index — powers ILIKE '%term%' and similarity() queries
CREATE INDEX IF NOT EXISTS idx_geonames_cities_city_trgm
    ON geonames_cities USING gin (city gin_trgm_ops);

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
--   `country` holds the resolved name ('India'), `country_code` the ISO
--   code ('IN'). Filter on country_code — it is the indexed one.
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_country_code
    ON geonames_cities (country_code);

-- -------------------------------------------------------------------------
-- Query 4: Filter by state, or by the finer region (admin2)
--   WHERE LOWER(state)  = LOWER('Maharashtra')
--   WHERE LOWER(region) = LOWER('Mumbai Suburban')
--   region equals state for cities GeoNames gives no admin2 for.
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_geonames_cities_state
    ON geonames_cities (LOWER(state));
CREATE INDEX IF NOT EXISTS idx_geonames_cities_region
    ON geonames_cities (LOWER(region));


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
--   SELECT * FROM locations WHERE LOWER(city) = LOWER('Mumbai');
-- -------------------------------------------------------------------------
DROP VIEW IF EXISTS locations;
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
