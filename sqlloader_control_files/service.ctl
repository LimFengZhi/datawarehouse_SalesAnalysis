OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'service.csv'
BADFILE 'service.bad'
DISCARDFILE 'service.dsc'
APPEND
INTO TABLE service
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    serv_ID,
    serv_name,
    serv_category,
    serv_description,
    serv_price
)
