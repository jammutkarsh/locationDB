\copy cities15000 FROM 'data/cities15000.txt' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
\copy admin1Codes  FROM 'data/admin1CodesASCII.txt' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
\copy admin2Codes  FROM 'data/admin2Codes.txt' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
\copy admin5Codes  FROM 'data/adminCode5.txt' WITH (FORMAT csv, DELIMITER E'\t', NULL '');
