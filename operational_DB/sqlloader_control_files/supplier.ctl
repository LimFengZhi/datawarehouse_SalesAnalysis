OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'supplier.csv'
BADFILE 'supplier.bad'
DISCARDFILE 'supplier.dsc'
APPEND
INTO TABLE supplier
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    sup_ID,
    sup_name,
    sup_phone,
    sup_email
)
