OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'salary_payment.csv'
BADFILE 'salary_payment.bad'
DISCARDFILE 'salary_payment.dsc'
APPEND
INTO TABLE salary_payment
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    sal_pay_ID,
    st_ID,
    pay_period,
    base_amt,
    bonus_amt,
    deduction_amt,
    payment_date DATE 'YYYY-MM-DD'
)
