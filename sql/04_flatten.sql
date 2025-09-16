-- https://www.postgresql.org/docs/current/pgtrgm.html
-- CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Create geonames_cities_v2 table with the same structure as geonames_cities
CREATE TABLE IF NOT EXISTS geonames_cities_v2 (
    id bigint NOT NULL,
    city text,
    country text,
    timezone text,
    population bigint DEFAULT 0,
    latitude numeric,
    longitude numeric,
    country_code text,
    alternate_city_names text[],
    inserted_at timestamp(0) without time zone DEFAULT now(),
    updated_at timestamp(0) without time zone DEFAULT now(),
    region text,
    geonameid bigint
);

-- Add primary key and sequence for geonames_cities_v2
ALTER TABLE geonames_cities_v2 ALTER COLUMN id SET DEFAULT nextval('geonames_cities_id_seq'::regclass);
ALTER TABLE geonames_cities_v2 ADD CONSTRAINT geonames_cities_v2_pkey PRIMARY KEY (id);

-- Insert flattened data into geonames_cities_v2 from cities1000
INSERT INTO geonames_cities_v2 (
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
    string_to_array(c.alternatenames, ',')
FROM
    cities1000 c
    LEFT JOIN admin1Codes a1 ON a1.code = c.country_code || '.' || c.admin1_code
    LEFT JOIN admin2Codes a2 ON a2.code = c.country_code || '.' || c.admin1_code || '.' || c.admin2_code;

-- Ensure geonames_cities has the new columns (if not already done)
ALTER TABLE geonames_cities ADD COLUMN IF NOT EXISTS region text;
ALTER TABLE geonames_cities ADD COLUMN IF NOT EXISTS geonameid bigint;

-- Create unique index on geonames_cities for upsert
-- CREATE INDEX IF NOT EXISTS idx_geonames_cities_city ON geonames_cities (city);
-- CREATE INDEX IF NOT EXISTS idx_geonames_cities_city_trgm ON geonames_cities USING gin (city gin_trgm_ops);
