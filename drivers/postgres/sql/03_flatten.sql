-- Postgres: flatten raw GeoNames staging tables into geonames_cities.

INSERT INTO geonames_cities (
    city,
    latitude,
    longitude,
    region,
    geonameid,
    country,
    timezone,
    population,
    country_code,
    alternate_city_names
)
SELECT
    c.name,
    c.latitude,
    c.longitude,
    COALESCE(a2.name, a1.name, c.admin1_code) AS region,
    c.geonameid,
    c.country_code AS country,
    c.timezone,
    c.population,
    c.country_code,
    string_to_array(NULLIF(c.alternatenames, ''), ',')
FROM cities1000 c
LEFT JOIN admin1Codes a1 ON a1.code = c.country_code || '.' || c.admin1_code
LEFT JOIN admin2Codes a2 ON a2.code = c.country_code || '.' || c.admin1_code || '.' || c.admin2_code
ON CONFLICT (geonameid) DO NOTHING;
