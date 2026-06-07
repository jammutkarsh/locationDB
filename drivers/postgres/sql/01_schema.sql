-- Postgres schema for locationDB
-- Raw GeoNames staging tables + final output table + sync tracker.

DROP TABLE IF EXISTS cities1000 CASCADE;
DROP TABLE IF EXISTS admin1Codes CASCADE;
DROP TABLE IF EXISTS admin2Codes CASCADE;
DROP TABLE IF EXISTS admin5Codes CASCADE;

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

CREATE TABLE admin5Codes (
    geonameid BIGINT,
    adm5code  TEXT
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
    country              TEXT,
    timezone             TEXT,
    population           BIGINT DEFAULT 0,
    latitude             NUMERIC,
    longitude            NUMERIC,
    country_code         TEXT,
    alternate_city_names TEXT[],
    inserted_at          TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT now(),
    updated_at           TIMESTAMP(0) WITHOUT TIME ZONE DEFAULT now(),
    region               TEXT,
    geonameid            BIGINT UNIQUE
);
