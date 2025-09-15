SELECT
	COUNT(*) AS invalid_admin_codes
	-- c.name AS city_name
FROM
	cities15000 c
	LEFT JOIN admin1Codes a1 ON a1.code = c.country_code || '.' || c.admin1_code
	LEFT JOIN admin2Codes a2 ON a2.code = c.country_code || '.' || c.admin1_code || '.' || c.admin2_code
	LEFT JOIN admin5Codes a5 ON a5.adm5code = c.admin1_code
WHERE
	a1.code IS NULL
	AND a2.code IS NULL
	AND a5.adm5code IS NULL;