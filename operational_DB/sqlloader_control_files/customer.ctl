OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'customer.csv'
BADFILE 'customer.bad'
DISCARDFILE 'customer.dsc'
APPEND
INTO TABLE customer
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    cus_ID,
    cus_first_name,
    cus_last_name,
    cus_age,
    cus_gender,
    cus_phone,
    cus_DOB DATE 'YYYY-MM-DD',
    cus_email,
    cus_loyalty_tier,
    cus_address_line,
    cus_city,
    cus_state,
    cus_postcode,
    cus_reg_date DATE 'YYYY-MM-DD'
)
