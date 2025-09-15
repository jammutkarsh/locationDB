DROP TABLE IF EXISTS cities15000 CASCADE;

DROP TABLE IF EXISTS admin1Codes CASCADE;

DROP TABLE IF EXISTS admin2Codes CASCADE;

DROP TABLE IF EXISTS admin5Codes CASCADE;

DROP TABLE IF EXISTS cities_flattened CASCADE;

CREATE TABLE cities15000 (
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

CREATE TABLE cities_flattened (
	id BIGINT PRIMARY KEY,
	city TEXT,
	region TEXT,
	country TEXT,
	timezone TEXT,
	population BIGINT,
	latitude DOUBLE PRECISION,
	longitude DOUBLE PRECISION,
	country_code TEXT,
	alternate_names TEXT
);

-- Track last synced date for cities15000 incremental updates
CREATE TABLE IF NOT EXISTS sync_state (name TEXT PRIMARY KEY, last_synced DATE NOT NULL);

-- Seed only if missing
INSERT INTO
	sync_state (name, last_synced)
VALUES
	('cities15000', '2025-09-15') ON CONFLICT (name) DO NOTHING;

-- Helpful indexes for joins and lookups
CREATE INDEX IF NOT EXISTS idx_cities_admin1 ON cities15000 (country_code, admin1_code);

CREATE INDEX IF NOT EXISTS idx_cities_admin2 ON cities15000 (country_code, admin1_code, admin2_code);

CREATE INDEX IF NOT EXISTS idx_cities_cc ON cities15000 (country_code);