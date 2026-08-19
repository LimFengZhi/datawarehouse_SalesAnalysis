OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'branch_utils.csv'
BADFILE 'branch_utils.bad'
DISCARDFILE 'branch_utils.dsc'
APPEND
INTO TABLE branch_utils
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    br_exp_ID,
    br_ID,
    util_name,
    billing_period,
    payment_amount,
    payment_date DATE 'YYYY-MM-DD'
)
