OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'order_detail.csv'
BADFILE 'order_detail.bad'
DISCARDFILE 'order_detail.dsc'
APPEND
INTO TABLE order_detail
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    order_det_ID,
    order_ID,
    product_ID,
    order_qty,
    order_discount,
    order_tax
)
