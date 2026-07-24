-- MySQL: locationDB schema — staging tables, final tables, indexes, view.
-- Executed via: mysql < 01_schema.sql
-- All tables use InnoDB with utf8mb4 charset for full Unicode support.

DROP TABLE IF EXISTS cities1000;
DROP TABLE IF EXISTS admin1Codes;
DROP TABLE IF EXISTS admin2Codes;
DROP TABLE IF EXISTS geonames_countries;
DROP TABLE IF EXISTS sync_state;
DROP TABLE IF EXISTS geonames_cities;
DROP TABLE IF EXISTS geonames_states;
DROP TABLE IF EXISTS geonames_countries;
DROP VIEW IF EXISTS locations;

-- ---------------------------------------------------------------------------
-- Raw GeoNames staging tables — dropped again at the end of 03_flatten.sql,
-- they only exist while the import runs.
-- ---------------------------------------------------------------------------
CREATE TABLE cities1000 (
    geonameid     BIGINT PRIMARY KEY,
    name          TEXT,
    asciiname     TEXT,
    alternatenames TEXT,
    latitude      DOUBLE,
    longitude     DOUBLE,
    feature_class TEXT,
    feature_code  TEXT,
    country_code  TEXT,
    cc2           TEXT,
    admin1_code   TEXT,
    admin2_code   TEXT,
    admin3_code   TEXT,
    admin4_code   TEXT,
    population    BIGINT DEFAULT 0,
    elevation     INT,
    dem           INT,
    timezone      TEXT,
    modification_date DATE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE admin1Codes (
    code      TEXT,
    name      TEXT,
    asciiname TEXT,
    geonameid BIGINT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE admin2Codes (
    code      TEXT,
    name      TEXT,
    asciiname TEXT,
    geonameid BIGINT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Incremental-sync state tracker
CREATE TABLE IF NOT EXISTS sync_state (
    name        VARCHAR(64) PRIMARY KEY,
    last_synced DATE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Indexes for staging tables (speeds up the flatten JOIN)
CREATE INDEX idx_cities_admin1 ON cities1000 (country_code, admin1_code);
CREATE INDEX idx_cities_admin2 ON cities1000 (country_code, admin1_code, admin2_code);
CREATE INDEX idx_cities_cc     ON cities1000 (country_code);

-- ---------------------------------------------------------------------------
-- Final flattened output table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS geonames_cities (
    id                   BIGINT AUTO_INCREMENT PRIMARY KEY,
    city                 TEXT,
    region               TEXT,   -- admin2 name if present, else the state
    state                TEXT,   -- resolved admin1 name, e.g. 'Maharashtra'
    country              TEXT,   -- resolved country name, e.g. 'India'
    latitude             DOUBLE,
    longitude            DOUBLE,
    population           BIGINT DEFAULT 0,
    alternate_city_names TEXT,   -- comma-separated (no native array type)
    timezone             TEXT,
    country_code         VARCHAR(2),
    state_code           VARCHAR(16),   -- 'IN.16' — joins to geonames_states.code
    geonameid            BIGINT UNIQUE,
    inserted_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at           TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------------------------
-- Countries — loaded directly from GeoNames countryInfo.txt (19 columns,
-- in file order: LOAD DATA maps them positionally, so do not reorder).
-- -------------------------------------------------------------------------
CREATE TABLE geonames_countries (
    country_code       VARCHAR(2) PRIMARY KEY,
    iso3               VARCHAR(3),
    iso_numeric        VARCHAR(3),
    fips               VARCHAR(2),
    country            VARCHAR(64),
    capital            VARCHAR(128),
    area_sqkm          DOUBLE,
    population         BIGINT,
    continent          VARCHAR(2),        -- AF AS EU NA OC SA AN
    tld                VARCHAR(4),
    currency_code      VARCHAR(3),
    currency_name      VARCHAR(64),
    phone              VARCHAR(16),
    postal_code_format VARCHAR(64),
    postal_code_regex  VARCHAR(128),
    languages          TEXT,              -- comma-separated locale codes
    geonameid          BIGINT,
    neighbours         TEXT,              -- comma-separated country codes
    equivalent_fips    VARCHAR(2)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------------------------
-- States / provinces — GeoNames first-level admin divisions (admin1).
-- Filled from the admin1Codes staging table in 03_flatten.sql.
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS geonames_states (
    code         VARCHAR(16) PRIMARY KEY,   -- 'IN.16'
    country_code VARCHAR(2),
    admin1_code  VARCHAR(8),
    state        VARCHAR(128),
    ascii_state  VARCHAR(128),
    geonameid    BIGINT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------------------------
-- Query 1: Case-insensitive city name lookup
--   WHERE city = 'Mumbai'
--   MySQL handles case-insensitivity via the table's utf8mb4_unicode_ci collation.
-- -------------------------------------------------------------------------
CREATE INDEX idx_geonames_cities_city
    ON geonames_cities (city(191));

-- MySQL FULLTEXT index for fuzzy city / state / region search
CREATE FULLTEXT INDEX idx_geonames_cities_city_ft
    ON geonames_cities (city, alternate_city_names, state, region);

-- -------------------------------------------------------------------------
-- Query 2: Proximity — find cities near a point (bounding-box)
--   WHERE latitude BETWEEN x-1 AND x+1 AND longitude BETWEEN y-1 AND y+1
-- -------------------------------------------------------------------------
CREATE INDEX idx_geonames_cities_lat_lon
    ON geonames_cities (latitude, longitude);

-- -------------------------------------------------------------------------
-- Query 3: Filter by country
--   WHERE country_code = 'IN'
-- -------------------------------------------------------------------------
CREATE INDEX idx_geonames_cities_country_code
    ON geonames_cities (country_code);

-- -------------------------------------------------------------------------
-- Query 4: Filter by state, or by the finer region (admin2)
--   WHERE state  = 'Maharashtra'
--   WHERE region = 'Mumbai Suburban'
-- -------------------------------------------------------------------------
CREATE INDEX idx_geonames_cities_state
    ON geonames_cities (state(191));
CREATE INDEX idx_geonames_cities_region
    ON geonames_cities (region(191));

-- -------------------------------------------------------------------------
-- Query 5: Cities within a specific state of a specific country
--   WHERE country_code = 'IN' AND state = 'Maharashtra'
-- -------------------------------------------------------------------------
CREATE INDEX idx_geonames_cities_country_state
    ON geonames_cities (country_code, state(191));

-- -------------------------------------------------------------------------
-- The eight columns most callers actually want, nothing else.
-- Plain projection of geonames_cities — no joins, so it uses that table's
-- indexes directly:
--   SELECT * FROM locations WHERE city = 'Mumbai';
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
