-- SQLite: flatten raw GeoNames staging tables into geonames_cities.
-- alternate_city_names is stored as raw comma-separated TEXT (no array type).

-- Temporarily disable the FTS5 triggers so the bulk INSERT doesn't fire
-- them ~150k times row-by-row. We rebuild the index in one efficient pass
-- at the end of this file instead.
DROP TRIGGER IF EXISTS geonames_cities_ai;
DROP TRIGGER IF EXISTS geonames_cities_ad;
DROP TRIGGER IF EXISTS geonames_cities_au;

INSERT OR IGNORE INTO geonames_cities (
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
    c.alternatenames   -- comma-separated string; split in application layer
FROM cities1000 c
LEFT JOIN admin1Codes a1 ON a1.code = c.country_code || '.' || c.admin1_code
LEFT JOIN admin2Codes a2 ON a2.code = c.country_code || '.' || c.admin1_code || '.' || c.admin2_code;

-- Build the FTS5 index in a single pass from the content table.
-- Much faster than per-row trigger inserts for the initial load.
INSERT INTO geonames_cities_fts(geonames_cities_fts) VALUES('rebuild');

-- Re-create the triggers so future incremental updates (sync) stay indexed.
CREATE TRIGGER geonames_cities_ai AFTER INSERT ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(rowid, city, alternate_city_names)
    VALUES (new.id, new.city, new.alternate_city_names);
END;

CREATE TRIGGER geonames_cities_ad AFTER DELETE ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(geonames_cities_fts, rowid, city, alternate_city_names)
    VALUES ('delete', old.id, old.city, old.alternate_city_names);
END;

CREATE TRIGGER geonames_cities_au AFTER UPDATE ON geonames_cities BEGIN
    INSERT INTO geonames_cities_fts(geonames_cities_fts, rowid, city, alternate_city_names)
    VALUES ('delete', old.id, old.city, old.alternate_city_names);
    INSERT INTO geonames_cities_fts(rowid, city, alternate_city_names)
    VALUES (new.id, new.city, new.alternate_city_names);
END;

