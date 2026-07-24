-- MySQL: bulk-load raw GeoNames TSV files into staging tables.
-- Executed via: mysql < 02_load.sql
-- Requires --local-infile=1 on the mysql CLI (the driver.sh sets this).

LOAD DATA LOCAL INFILE 'data/cities1000.txt'
INTO TABLE cities1000
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t' ESCAPED BY '\\\\'
LINES TERMINATED BY '\n'
IGNORE 0 LINES;

LOAD DATA LOCAL INFILE 'data/admin1CodesASCII.txt'
INTO TABLE admin1Codes
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t' ESCAPED BY '\\\\'
LINES TERMINATED BY '\n';

LOAD DATA LOCAL INFILE 'data/admin2Codes.txt'
INTO TABLE admin2Codes
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t' ESCAPED BY '\\\\'
LINES TERMINATED BY '\n';

LOAD DATA LOCAL INFILE 'data/countryInfo.txt'
INTO TABLE geonames_countries
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t' ESCAPED BY '\\\\'
LINES TERMINATED BY '\n';
