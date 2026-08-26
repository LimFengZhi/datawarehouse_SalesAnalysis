TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 140
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON

ACCEPT focus_year NUMBER DEFAULT 2025 PROMPT 'Enter the year to analyse (default 2025): '
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN focus_y NEW_VALUE focus_y NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;

COLUMN yr1 NEW_VALUE yr1 NOPRINT
COLUMN yr2 NEW_VALUE yr2 NOPRINT
COLUMN yr3 NEW_VALUE yr3 NOPRINT
SELECT TO_CHAR(&focus_year - 2) AS yr1,
       TO_CHAR(&focus_year - 1) AS yr2,
       TO_CHAR(&focus_year)     AS yr3
FROM   dual;
CLEAR COLUMNS
SET TERMOUT ON

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - A. RESERVATIONS BY BRANCH x YEAR' SKIP 1 -
       CENTER '&yr1 - &yr3 COMPARISON' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city   HEADING 'BRANCH' FORMAT A15
COLUMN y1        HEADING '&yr1'   FORMAT 99,999
COLUMN y2        HEADING '&yr2'   FORMAT 99,999
COLUMN y3        HEADING '&yr3'   FORMAT 99,999
COLUMN total_res HEADING 'TOTAL'  FORMAT 999,999

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL BRANCHES' OF y1 y2 y3 total_res ON REPORT

WITH yearly AS (
    SELECT b.br_ID, b.br_city, d.cal_year, COUNT(f.res_ID) AS num_res
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year BETWEEN &focus_year - 2 AND &focus_year
    GROUP  BY b.br_ID, b.br_city, d.cal_year
)
SELECT br_city,
       SUM(CASE WHEN cal_year = &focus_year - 2 THEN num_res END) AS y1,
       SUM(CASE WHEN cal_year = &focus_year - 1 THEN num_res END) AS y2,
       SUM(CASE WHEN cal_year = &focus_year     THEN num_res END) AS y3,
       SUM(num_res)                                                AS total_res
FROM   yearly
GROUP  BY br_ID, br_city
ORDER  BY total_res DESC;

CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - B. RESERVATIONS BY BRANCH x MONTH' SKIP 1 -
       CENTER 'FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city   HEADING 'BRANCH' FORMAT A15
COLUMN jan       HEADING 'JAN'    FORMAT 9,999
COLUMN feb       HEADING 'FEB'    FORMAT 9,999
COLUMN mar       HEADING 'MAR'    FORMAT 9,999
COLUMN apr       HEADING 'APR'    FORMAT 9,999
COLUMN may       HEADING 'MAY'    FORMAT 9,999
COLUMN jun       HEADING 'JUN'    FORMAT 9,999
COLUMN jul       HEADING 'JUL'    FORMAT 9,999
COLUMN aug       HEADING 'AUG'    FORMAT 9,999
COLUMN sep       HEADING 'SEP'    FORMAT 9,999
COLUMN oct       HEADING 'OCT'    FORMAT 9,999
COLUMN nov       HEADING 'NOV'    FORMAT 9,999
COLUMN dec       HEADING 'DEC'    FORMAT 9,999
COLUMN total_res HEADING 'TOTAL'  FORMAT 99,999

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL BRANCHES' OF jan feb mar apr may jun jul aug sep oct nov dec total_res ON REPORT

WITH monthly AS (
    SELECT b.br_ID, b.br_city, MOD(d.cal_year_month, 100) AS month_num,
           COUNT(f.res_ID) AS num_res
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    GROUP  BY b.br_ID, b.br_city, MOD(d.cal_year_month, 100)
)
SELECT br_city,
       SUM(CASE WHEN month_num = 1  THEN num_res END) AS jan,
       SUM(CASE WHEN month_num = 2  THEN num_res END) AS feb,
       SUM(CASE WHEN month_num = 3  THEN num_res END) AS mar,
       SUM(CASE WHEN month_num = 4  THEN num_res END) AS apr,
       SUM(CASE WHEN month_num = 5  THEN num_res END) AS may,
       SUM(CASE WHEN month_num = 6  THEN num_res END) AS jun,
       SUM(CASE WHEN month_num = 7  THEN num_res END) AS jul,
       SUM(CASE WHEN month_num = 8  THEN num_res END) AS aug,
       SUM(CASE WHEN month_num = 9  THEN num_res END) AS sep,
       SUM(CASE WHEN month_num = 10 THEN num_res END) AS oct,
       SUM(CASE WHEN month_num = 11 THEN num_res END) AS nov,
       SUM(CASE WHEN month_num = 12 THEN num_res END) AS dec,
       SUM(num_res)                                     AS total_res
FROM   monthly
GROUP  BY br_ID, br_city
ORDER  BY total_res DESC;

CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - C. RESERVATIONS BY BRANCH x TIME PERIOD' SKIP 1 -
       CENTER 'FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city   HEADING 'BRANCH'           FORMAT A15
COLUMN morning   HEADING 'MORNING (9-12)'   FORMAT 99,999
COLUMN afternoon HEADING 'AFTERNOON (12-5)' FORMAT 99,999
COLUMN evening   HEADING 'EVENING (5-9)'    FORMAT 99,999
COLUMN total_res HEADING 'TOTAL'            FORMAT 99,999

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL BRANCHES' OF morning afternoon evening total_res ON REPORT

WITH banded AS (
    SELECT b.br_ID, b.br_city, f.res_ID,
           CASE WHEN TO_NUMBER(TO_CHAR(f.start_time, 'HH24')) BETWEEN 9  AND 11 THEN 'morning'
                WHEN TO_NUMBER(TO_CHAR(f.start_time, 'HH24')) BETWEEN 12 AND 16 THEN 'afternoon'
                ELSE 'evening' END AS band
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    AND    TO_NUMBER(TO_CHAR(f.start_time, 'HH24')) BETWEEN 9 AND 20
)
SELECT br_city,
       COUNT(CASE WHEN band = 'morning'   THEN res_ID END) AS morning,
       COUNT(CASE WHEN band = 'afternoon' THEN res_ID END) AS afternoon,
       COUNT(CASE WHEN band = 'evening'   THEN res_ID END) AS evening,
       COUNT(res_ID)                                        AS total_res
FROM   banded
GROUP  BY br_ID, br_city
ORDER  BY total_res DESC;

CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - D. DEMAND SUMMARY - BRANCH, MONTH, TIME' SKIP 1 -
       CENTER 'FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC'  FORMAT A38
COLUMN metric_value HEADING 'VALUE'   FORMAT A55

WITH lines AS (
    SELECT b.br_ID, b.br_city, d.cal_month_name, MOD(d.cal_year_month, 100) AS month_num,
           TO_NUMBER(TO_CHAR(f.start_time, 'HH24'))    AS start_hour,
           f.res_ID, f.serv_total_amt - f.serv_tax_amt AS revenue
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
),
banded AS (
    SELECT l.*,
           CASE WHEN start_hour BETWEEN 9  AND 11 THEN 'Morning (9am-12pm)'
                WHEN start_hour BETWEEN 12 AND 16 THEN 'Afternoon (12pm-5pm)'
                WHEN start_hour BETWEEN 17 AND 20 THEN 'Evening (5pm-9pm)'
                END AS hour_band
    FROM   lines l
    WHERE  start_hour BETWEEN 9 AND 20
),
stats AS (
    SELECT
        (SELECT COUNT(res_ID) FROM lines)  AS num_reservations,
        (SELECT SUM(revenue)  FROM lines)  AS revenue,
        (SELECT br_city FROM
            (SELECT br_city, COUNT(res_ID) AS cnt
             FROM   lines GROUP BY br_ID, br_city ORDER BY cnt DESC)
         WHERE ROWNUM = 1)                 AS top_branch,
        (SELECT cnt FROM
            (SELECT COUNT(res_ID) AS cnt
             FROM   lines GROUP BY br_ID ORDER BY cnt DESC)
         WHERE ROWNUM = 1)                 AS top_branch_res,
        (SELECT cal_month_name FROM
            (SELECT cal_month_name, COUNT(res_ID) AS cnt
             FROM   lines GROUP BY cal_month_name, month_num ORDER BY cnt DESC)
         WHERE ROWNUM = 1)                 AS busiest_month,
        (SELECT cnt FROM
            (SELECT COUNT(res_ID) AS cnt
             FROM   lines GROUP BY cal_month_name, month_num ORDER BY cnt DESC)
         WHERE ROWNUM = 1)                 AS busiest_month_res,
        (SELECT hour_band FROM
            (SELECT hour_band, COUNT(res_ID) AS cnt
             FROM   banded GROUP BY hour_band ORDER BY cnt DESC)
         WHERE ROWNUM = 1)                 AS busiest_period,
        (SELECT cnt FROM
            (SELECT COUNT(res_ID) AS cnt
             FROM   banded GROUP BY hour_band ORDER BY cnt DESC)
         WHERE ROWNUM = 1)                 AS busiest_period_res
    FROM dual
)
SELECT 'Total Reservations' AS metric_name,
       TRIM(TO_CHAR(num_reservations, '999,999,990')) AS metric_value          FROM stats
UNION ALL SELECT 'Total Service Revenue (RM)',
       TRIM(TO_CHAR(revenue, '999,999,999,990.00'))                   FROM stats
UNION ALL SELECT ' ', ' ' FROM dual
UNION ALL SELECT 'Top Branch (Highest Demand)',
       top_branch || '  (' || TRIM(TO_CHAR(top_branch_res, '999,999,990')) || ' reservations)' FROM stats
UNION ALL SELECT 'Busiest Month',
       busiest_month || '  (' || TRIM(TO_CHAR(busiest_month_res, '999,999,990')) || ' reservations)' FROM stats
UNION ALL SELECT 'Busiest Time Period',
       busiest_period || '  (' || TRIM(TO_CHAR(busiest_period_res, '999,999,990')) || ' reservations)' FROM stats;

PROMPT
PROMPT +==========================================================+
PROMPT |   END OF RESERVATION DEMAND BY BRANCH, MONTH AND TIME    |
PROMPT +==========================================================+
PROMPT

TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE focus_year
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
