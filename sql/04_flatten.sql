TRUNCATE geonames_cities;

INSERT INTO
	geonames_cities (
		id,
		city,
		region,
		country,
		timezone,
		population,
		latitude,
		longitude,
		country_code,
		alternate_names
	)
SELECT
	c.geonameid,
	c.name,
	COALESCE(a2.name, a1.name, c.admin1_code) AS region,
	c.country_code AS country,
	c.timezone,
	c.population,
	c.latitude,
	c.longitude,
	c.country_code,
	c.alternatenames
FROM
	cities15000 c
	LEFT JOIN admin1Codes a1 ON a1.code = c.country_code || '.' || c.admin1_code
	LEFT JOIN admin2Codes a2 ON a2.code = c.country_code || '.' || c.admin1_code || '.' || c.admin2_code;