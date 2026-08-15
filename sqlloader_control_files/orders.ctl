OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'orders.csv'
BADFILE 'orders.bad'
DISCARDFILE 'orders.dsc'
APPEND
INTO TABLE orders
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    order_ID,
    cus_ID,
    br_ID,
    st_ID,
    order_date DATE 'YYYY-MM-DD',
    order_status
)
