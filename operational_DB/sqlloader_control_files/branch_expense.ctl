OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'branch_expense.csv'
BADFILE 'branch_expense.bad'
DISCARDFILE 'branch_expense.dsc'
APPEND
INTO TABLE branch_expense
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    br_exp_ID,
    br_ID,
    br_utils_ID,
    billing_period,
    payment_amount,
    payment_date DATE 'YYYY-MM-DD'
)
