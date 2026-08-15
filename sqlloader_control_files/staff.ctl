OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'staff.csv'
BADFILE 'staff.bad'
DISCARDFILE 'staff.dsc'
APPEND
INTO TABLE staff
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    st_ID,
    br_ID,
    st_first_name,
    st_last_name,
    st_role,
    st_position,
    st_address_line,
    st_city,
    st_state,
    st_postcode,
    st_DOB DATE 'YYYY-MM-DD',
    st_gender,
    st_email,
    st_phone,
    st_hire_date DATE 'YYYY-MM-DD',
    st_salary,
    st_status
)
