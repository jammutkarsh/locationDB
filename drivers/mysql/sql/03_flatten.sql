-- MySQL: flatten raw GeoNames staging tables into final tables.
-- Executed via: mysql < 03_flatten.sql

-- States / provinces (admin1). code looks like 'IN.16'.
INSERT IGNORE INTO geonames_states (code, country_code, admin1_code, state, ascii_state, geonameid)
SELECT
    code,
    SUBSTRING_INDEX(code, '.', 1),
    SUBSTRING_INDEX(code, '.', -1),
    name,
    asciiname,
    geonameid
FROM admin1Codes
WHERE code LIKE '%.%';

-- How the pieces line up:
--   country_code                  -> countryInfo.ISO      -> country name
--   country_code.admin1_code      -> admin1Codes.code     -> state name
--   country_code.admin1.admin2    -> admin2Codes.code     -> district name
INSERT IGNORE INTO geonames_cities (
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
    CONCAT(c.country_code, '.', c.admin1_code) AS state_code,
    c.geonameid
FROM cities1000 c
LEFT JOIN admin1Codes a1 ON a1.code = CONCAT(c.country_code, '.', c.admin1_code)
LEFT JOIN admin2Codes a2 ON a2.code = CONCAT(c.country_code, '.', c.admin1_code, '.', c.admin2_code)
LEFT JOIN geonames_countries o ON o.country_code = c.country_code;

-- Backfill rows written by an older schema that may have NULL state / state_code.
UPDATE geonames_cities gc
JOIN cities1000 c ON c.geonameid = gc.geonameid
LEFT JOIN admin1Codes a1 ON a1.code = CONCAT(c.country_code, '.', c.admin1_code)
LEFT JOIN geonames_countries o ON o.country_code = c.country_code
SET
    gc.state_code = CONCAT(c.country_code, '.', c.admin1_code),
    gc.state      = COALESCE(a1.name, c.admin1_code),
    gc.country    = COALESCE(o.country, c.country_code)
WHERE gc.state_code IS NULL
   OR gc.state IS NULL
   OR gc.country = c.country_code;

-- Staging tables have served their purpose — drop them.
DROP TABLE cities1000;
DROP TABLE admin1Codes;
DROP TABLE admin2Codes;
