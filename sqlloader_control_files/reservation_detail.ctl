OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'reservation_detail.csv'
BADFILE 'reservation_detail.bad'
DISCARDFILE 'reservation_detail.dsc'
APPEND
INTO TABLE reservation_detail
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    res_det_ID,
    res_ID,
    st_ID,
    serv_ID,
    start_time DATE 'YYYY-MM-DD HH24:MI:SS',
    end_time DATE 'YYYY-MM-DD HH24:MI:SS',
    serv_discount,
    serv_tax
)
