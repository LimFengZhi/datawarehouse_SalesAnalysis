OPTIONS (SKIP=1, ERRORS=50)
LOAD DATA
INFILE 'branch_utils_category.csv'
BADFILE 'branch_utils_category.bad'
DISCARDFILE 'branch_utils_category.dsc'
APPEND
INTO TABLE branch_utils_category
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
TRAILING NULLCOLS
(
    br_utils_ID,
    util_name
)
