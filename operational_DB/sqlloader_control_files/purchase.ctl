OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'purchase.csv'
BADFILE 'purchase.bad'
DISCARDFILE 'purchase.dsc'
APPEND
INTO TABLE purchase
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    purchase_ID,
    product_ID,
    br_ID,
    sup_ID,
    purchase_qty,
    purchase_date DATE 'YYYY-MM-DD',
    purchase_unit_cost
)
