BEGIN;

-- Staging for daily modifications (same columns as cities1000)
CREATE TEMP TABLE mods (
	geonameid BIGINT,
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

-- Staging for daily deletions (geonameId, name, comment)
CREATE TEMP TABLE dels (
	geonameid BIGINT,
	name TEXT,
	comment TEXT
);

-- Combined files are created by sync.sh (may be empty)
\copy mods FROM 'data/mods.txt' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
\copy dels FROM 'data/deletes.txt' WITH (FORMAT csv, DELIMITER E'\t', NULL '');

-- Upsert modifications/new rows
INSERT INTO cities1000 AS c (
	geonameid, name, asciiname, alternatenames, latitude, longitude,
	feature_class, feature_code, country_code, cc2,
	admin1_code, admin2_code, admin3_code, admin4_code,
	population, elevation, dem, timezone, modification
)
SELECT
	m.geonameid, m.name, m.asciiname, m.alternatenames, m.latitude, m.longitude,
	m.feature_class, m.feature_code, m.country_code, m.cc2,
	m.admin1_code, m.admin2_code, m.admin3_code, m.admin4_code,
	m.population, m.elevation, m.dem, m.timezone, m.modification
FROM mods m
ON CONFLICT (geonameid) DO UPDATE SET
	name = EXCLUDED.name,
	asciiname = EXCLUDED.asciiname,
	alternatenames = EXCLUDED.alternatenames,
	latitude = EXCLUDED.latitude,
	longitude = EXCLUDED.longitude,
	feature_class = EXCLUDED.feature_class,
	feature_code = EXCLUDED.feature_code,
	country_code = EXCLUDED.country_code,
	cc2 = EXCLUDED.cc2,
	admin1_code = EXCLUDED.admin1_code,
	admin2_code = EXCLUDED.admin2_code,
	admin3_code = EXCLUDED.admin3_code,
	admin4_code = EXCLUDED.admin4_code,
	population = EXCLUDED.population,
	elevation = EXCLUDED.elevation,
	dem = EXCLUDED.dem,
	timezone = EXCLUDED.timezone,
	modification = EXCLUDED.modification;

-- Apply deletions
DELETE FROM cities1000
WHERE geonameid IN (SELECT geonameid FROM dels);

COMMIT;
