OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'product.csv'
BADFILE 'product.bad'
DISCARDFILE 'product.dsc'
APPEND
INTO TABLE product
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    product_ID,
    product_name,
    product_brand,
    product_category,
    product_desc,
    product_unit_price
)
