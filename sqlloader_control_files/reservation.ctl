OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'reservation.csv'
BADFILE 'reservation.bad'
DISCARDFILE 'reservation.dsc'
APPEND
INTO TABLE reservation
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    res_ID,
    cus_ID,
    br_ID,
    booking_date DATE 'YYYY-MM-DD',
    res_status
)
