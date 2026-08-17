-- ===================================================================
-- 03_reservation_reliability.sql
-- RESERVATION RELIABILITY - CANCELLATION & NO-SHOW ANALYSIS
--   funnel trend  ->  revenue leakage  ->  service  ->  day  ->  branch
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\My\03_reservation_reliability.sql
--
-- PARAMETERS (prompted)
--   branch       city or name, e.g. Ipoh   - or ALL   (default ALL)
--   focus year   the year to zoom into                (default 2025)
--
-- WHAT IT ANSWERS
--   1. Of everything booked, how much actually happens? Cancellation
--      and No-Show rates trended 2019-2025 - is reliability improving
--      or getting worse as the business grows?
--   2. How much revenue does that represent - what's the RM value of
--      slots that were booked but never paid for?
--   3. Is unreliability concentrated in particular services, days of
--      the week, or branches - i.e. is there something specific worth
--      fixing, rather than a general problem?
--
-- SCOPE NOTE
--   01_service_demand_peak_hour.sql only ever counts res_status =
--   'Completed' rows - by design, it is about realised demand. This
--   report is the deliberate complement: it is ABOUT the Cancelled and
--   No-Show rows that report ignores, using every reservation
--   regardless of outcome as the base.
--
-- MEASURES  (reservation_fact, every status counted)
--   Total bookings    = COUNT(res_det_ID), all statuses
--   Completion rate %  = Completed / Total * 100
--   Cancellation rate % = Cancelled / Total * 100
--   No-Show rate %      = 'No-Show' / Total * 100
--   Lost revenue (RM)   = serv_price - serv_discount_amt, SUMMED over
--                         Cancelled + No-Show rows only - the value
--                         that was booked but never collected
--
-- DIMENSIONS USED  (three)
--   date_dim     cal_year, day_week, day_num_week  -> the drill path
--   branch_dim   br_city / br_name                  -> section 5, filter
--   service_dim  serv_category                       -> section 3
--
-- REPORT SECTIONS (the drill-down path)
--   1  RESERVATION STATUS FUNNEL PER YEAR     2019-2025, year rows
--   2  REVENUE LEAKAGE: CAPTURED VS LOST      2019-2025
--   3  FOCUS YEAR - RELIABILITY BY SERVICE CATEGORY
--   4  FOCUS YEAR - RELIABILITY BY DAY OF WEEK
--   5  FOCUS YEAR - RELIABILITY BY BRANCH     always all branches,
--                                             worst first
--   6  SUMMARY STATISTICS                     grouped OVERALL /
--                                             FOCUS YEAR
--   Sections 1, 2, 3, 4 and 6 honour the branch filter; section 5
--   always shows every branch so there is something to compare against.
--
-- WHAT TO LOOK FOR
--   - Section 1: rates should be fairly stable year to year - a year
--     that jumps is worth a closer look at what changed operationally
--   - Section 3: longer/pricier services likely cancel more often than
--     quick ones - people commit less easily to a big booking
--   - Section 4: weekend bookings may show different reliability than
--     weekday ones
--   - Section 5: ranked worst-first, so row 1 is the branch to
--     investigate first
--
-- WHY "PAGE: 1" NEVER CHANGES
--   SQL.PNO in the TTITLE counts pages WITHIN the current SELECT's own
--   output (driven by PAGESIZE = 60 lines). Every table here is far
--   shorter than that, so it never rolls to page 2 - PAGE: 1 on every
--   section is expected.
-- ===================================================================

-- reset anything a previous script left behind in this session
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 132
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

ACCEPT branch     CHAR   DEFAULT 'ALL' PROMPT 'Enter branch (e.g. Ipoh) or ALL for all branches (default ALL): '
ACCEPT focus_year NUMBER DEFAULT 2025  PROMPT 'Enter the focus year to zoom into (default 2025): '

SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN focus_y NEW_VALUE focus_y NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;

COLUMN br_label NEW_VALUE br_label NOPRINT
SELECT CASE WHEN UPPER(TRIM('&branch')) IN ('', 'ALL') THEN 'ALL BRANCHES'
            ELSE UPPER(TRIM('&branch')) END AS br_label
FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

-- The branch filter, used in sections 1, 2, 3, 4 and 6. Matches on the
-- branch NAME with LIKE, so 'Ipoh', 'ipoh' and 'Glow Beauty Ipoh' all
-- work.
--   (UPPER(TRIM('&branch')) IN ('', 'ALL')
--    OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')

SPOOL reservation_reliability_output.txt


-- ###################################################################
-- SECTION 1 - RESERVATION STATUS FUNNEL PER YEAR
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. RESERVATION STATUS FUNNEL PER YEAR' SKIP 1 -
       CENTER '&br_label, 2019 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year   HEADING 'YEAR'         FORMAT 9999
COLUMN total_bk   HEADING 'TOTAL|BOOKED'  FORMAT 999,999
COLUMN completed  HEADING 'COMPLETED'     FORMAT 999,999
COLUMN cancelled  HEADING 'CANCELLED'     FORMAT 999,999
COLUMN no_show    HEADING 'NO-SHOW'       FORMAT 999,999
COLUMN pending    HEADING 'STILL|PENDING' FORMAT 999,999
COLUMN comp_pct   HEADING 'COMPLETE|%'    FORMAT 990.0
COLUMN cancel_pct HEADING 'CANCEL|%'      FORMAT 990.0
COLUMN noshow_pct HEADING 'NO-SHOW|%'     FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF total_bk completed cancelled no_show pending ON REPORT

WITH yearly AS (
    SELECT d.cal_year,
           COUNT(f.res_det_ID)                                             AS total_bk,
           SUM(CASE WHEN f.res_status = 'Completed' THEN 1 ELSE 0 END)     AS completed,
           SUM(CASE WHEN f.res_status = 'Cancelled' THEN 1 ELSE 0 END)     AS cancelled,
           SUM(CASE WHEN f.res_status = 'No-Show'   THEN 1 ELSE 0 END)     AS no_show,
           SUM(CASE WHEN f.res_status IN ('Booked','Confirmed') THEN 1 ELSE 0 END) AS pending
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY d.cal_year
)
SELECT cal_year, total_bk, completed, cancelled, no_show, pending,
       ROUND(completed / NULLIF(total_bk, 0) * 100, 1) AS comp_pct,
       ROUND(cancelled / NULLIF(total_bk, 0) * 100, 1) AS cancel_pct,
       ROUND(no_show   / NULLIF(total_bk, 0) * 100, 1) AS noshow_pct
FROM   yearly
ORDER  BY cal_year;


-- ###################################################################
-- SECTION 2 - REVENUE LEAKAGE: CAPTURED VS LOST
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. REVENUE LEAKAGE: CAPTURED VS LOST' SKIP 1 -
       CENTER '&br_label, 2019 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year        HEADING 'YEAR'               FORMAT 9999
COLUMN captured_rev    HEADING 'CAPTURED|REV (RM)'  FORMAT 999,999,990.00
COLUMN lost_rev        HEADING 'LOST|REV (RM)'      FORMAT 999,999,990.00
COLUMN at_stake_rev    HEADING 'TOTAL AT|STAKE (RM)' FORMAT 999,999,990.00
COLUMN leakage_pct     HEADING 'LEAKAGE|%'          FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF captured_rev lost_rev at_stake_rev ON REPORT

WITH yearly AS (
    SELECT d.cal_year,
           SUM(CASE WHEN f.res_status = 'Completed'
                    THEN f.serv_price - f.serv_discount_amt ELSE 0 END) AS captured_rev,
           SUM(CASE WHEN f.res_status IN ('Cancelled','No-Show')
                    THEN f.serv_price - f.serv_discount_amt ELSE 0 END) AS lost_rev
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY d.cal_year
)
SELECT cal_year, captured_rev, lost_rev, captured_rev + lost_rev AS at_stake_rev,
       ROUND(lost_rev / NULLIF(captured_rev + lost_rev, 0) * 100, 1) AS leakage_pct
FROM   yearly
ORDER  BY cal_year;


-- ###################################################################
-- SECTION 3 - FOCUS YEAR: RELIABILITY BY SERVICE CATEGORY
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. FOCUS YEAR &focus_y: RELIABILITY BY SERVICE' SKIP 1 -
       CENTER '&br_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN serv_category HEADING 'SERVICE CATEGORY' FORMAT A20
COLUMN total_bk      HEADING 'TOTAL|BOOKED'     FORMAT 99,999
COLUMN cancelled     HEADING 'CANCELLED'         FORMAT 99,999
COLUMN no_show       HEADING 'NO-SHOW'           FORMAT 99,999
COLUMN cancel_pct    HEADING 'CANCEL|%'          FORMAT 990.0
COLUMN noshow_pct    HEADING 'NO-SHOW|%'         FORMAT 990.0
COLUMN lost_rev      HEADING 'LOST REV|(RM)'     FORMAT 999,999.00

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF total_bk cancelled no_show lost_rev ON REPORT

WITH cat AS (
    SELECT s.serv_category,
           COUNT(f.res_det_ID)                                         AS total_bk,
           SUM(CASE WHEN f.res_status = 'Cancelled' THEN 1 ELSE 0 END) AS cancelled,
           SUM(CASE WHEN f.res_status = 'No-Show'   THEN 1 ELSE 0 END) AS no_show,
           SUM(CASE WHEN f.res_status IN ('Cancelled','No-Show')
                    THEN f.serv_price - f.serv_discount_amt ELSE 0 END) AS lost_rev
    FROM   reservation_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   service_dim s ON s.service_key = f.service_key
    WHERE  d.cal_year = &focus_year
    AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY s.serv_category
)
SELECT serv_category, total_bk, cancelled, no_show,
       ROUND(cancelled / NULLIF(total_bk, 0) * 100, 1)             AS cancel_pct,
       ROUND(no_show   / NULLIF(total_bk, 0) * 100, 1)             AS noshow_pct,
       lost_rev
FROM   cat
ORDER  BY (cancelled + no_show) / NULLIF(total_bk, 0) DESC;


-- ###################################################################
-- SECTION 4 - FOCUS YEAR: RELIABILITY BY DAY OF WEEK
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. FOCUS YEAR &focus_y: RELIABILITY BY DAY' SKIP 1 -
       CENTER '&br_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN day_week    HEADING 'DAY'         FORMAT A10
COLUMN total_bk    HEADING 'TOTAL|BOOKED' FORMAT 99,999
COLUMN cancelled   HEADING 'CANCELLED'     FORMAT 99,999
COLUMN no_show     HEADING 'NO-SHOW'       FORMAT 99,999
COLUMN cancel_pct  HEADING 'CANCEL|%'      FORMAT 990.0
COLUMN noshow_pct  HEADING 'NO-SHOW|%'     FORMAT 990.0
COLUMN day_num_week NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL DAYS' OF total_bk cancelled no_show ON REPORT

WITH dow AS (
    SELECT d.day_week, d.day_num_week,
           COUNT(f.res_det_ID)                                         AS total_bk,
           SUM(CASE WHEN f.res_status = 'Cancelled' THEN 1 ELSE 0 END) AS cancelled,
           SUM(CASE WHEN f.res_status = 'No-Show'   THEN 1 ELSE 0 END) AS no_show
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  d.cal_year = &focus_year
    AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY d.day_week, d.day_num_week
)
SELECT day_week, total_bk, cancelled, no_show,
       ROUND(cancelled / NULLIF(total_bk, 0) * 100, 1) AS cancel_pct,
       ROUND(no_show   / NULLIF(total_bk, 0) * 100, 1) AS noshow_pct,
       day_num_week
FROM   dow
ORDER  BY day_num_week;


-- ###################################################################
-- SECTION 5 - FOCUS YEAR: RELIABILITY BY BRANCH  (always all, worst first)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. FOCUS YEAR &focus_y: RELIABILITY BY BRANCH' SKIP 1 -
       CENTER 'ALL BRANCHES, WORST FIRST' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk        HEADING 'RANK'         FORMAT 99
COLUMN br_city     HEADING 'BRANCH'       FORMAT A15
COLUMN total_bk    HEADING 'TOTAL|BOOKED' FORMAT 99,999
COLUMN cancelled   HEADING 'CANCELLED'     FORMAT 99,999
COLUMN no_show     HEADING 'NO-SHOW'       FORMAT 99,999
COLUMN unreliable_pct HEADING 'CANCEL+NO-|SHOW %' FORMAT 990.0
COLUMN lost_rev    HEADING 'LOST REV|(RM)' FORMAT 999,999.00

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF total_bk cancelled no_show lost_rev ON REPORT

WITH br AS (
    SELECT b.br_ID, b.br_city,
           COUNT(f.res_det_ID)                                         AS total_bk,
           SUM(CASE WHEN f.res_status = 'Cancelled' THEN 1 ELSE 0 END) AS cancelled,
           SUM(CASE WHEN f.res_status = 'No-Show'   THEN 1 ELSE 0 END) AS no_show,
           SUM(CASE WHEN f.res_status IN ('Cancelled','No-Show')
                    THEN f.serv_price - f.serv_discount_amt ELSE 0 END) AS lost_rev
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  d.cal_year = &focus_year
    GROUP  BY b.br_ID, b.br_city
)
SELECT RANK() OVER (ORDER BY (cancelled + no_show) / NULLIF(total_bk, 0) DESC) AS rnk,
       br_city, total_bk, cancelled, no_show,
       ROUND((cancelled + no_show) / NULLIF(total_bk, 0) * 100, 1) AS unreliable_pct,
       lost_rev
FROM   br
ORDER  BY rnk;


-- ###################################################################
-- SECTION 6 - SUMMARY STATISTICS
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 6. RESERVATION RELIABILITY SUMMARY STATISTICS' SKIP 1 -
       CENTER '&br_label, 2019 - 2025, FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC'  FORMAT A38
COLUMN metric_value HEADING 'VALUE'   FORMAT A38

WITH lines AS (
    SELECT d.cal_year, s.serv_category, b.br_city, f.res_status,
           f.serv_price - f.serv_discount_amt AS revenue
    FROM   reservation_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   service_dim s ON s.service_key = f.service_key
    WHERE (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
),
totals AS (
    SELECT COUNT(*)                                                     AS total_bk,
           SUM(CASE WHEN res_status = 'Completed' THEN 1 ELSE 0 END)    AS completed,
           SUM(CASE WHEN res_status = 'Cancelled' THEN 1 ELSE 0 END)    AS cancelled,
           SUM(CASE WHEN res_status = 'No-Show'   THEN 1 ELSE 0 END)    AS no_show,
           SUM(CASE WHEN res_status IN ('Cancelled','No-Show')
                    THEN revenue ELSE 0 END)                             AS lost_rev
    FROM   lines
),
by_year AS (
    SELECT cal_year,
           COUNT(*) AS total_bk,
           SUM(CASE WHEN res_status IN ('Cancelled','No-Show') THEN 1 ELSE 0 END) AS unreliable
    FROM   lines GROUP BY cal_year
),
yr AS (
    SELECT MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY unreliable / NULLIF(total_bk, 0) DESC) AS worst_year,
           MAX(ROUND(unreliable / NULLIF(total_bk, 0) * 100, 1))
               KEEP (DENSE_RANK FIRST ORDER BY unreliable / NULLIF(total_bk, 0) DESC)            AS worst_year_pct,
           MIN(cal_year) KEEP (DENSE_RANK LAST  ORDER BY unreliable / NULLIF(total_bk, 0) DESC) AS best_year,
           MIN(ROUND(unreliable / NULLIF(total_bk, 0) * 100, 1))
               KEEP (DENSE_RANK LAST  ORDER BY unreliable / NULLIF(total_bk, 0) DESC)            AS best_year_pct
    FROM   by_year
),
by_cat_focus AS (
    SELECT serv_category,
           COUNT(*) AS total_bk,
           SUM(CASE WHEN res_status IN ('Cancelled','No-Show') THEN 1 ELSE 0 END) AS unreliable
    FROM   lines WHERE cal_year = &focus_year GROUP BY serv_category
),
cf AS (
    SELECT MAX(serv_category) KEEP (DENSE_RANK FIRST ORDER BY unreliable / NULLIF(total_bk, 0) DESC) AS worst_cat,
           MAX(ROUND(unreliable / NULLIF(total_bk, 0) * 100, 1))
               KEEP (DENSE_RANK FIRST ORDER BY unreliable / NULLIF(total_bk, 0) DESC)                 AS worst_cat_pct
    FROM   by_cat_focus
),
by_branch_focus AS (
    SELECT br_city,
           COUNT(*) AS total_bk,
           SUM(CASE WHEN res_status IN ('Cancelled','No-Show') THEN 1 ELSE 0 END) AS unreliable
    FROM   lines WHERE cal_year = &focus_year GROUP BY br_city
),
bf AS (
    SELECT MAX(br_city) KEEP (DENSE_RANK FIRST ORDER BY unreliable / NULLIF(total_bk, 0) DESC) AS worst_branch,
           MAX(ROUND(unreliable / NULLIF(total_bk, 0) * 100, 1))
               KEEP (DENSE_RANK FIRST ORDER BY unreliable / NULLIF(total_bk, 0) DESC)           AS worst_branch_pct
    FROM   by_branch_focus
),
stats AS (
    SELECT t.*, yr.*, cf.*, bf.*
    FROM   totals t CROSS JOIN yr CROSS JOIN cf CROSS JOIN bf
)
SELECT '--- OVERALL ---' AS metric_name, ' ' AS metric_value FROM dual
UNION ALL SELECT 'Total Bookings',
       TRIM(TO_CHAR(total_bk, '999,999,990'))                          FROM stats
UNION ALL SELECT 'Completion Rate',
       TRIM(TO_CHAR(completed / NULLIF(total_bk, 0) * 100, '990.0')) || '%' FROM stats
UNION ALL SELECT 'Cancellation Rate',
       TRIM(TO_CHAR(cancelled / NULLIF(total_bk, 0) * 100, '990.0')) || '%' FROM stats
UNION ALL SELECT 'No-Show Rate',
       TRIM(TO_CHAR(no_show / NULLIF(total_bk, 0) * 100, '990.0')) || '%'   FROM stats
UNION ALL SELECT 'Total Revenue Lost (RM)',
       TRIM(TO_CHAR(lost_rev, '999,999,999,990.00'))                    FROM stats
UNION ALL SELECT 'Best Year (Most Reliable)',
       best_year || '  (' || TRIM(TO_CHAR(best_year_pct, '990.0')) || '% unreliable)' FROM stats
UNION ALL SELECT 'Worst Year (Least Reliable)',
       worst_year || '  (' || TRIM(TO_CHAR(worst_year_pct, '990.0')) || '% unreliable)' FROM stats
UNION ALL SELECT ' ', ' ' FROM dual
UNION ALL SELECT '--- FOCUS YEAR &focus_y ---', ' ' FROM dual
UNION ALL SELECT 'Worst Service Category',
       worst_cat || '  (' || TRIM(TO_CHAR(worst_cat_pct, '990.0')) || '% unreliable)' FROM stats
UNION ALL SELECT 'Worst Branch',
       worst_branch || '  (' || TRIM(TO_CHAR(worst_branch_pct, '990.0')) || '% unreliable)' FROM stats;

PROMPT
PROMPT +==========================================================+
PROMPT |     END OF RESERVATION RELIABILITY REPORT                |
PROMPT +==========================================================+
PROMPT

-- ===================================================================
-- tidy up so the next script starts clean
-- ===================================================================
SPOOL OFF
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE branch
UNDEFINE focus_year
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
