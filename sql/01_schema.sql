DROP TABLE IF EXISTS cities1000 CASCADE;

DROP TABLE IF EXISTS admin1Codes CASCADE;

DROP TABLE IF EXISTS admin2Codes CASCADE;

DROP TABLE IF EXISTS admin5Codes CASCADE;

CREATE TABLE cities1000 (
	geonameid BIGINT PRIMARY KEY,
	name TEXT,
	asciiname TEXT,
	alternatenames TEXT,
	latitude DOUBLE PRECISION,
	longitude DOUBLE PRECISION,
	feature_class TEXT,
	feature_code TEXT,
	country_code TEXT,
	cc2 TEXT,
	admin1_code TEXT,
	admin2_code TEXT,
	admin3_code TEXT,
	admin4_code TEXT,
	population BIGINT,
	elevation TEXT,
	dem TEXT,
	timezone TEXT,
	modification TEXT
);

CREATE TABLE admin1Codes (
	code TEXT PRIMARY KEY,
	name TEXT,
	asciiname TEXT,
	geonameid BIGINT
);

CREATE TABLE admin2Codes (
	code TEXT PRIMARY KEY,
	name TEXT,
	asciiname TEXT,
	geonameid BIGINT
);

CREATE TABLE admin5Codes (geonameid BIGINT, adm5code TEXT);

-- Track last synced date for cities1000 incremental updates
CREATE TABLE IF NOT EXISTS sync_state (name TEXT PRIMARY KEY, last_synced DATE NOT NULL);

-- Seed only if missing
INSERT INTO
	sync_state (name, last_synced)
VALUES
	('cities1000', '2025-09-18') ON CONFLICT (name) DO NOTHING;

-- Helpful indexes for joins and lookups
CREATE INDEX IF NOT EXISTS idx_cities_admin1 ON cities1000 (country_code, admin1_code);

CREATE INDEX IF NOT EXISTS idx_cities_admin2 ON cities1000 (country_code, admin1_code, admin2_code);

CREATE INDEX IF NOT EXISTS idx_cities_cc ON cities1000 (country_code);