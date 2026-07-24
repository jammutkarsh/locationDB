-- Postgres: flatten raw GeoNames staging tables into geonames_cities.

-- States / provinces (admin1). code looks like 'IN.16'.
INSERT INTO geonames_states (code, country_code, admin1_code, state, ascii_state, geonameid)
SELECT code, split_part(code, '.', 1), split_part(code, '.', 2), name, asciiname, geonameid
FROM admin1Codes
WHERE code LIKE '%.%'
ON CONFLICT (code) DO UPDATE SET
    country_code = EXCLUDED.country_code,
    admin1_code  = EXCLUDED.admin1_code,
    state        = EXCLUDED.state,
    ascii_state  = EXCLUDED.ascii_state,
    geonameid    = EXCLUDED.geonameid;

-- How the pieces line up:
--   country_code                  -> countryInfo.ISO      -> country name
--   country_code.admin1_code      -> admin1Codes.code     -> state name
--   country_code.admin1.admin2    -> admin2Codes.code     -> district name
INSERT INTO geonames_cities (
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
    string_to_array(NULLIF(c.alternatenames, ''), ','),
    c.timezone,
    c.country_code,
    c.country_code || '.' || c.admin1_code AS state_code,
    c.geonameid
FROM cities1000 c
LEFT JOIN admin1Codes a1 ON a1.code = c.country_code || '.' || c.admin1_code
LEFT JOIN admin2Codes a2 ON a2.code = c.country_code || '.' || c.admin1_code || '.' || c.admin2_code
LEFT JOIN geonames_countries o ON o.country_code = c.country_code
ON CONFLICT (geonameid) DO NOTHING;

-- The INSERT above skips geonameids that already exist, so rows written by an
-- older schema keep a NULL state / state_code and an ISO code in `country`.
-- Backfill them.
UPDATE geonames_cities gc
SET state_code = c.country_code || '.' || c.admin1_code,
    state      = COALESCE(a1.name, c.admin1_code),
    country    = COALESCE(o.country, c.country_code)
FROM cities1000 c
LEFT JOIN admin1Codes a1 ON a1.code = c.country_code || '.' || c.admin1_code
LEFT JOIN geonames_countries o ON o.country_code = c.country_code
WHERE c.geonameid = gc.geonameid
  AND (gc.state_code IS DISTINCT FROM c.country_code || '.' || c.admin1_code
       OR gc.state   IS DISTINCT FROM COALESCE(a1.name, c.admin1_code)
       OR gc.country IS DISTINCT FROM COALESCE(o.country, c.country_code));

-- Staging tables have served their purpose — neither populate nor sync reads
-- them again (sync loads its deltas into a TEMP table). Drop them so the
-- database holds only geonames_cities / _states / _countries + sync_state.
DROP TABLE cities1000;
DROP TABLE admin1Codes;
DROP TABLE admin2Codes;
