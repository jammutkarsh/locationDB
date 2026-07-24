-- SQLite: flatten raw GeoNames staging tables into geonames_cities.
-- alternate_city_names is stored as raw comma-separated TEXT (no array type).

-- Temporarily disable the FTS5 triggers so the bulk INSERT doesn't fire
-- them ~150k times row-by-row. We rebuild the index in one efficient pass
-- at the end of this file instead.
DROP TRIGGER IF EXISTS geonames_cities_ai;
DROP TRIGGER IF EXISTS geonames_cities_ad;
DROP TRIGGER IF EXISTS geonames_cities_au;

-- States / provinces (admin1). code looks like 'IN.16'.
INSERT OR IGNORE INTO geonames_states (code, country_code, admin1_code, state, ascii_state, geonameid)
SELECT code, substr(code, 1, instr(code, '.') - 1), substr(code, instr(code, '.') + 1),
       name, asciiname, geonameid
FROM admin1Codes
WHERE instr(code, '.') > 0;

-- How the pieces line up:
--   country_code                  -> countryInfo.ISO      -> country name
--   country_code.admin1_code      -> admin1Codes.code     -> state name
--   country_code.admin1.admin2    -> admin2Codes.code     -> district name
INSERT OR IGNORE INTO geonames_cities (
    city,
    region,
    state,
    country,
    latitude,
    longitude,
    population,
    alternate_city_names,
    timezone,
    country_code,
    state_code,
    geonameid
)
SELECT
    c.name,
    COALESCE(a2.name, a1.name, c.admin1_code) AS region,
    COALESCE(a1.name, c.admin1_code) AS state,
    COALESCE(o.country, c.country_code) AS country,
    c.latitude,
    c.longitude,
    c.population,
    c.alternatenames,  -- comma-separated string; split in application layer
    c.timezone,
    c.country_code,
    c.country_code || '.' || c.admin1_code AS state_code,
    c.geonameid
FROM cities1000 c
LEFT JOIN admin1Codes a1 ON a1.code = c.country_code || '.' || c.admin1_code
LEFT JOIN admin2Codes a2 ON a2.code = c.country_code || '.' || c.admin1_code || '.' || c.admin2_code
LEFT JOIN geonames_countries o ON o.country_code = c.country_code;

-- Build the FTS5 index in a single pass from the content table.
-- Much faster than per-row trigger inserts for the initial load.
INSERT INTO geonames_cities_fts(geonames_cities_fts) VALUES('rebuild');

-- Re-create the triggers so future incremental updates (sync) stay indexed.
CREATE TRIGGER geonames_cities_ai AFTER INSERT ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(rowid, city, alternate_city_names, state, region)
    VALUES (new.id, new.city, new.alternate_city_names, new.state, new.region);
END;

CREATE TRIGGER geonames_cities_ad AFTER DELETE ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(geonames_cities_fts, rowid, city, alternate_city_names, state, region)
    VALUES ('delete', old.id, old.city, old.alternate_city_names, old.state, old.region);
END;

CREATE TRIGGER geonames_cities_au AFTER UPDATE ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(geonames_cities_fts, rowid, city, alternate_city_names, state, region)
    VALUES ('delete', old.id, old.city, old.alternate_city_names, old.state, old.region);
    INSERT INTO geonames_cities_fts(rowid, city, alternate_city_names, state, region)
    VALUES (new.id, new.city, new.alternate_city_names, new.state, new.region);
END;

-- Staging tables have served their purpose — neither populate nor sync reads
-- them again. Drop them and reclaim the pages, so the shipped .db holds only
-- geonames_cities / _states / _countries (+ FTS index, locations view, sync_state).
DROP TABLE cities1000;
DROP TABLE admin1Codes;
DROP TABLE admin2Codes;
VACUUM;

