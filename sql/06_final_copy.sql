BEGIN;

-- For faster lookups during the updates and deletes
CREATE INDEX idx_account_city_id ON account(city_id);

UPDATE geonames_cities g
SET region   = v.region,
    geonameid = v.geonameid
FROM geonames_cities_v2 v, account c
WHERE g.id = c.city_id;

SELECT c.city_id, g.region, g.geonameid
FROM account c
LEFT JOIN geonames_cities g ON g.id = c.city_id
WHERE c.city_id IS NOT NULL
  AND (g.region IS NULL OR g.geonameid IS NULL);

DELETE FROM geonames_cities g
WHERE g.id NOT IN (SELECT city_id FROM account);

DELETE FROM geonames_cities g
WHERE NOT EXISTS (
    SELECT 1 FROM account c WHERE c.city_id = g.id
);

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
WHERE NOT EXISTS (
    SELECT 1 FROM geonames_cities g WHERE g.id = v.id
);


COMMIT;