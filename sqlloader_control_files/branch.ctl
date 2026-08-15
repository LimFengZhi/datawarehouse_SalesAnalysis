OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'branch.csv'
BADFILE 'branch.bad'
DISCARDFILE 'branch.dsc'
APPEND
INTO TABLE branch
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    br_ID,
    br_name,
    br_address_line,
    br_city,
    br_state,
    br_postcode,
    br_phone,
    br_email,
    br_open_date DATE 'YYYY-MM-DD'
)
