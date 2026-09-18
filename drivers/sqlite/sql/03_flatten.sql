-- SQLite: flatten raw GeoNames staging tables into geonames_cities.
-- alternate_city_names is stored as raw comma-separated TEXT (no array type).

-- Temporarily disable the FTS5 triggers so the bulk INSERT doesn't fire
-- them ~150k times row-by-row. We rebuild the index in one efficient pass
-- at the end of this file instead.
DROP TRIGGER IF EXISTS geonames_cities_ai;
DROP TRIGGER IF EXISTS geonames_cities_ad;
DROP TRIGGER IF EXISTS geonames_cities_au;

-- States / provinces (admin1). code looks like 'IN.16'.
INSERT INTO geonames_states (code, country_code, admin1_code, state, ascii_state, geonameid)
SELECT code, substr(code, 1, instr(code, '.') - 1), substr(code, instr(code, '.') + 1),
       name, asciiname, geonameid
FROM admin1Codes
WHERE instr(code, '.') > 0
ON CONFLICT (code) DO UPDATE SET
    state       = excluded.state,
    ascii_state = excluded.ascii_state,
    geonameid   = excluded.geonameid;

-- How the pieces line up:
--   country_code                  -> countryInfo.ISO      -> country name
--   country_code.admin1_code      -> admin1Codes.code     -> state name
--   country_code.admin1.admin2    -> admin2Codes.code     -> district name
--
-- Upsert keyed on id = geonameid: a city already in the .db keeps its id and
-- gets today's values; a new one is added. Cities missing from today's dump
-- (deleted/merged upstream, or population fell under 1000) are deliberately
-- kept, so an id a client stored never stops resolving. updated_at only moves
-- when a value actually changed, so re-running on the same input is a no-op.
INSERT INTO geonames_cities (
    id,
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
    c.geonameid,
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
LEFT JOIN geonames_countries o ON o.country_code = c.country_code
WHERE true  -- required: disambiguates the JOIN ... ON from the upsert's ON CONFLICT
ON CONFLICT (id) DO UPDATE SET
    city                 = excluded.city,
    region               = excluded.region,
    state                = excluded.state,
    country              = excluded.country,
    latitude             = excluded.latitude,
    longitude            = excluded.longitude,
    population           = excluded.population,
    alternate_city_names = excluded.alternate_city_names,
    timezone             = excluded.timezone,
    country_code         = excluded.country_code,
    state_code           = excluded.state_code,
    geonameid            = excluded.geonameid,
    updated_at           = datetime('now')
WHERE (city, region, state, country, latitude, longitude, population,
       alternate_city_names, timezone, country_code, state_code)
      IS NOT
      (excluded.city, excluded.region, excluded.state, excluded.country,
       excluded.latitude, excluded.longitude, excluded.population,
       excluded.alternate_city_names, excluded.timezone, excluded.country_code,
       excluded.state_code);

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

-- ---------------------------------------------------------------------------
-- Trigram index: decompose every city name + asciiname + alternate names into
-- 3-char substrings for typo-tolerant fuzzy search.
--
-- We join back to the cities1000 staging table (still present) to grab
-- asciiname (diacritic-free) and alternatenames (comma-separated).
--
-- Only cities in today's dump are (re)indexed: their old trigrams are cleared
-- first so a renamed city stops matching its old name. Cities kept from an
-- earlier build keep the trigrams they already had.
-- ---------------------------------------------------------------------------
DELETE FROM geonames_trigrams WHERE city_id IN (SELECT geonameid FROM cities1000);

INSERT OR IGNORE INTO geonames_trigrams (trigram, city_id)
WITH RECURSIVE
  pos(n) AS (
    VALUES(1)
    UNION ALL
    SELECT n+1 FROM pos WHERE n < 100
  ),
  alt_split(geonameid, name, rest) AS (
    SELECT geonameid,
           trim(substr(alternatenames, 1, instr(alternatenames||',',',')-1)),
           substr(alternatenames, instr(alternatenames||',',',')+1)
    FROM cities1000
    WHERE alternatenames IS NOT NULL AND alternatenames != ''
    UNION ALL
    SELECT geonameid,
           trim(substr(rest, 1, instr(rest||',',',')-1)),
           substr(rest, instr(rest||',',',')+1)
    FROM alt_split WHERE rest != ''
  ),
  names(city_id, name) AS (
    SELECT gc.id, lower(gc.city)
    FROM geonames_cities gc
    JOIN cities1000 c ON c.geonameid = gc.id
    UNION
    SELECT gc.id, lower(c.asciiname)
    FROM geonames_cities gc
    JOIN cities1000 c ON c.geonameid = gc.id
    WHERE lower(c.asciiname) != lower(gc.city)
    UNION
    SELECT gc.id, lower(s.name)
    FROM alt_split s
    JOIN geonames_cities gc ON gc.id = s.geonameid
    WHERE s.name != ''
  )
SELECT substr('  ' || name || '  ', pos.n, 3), city_id
FROM names CROSS JOIN pos
WHERE length(substr('  ' || name || '  ', pos.n, 3)) = 3;

-- Staging tables have served their purpose — neither populate nor sync reads
-- them again. Drop them and reclaim the pages, so the shipped .db holds only
-- geonames_cities / _states / _countries (+ FTS index, locations view, sync_state).
DROP TABLE cities1000;
DROP TABLE admin1Codes;
DROP TABLE admin2Codes;
VACUUM;

