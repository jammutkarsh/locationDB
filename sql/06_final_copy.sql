BEGIN;

-- For faster lookups during the updates and deletes
CREATE INDEX idx_account_city_id ON account(city_id);

WITH acc AS (
    SELECT city_id
    FROM account
    WHERE city_id IS NOT NULL
)
DELETE FROM geonames_cities g
WHERE g.id NOT IN (SELECT city_id FROM acc);

UPDATE geonames_cities g
SET region   = v.region,
    geonameid = v.geonameid
FROM geonames_cities_v2 v
WHERE g.latitude = v.latitude
  AND g.longitude = v.longitude;

INSERT INTO geonames_cities (
    id, city, country, timezone, population, latitude, longitude,
    country_code, alternate_city_names, inserted_at, updated_at, region, geonameid
)
SELECT v.id, v.city, v.country,
       COALESCE(v.timezone, 'UTC'),
       v.population, v.latitude, v.longitude,
       v.country_code,
       COALESCE(v.alternate_city_names, ARRAY[]::text[]),
       v.inserted_at, v.updated_at, v.region, v.geonameid
FROM geonames_cities_v2 v
WHERE v.geonameid NOT IN (SELECT geonameid FROM geonames_cities);

CREATE UNIQUE INDEX idx_geonameid_geonames_cities ON geonames_cities(geonameid);

COMMIT;