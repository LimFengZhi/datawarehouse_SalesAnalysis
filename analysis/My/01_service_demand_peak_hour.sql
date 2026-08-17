-- ===================================================================
-- 01_service_demand_peak_hour.sql
-- SERVICE ANALYSIS - DEMAND, SEASONALITY & PEAK-HOUR PRODUCTIVITY
--   year trend  ->  seasonality  ->  branch  ->  day/hour  ->  staffing
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\My\01_service_demand_peak_hour.sql
--
-- PARAMETERS (prompted)
--   branch       city or name, e.g. Ipoh   - or ALL   (default ALL)
--   focus year   the year to zoom into                (default 2025)
--
-- WHAT IT ANSWERS
--   1. How has service demand (reservations) trended year over year,
--      and which months carry each year (seasonality)?
--   2. Within the focus year, which day of the week and which hour of
--      the day are busiest (peak-hour demand)?
--   3. Is staff presence actually matched to that demand curve, or are
--      some hour-bands overloaded relative to how many staff handled
--      reservations in them (productivity/staffing gap)?
--
-- SCOPE NOTE
--   Only res_status = 'Completed' rows count here - by design, this
--   report is about realised demand. Cancelled / No-Show behaviour is a
--   deliberately separate question, covered by
--   03_reservation_reliability.sql.
--
-- MEASURES  (reservation_fact, Completed lines only)
--   Reservations  = COUNT(res_det_ID)
--   Revenue (RM)  = serv_total_amt - serv_tax_amt, EXCLUDING tax (SST
--                   is passed on to the government, it is not income).
--                   The fact no longer stores serv_price directly -
--                   serv_total_amt is populated as
--                   service_dim.serv_price - discount + tax, so
--                   subtracting tax back out recovers price - discount
--                   without a service_dim join.
--   Avg duration  = AVG(res_duration) in minutes
--   Staff active  = COUNT(DISTINCT staff_key) of staff who actually
--                   handled a reservation in that hour/band - the only
--                   staff-presence signal available (there is no shift
--                   roster table), so it is a floor, not a headcount.
--                   Note this is counted across the WHOLE focus year,
--                   so it can saturate at "every staff the branch has"
--                   once enough days are covered - read RES PER STAFF
--                   as a relative, not absolute, workload signal
--   Res per staff = reservations / staff active - a workload/pressure
--                   ratio, not a pay figure
--
-- DIMENSIONS USED  (four)
--   date_dim     cal_year, cal_month_name, day_week, weekday_ind -> the
--                drill path (year -> month -> day of week). day_week has
--                no stored sort-order column, so sections 4A/5 derive one
--                with a CASE on the first 3 letters (Mon=1 ... Sun=7).
--   branch_dim   br_city / br_name                 -> section 3, filter
--   staff_dim    st_position                        -> section 5 (the
--                single job-title column; there is no separate st_role)
--   service_dim                                     -> join, keeps the
--                grain correct even though category is not broken out
--                here (see a Service Portfolio Mix report for that cut)
--   plus start_hour, derived from reservation_fact.start_time via
--   TO_CHAR(start_time,'HH24') - the fact no longer stores a dedicated
--   start_hour column.
--
-- REPORT SECTIONS (the drill-down path)
--   1  RESERVATION DEMAND PER YEAR          2018-2025 overview
--   2  SEASONALITY - DEMAND BY MONTH        years ACROSS, month rows
--   3  FOCUS YEAR - DEMAND BY BRANCH        always all branches
--   4A FOCUS YEAR - DEMAND BY DAY OF WEEK
--   4B FOCUS YEAR - DEMAND BY HOUR OF DAY   the peak-hour table
--   5  FOCUS YEAR - STAFF WORKLOAD BY HOUR-BAND
--   6  SUMMARY STATISTICS                   grouped OVERALL / FOCUS YEAR
--   Sections 1, 2, 4A, 4B, 5 and 6 honour the branch filter; section 3
--   always shows every branch so there is something to compare against.
--
-- WHAT TO LOOK FOR
--   - Section 1: April 2020 (MCO 1.0) and Jun-Aug 2021 (FMCO) show
--     ZERO completed reservations - salons were legally closed
--   - Section 2: spikes around the Malaysian festive calendar (Chinese
--     New Year, Hari Raya, Deepavali, Christmas) - date_dim's holiday
--     flags are what drive those months up
--   - Section 4B: expect a small number of hours to carry most of the
--     day's volume - that is the window worth staffing for
--   - Section 5: a high reservations-per-staff figure in a band with
--     few distinct staff active is the understaffed window
--
-- WHY "PAGE: 1" NEVER CHANGES
--   SQL.PNO in the TTITLE (see below) counts pages WITHIN the current
--   SELECT's own output, driven by PAGESIZE (60 lines). Every table in
--   this report is far shorter than 60 lines, so no section ever rolls
--   over to a second page - PAGE: 1 on every section is expected, not
--   a bug. The 1 / 2 / 3 / 4A ... numbers in each section's own title
--   are the real section index; SQL.PNO is unrelated to that.
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

-- ---- values reused in every title ---------------------------------
-- TERMOUT OFF hides these helper queries (only works when the file is
-- run with @, which is how this report is meant to be run).
SET TERMOUT OFF
COLUMN run_dt    NEW_VALUE run_dt    NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN focus_y    NEW_VALUE focus_y    NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;

COLUMN br_label   NEW_VALUE br_label   NOPRINT
SELECT CASE WHEN UPPER(TRIM('&branch')) IN ('', 'ALL') THEN 'ALL BRANCHES'
            ELSE UPPER(TRIM('&branch')) END AS br_label
FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

-- The branch filter, used in sections 1, 2, 4A, 4B and 5. Matches on
-- the branch NAME with LIKE, so 'Ipoh', 'ipoh' and 'Glow Beauty Ipoh'
-- all work.
--   (UPPER(TRIM('&branch')) IN ('', 'ALL')
--    OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')

SPOOL service_demand_peak_hour_output.txt


-- ###################################################################
-- SECTION 1 - RESERVATION DEMAND PER YEAR
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. RESERVATION DEMAND PER YEAR' SKIP 1 -
       CENTER '&br_label, 2018 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year        HEADING 'YEAR'             FORMAT 9999
COLUMN num_reservations HEADING 'RESERVATIONS'    FORMAT 999,999
COLUMN revenue          HEADING 'REVENUE (RM)'    FORMAT 999,999,990.00
COLUMN avg_duration     HEADING 'AVG DUR|(MIN)'   FORMAT 990.0
COLUMN yoy_pct          HEADING 'DEMAND|YOY %'    FORMAT S990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF num_reservations revenue ON REPORT

WITH yearly AS (
    SELECT d.cal_year,
           COUNT(f.res_det_ID)                        AS num_reservations,
           SUM(f.serv_total_amt - f.serv_tax_amt)      AS revenue,
           AVG(f.res_duration)                         AS avg_duration
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY d.cal_year
)
SELECT cal_year, num_reservations, revenue, avg_duration,
       ROUND( (num_reservations - LAG(num_reservations) OVER (ORDER BY cal_year))
             / NULLIF(LAG(num_reservations) OVER (ORDER BY cal_year), 0) * 100, 1) AS yoy_pct
FROM   yearly
ORDER  BY cal_year;


-- ###################################################################
-- SECTION 2 - SEASONALITY: DEMAND BY MONTH  (years across)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. SEASONALITY: RESERVATION DEMAND BY MONTH' SKIP 1 -
       CENTER '&br_label, 2018 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN month_name  HEADING 'MONTH'      FORMAT A10
COLUMN y2018       HEADING '2018'       FORMAT 99,999
COLUMN y2019       HEADING '2019'       FORMAT 99,999
COLUMN y2020       HEADING '2020'       FORMAT 99,999
COLUMN y2021       HEADING '2021'       FORMAT 99,999
COLUMN y2022       HEADING '2022'       FORMAT 99,999
COLUMN y2023       HEADING '2023'       FORMAT 99,999
COLUMN y2024       HEADING '2024'       FORMAT 99,999
COLUMN y2025       HEADING '2025'       FORMAT 99,999
COLUMN total_res   HEADING 'TOTAL'      FORMAT 999,999
COLUMN share_pct   HEADING 'SHARE|%'    FORMAT 90.0
COLUMN month_num   NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL MONTHS' OF y2018 y2019 y2020 y2021 y2022 y2023 y2024 y2025 total_res ON REPORT

WITH monthly AS (
    SELECT d.cal_month_name AS month_name, MOD(d.cal_year_month, 100) AS month_num,
           d.cal_year, COUNT(f.res_det_ID) AS num_res
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY d.cal_month_name, MOD(d.cal_year_month, 100), d.cal_year
)
SELECT month_name,
       SUM(CASE WHEN cal_year = 2018 THEN num_res END) AS y2018,
       SUM(CASE WHEN cal_year = 2019 THEN num_res END) AS y2019,
       SUM(CASE WHEN cal_year = 2020 THEN num_res END) AS y2020,
       SUM(CASE WHEN cal_year = 2021 THEN num_res END) AS y2021,
       SUM(CASE WHEN cal_year = 2022 THEN num_res END) AS y2022,
       SUM(CASE WHEN cal_year = 2023 THEN num_res END) AS y2023,
       SUM(CASE WHEN cal_year = 2024 THEN num_res END) AS y2024,
       SUM(CASE WHEN cal_year = 2025 THEN num_res END) AS y2025,
       SUM(num_res)                                       AS total_res,
       ROUND(RATIO_TO_REPORT(SUM(num_res)) OVER () * 100, 1) AS share_pct,
       month_num
FROM   monthly
GROUP  BY month_name, month_num
ORDER  BY month_num;


-- ###################################################################
-- SECTION 3 - FOCUS YEAR: DEMAND BY BRANCH  (always all branches)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. FOCUS YEAR &focus_y: DEMAND BY BRANCH' SKIP 1 -
       CENTER 'ALL BRANCHES FOR COMPARISON' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk              HEADING 'RANK'              FORMAT 99
COLUMN br_city           HEADING 'BRANCH'            FORMAT A15
COLUMN num_reservations  HEADING 'RESERVATIONS'      FORMAT 99,999
COLUMN revenue           HEADING 'REVENUE (RM)'      FORMAT 999,999,990.00
COLUMN avg_duration      HEADING 'AVG DUR|(MIN)'     FORMAT 990.0
COLUMN share_pct         HEADING 'SHARE OF|DEMAND %' FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF num_reservations revenue ON REPORT

WITH br AS (
    SELECT b.br_ID, b.br_city,
           COUNT(f.res_det_ID)                      AS num_reservations,
           SUM(f.serv_total_amt - f.serv_tax_amt)    AS revenue,
           AVG(f.res_duration)                       AS avg_duration
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    GROUP  BY b.br_ID, b.br_city
)
SELECT RANK() OVER (ORDER BY num_reservations DESC) AS rnk,
       br_city, num_reservations, revenue, avg_duration,
       ROUND(RATIO_TO_REPORT(num_reservations) OVER () * 100, 1) AS share_pct
FROM   br
ORDER  BY rnk;


-- ###################################################################
-- SECTION 4A - FOCUS YEAR: DEMAND BY DAY OF WEEK
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4A. FOCUS YEAR &focus_y: DEMAND BY DAY OF WEEK' SKIP 1 -
       CENTER '&br_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN day_week       HEADING 'DAY'            FORMAT A10
COLUMN weekday_ind    HEADING 'WEEKDAY|(Y/N)'  FORMAT A7
COLUMN num_reservations HEADING 'RESERVATIONS' FORMAT 99,999
COLUMN revenue          HEADING 'REVENUE (RM)' FORMAT 999,999,990.00
COLUMN share_pct        HEADING 'SHARE|%'      FORMAT 990.0
COLUMN day_sort         NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL DAYS' OF num_reservations revenue ON REPORT

-- date_dim carries no day-of-week sort order (day_num_week was dropped
-- from the schema), so it is derived here from the first 3 letters of
-- day_week: Monday = 1 ... Sunday = 7.
WITH dow AS (
    SELECT d.day_week,
           CASE UPPER(SUBSTR(d.day_week, 1, 3))
                WHEN 'MON' THEN 1 WHEN 'TUE' THEN 2 WHEN 'WED' THEN 3
                WHEN 'THU' THEN 4 WHEN 'FRI' THEN 5 WHEN 'SAT' THEN 6
                WHEN 'SUN' THEN 7 END           AS day_sort,
           d.weekday_ind,
           COUNT(f.res_det_ID)                          AS num_reservations,
           SUM(f.serv_total_amt - f.serv_tax_amt)        AS revenue
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY d.day_week, d.weekday_ind
)
SELECT day_week, weekday_ind, num_reservations, revenue,
       ROUND(RATIO_TO_REPORT(num_reservations) OVER () * 100, 1) AS share_pct,
       day_sort
FROM   dow
ORDER  BY day_sort;


-- ###################################################################
-- SECTION 4B - FOCUS YEAR: DEMAND BY HOUR OF DAY  (the peak-hour table)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4B. FOCUS YEAR &focus_y: DEMAND BY HOUR OF DAY' SKIP 1 -
       CENTER '&br_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN start_hour       HEADING 'HOUR'          FORMAT 99
COLUMN num_reservations HEADING 'RESERVATIONS'  FORMAT 99,999
COLUMN revenue          HEADING 'REVENUE (RM)'  FORMAT 999,999,990.00
COLUMN staff_active     HEADING 'STAFF|ACTIVE'  FORMAT 9990
COLUMN res_per_staff    HEADING 'RES PER|STAFF' FORMAT 990.0
COLUMN share_pct        HEADING 'SHARE|%'       FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL HOURS' OF num_reservations revenue ON REPORT

WITH hr AS (
    SELECT TO_NUMBER(TO_CHAR(f.start_time, 'HH24'))  AS start_hour,
           COUNT(f.res_det_ID)                          AS num_reservations,
           SUM(f.serv_total_amt - f.serv_tax_amt)        AS revenue,
           COUNT(DISTINCT f.staff_key)                   AS staff_active
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY TO_NUMBER(TO_CHAR(f.start_time, 'HH24'))
)
SELECT start_hour, num_reservations, revenue, staff_active,
       ROUND(num_reservations / NULLIF(staff_active, 0), 1)      AS res_per_staff,
       ROUND(RATIO_TO_REPORT(num_reservations) OVER () * 100, 1) AS share_pct
FROM   hr
ORDER  BY start_hour;


-- ###################################################################
-- SECTION 5 - FOCUS YEAR: STAFF WORKLOAD BY HOUR-BAND
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. FOCUS YEAR &focus_y: STAFF WORKLOAD BY HOUR-BAND' SKIP 1 -
       CENTER '&br_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN hour_band        HEADING 'HOUR BAND'         FORMAT A22
COLUMN num_reservations HEADING 'RESERVATIONS'      FORMAT 99,999
COLUMN revenue          HEADING 'REVENUE (RM)'      FORMAT 999,999,990.00
COLUMN staff_active     HEADING 'STAFF|ACTIVE'      FORMAT 9990
COLUMN res_per_staff    HEADING 'RES PER|STAFF'     FORMAT 990.0
COLUMN therapists_active HEADING 'THERAPISTS|ACTIVE' FORMAT 9990
COLUMN band_order       NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL HOURS' OF num_reservations revenue ON REPORT

WITH banded AS (
    SELECT CASE WHEN start_hour BETWEEN 9  AND 11 THEN 1
                WHEN start_hour BETWEEN 12 AND 16 THEN 2
                WHEN start_hour BETWEEN 17 AND 20 THEN 3
                ELSE 4 END AS band_order,
           CASE WHEN start_hour BETWEEN 9  AND 11 THEN 'Morning (9am-12pm)'
                WHEN start_hour BETWEEN 12 AND 16 THEN 'Afternoon (12pm-5pm)'
                WHEN start_hour BETWEEN 17 AND 20 THEN 'Evening (5pm-9pm)'
                ELSE 'Other Hours' END AS hour_band,
           staff_key, st_position, res_det_ID, revenue
    FROM (
        SELECT f.staff_key, s.st_position, f.res_det_ID,
               TO_NUMBER(TO_CHAR(f.start_time, 'HH24'))  AS start_hour,
               f.serv_total_amt - f.serv_tax_amt         AS revenue
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        JOIN   staff_dim  s ON s.staff_key  = f.staff_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
               OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    )
)
SELECT band_order, hour_band,
       COUNT(res_det_ID)                                          AS num_reservations,
       SUM(revenue)                                                AS revenue,
       COUNT(DISTINCT staff_key)                                   AS staff_active,
       ROUND(COUNT(res_det_ID) / NULLIF(COUNT(DISTINCT staff_key), 0), 1) AS res_per_staff,
       COUNT(DISTINCT CASE WHEN st_position IN ('Beauty Therapist', 'Senior Therapist')
                            THEN staff_key END)                    AS therapists_active
FROM   banded
GROUP  BY band_order, hour_band
ORDER  BY band_order;


-- ###################################################################
-- SECTION 6 - SUMMARY STATISTICS
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 6. SERVICE DEMAND SUMMARY STATISTICS' SKIP 1 -
       CENTER '&br_label, 2018 - 2025, FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC'  FORMAT A38
COLUMN metric_value HEADING 'VALUE'   FORMAT A38

WITH lines AS (
    SELECT d.cal_year, d.cal_month_name, MOD(d.cal_year_month, 100) AS month_num,
           d.day_week,
           TO_NUMBER(TO_CHAR(f.start_time, 'HH24'))    AS start_hour,
           f.staff_key, f.res_det_ID,
           f.serv_total_amt - f.serv_tax_amt           AS revenue
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
),
-- branch totals ignore the branch filter on purpose - Section 3 above
-- already always shows every branch, so "Top Branch by Reservations"
-- stays consistent with that and is not filtered either
branch_totals AS (
    SELECT b.br_city, COUNT(f.res_det_ID) AS num_res
    FROM   reservation_fact f
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    GROUP  BY b.br_city
),
-- one-row helper blocks, CROSS JOINed below (Oracle 11g rejects KEEP
-- scalar subqueries inside an aggregate SELECT list - ORA-00937)
totals AS (
    SELECT COUNT(res_det_ID)          AS num_reservations,
           SUM(revenue)               AS revenue,
           COUNT(DISTINCT cal_year)   AS num_years
    FROM   lines
),
by_year AS (
    SELECT cal_year, COUNT(res_det_ID) AS num_res FROM lines GROUP BY cal_year
),
by_month AS (
    SELECT cal_month_name, month_num, COUNT(res_det_ID) AS num_res
    FROM   lines GROUP BY cal_month_name, month_num
),
by_dow_focus AS (
    SELECT day_week, COUNT(res_det_ID) AS num_res
    FROM   lines WHERE cal_year = &focus_year GROUP BY day_week
),
by_hour_focus AS (
    SELECT start_hour, COUNT(res_det_ID) AS num_res, COUNT(DISTINCT staff_key) AS staff_active
    FROM   lines WHERE cal_year = &focus_year GROUP BY start_hour
),
yr AS (
    SELECT MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY num_res DESC) AS best_year,
           MAX(num_res)                                               AS best_year_res,
           MIN(cal_year) KEEP (DENSE_RANK LAST  ORDER BY num_res DESC) AS worst_year,
           MIN(num_res)                                               AS worst_year_res
    FROM   by_year
),
mo AS (
    SELECT MAX(cal_month_name) KEEP (DENSE_RANK FIRST ORDER BY num_res DESC) AS busiest_month,
           MAX(num_res)                                                    AS busiest_month_res
    FROM   by_month
),
dw AS (
    SELECT MAX(day_week) KEEP (DENSE_RANK FIRST ORDER BY num_res DESC) AS busiest_day,
           MAX(num_res)                                               AS busiest_day_res
    FROM   by_dow_focus
),
hf AS (
    SELECT MAX(start_hour) KEEP (DENSE_RANK FIRST ORDER BY num_res DESC) AS peak_hour,
           MAX(num_res)                                                 AS peak_hour_res,
           MAX(ROUND(num_res / NULLIF(staff_active, 0), 1))             AS max_res_per_staff
    FROM   by_hour_focus
),
bt AS (
    SELECT MAX(br_city) KEEP (DENSE_RANK FIRST ORDER BY num_res DESC) AS top_branch,
           MAX(num_res)                                              AS top_branch_res
    FROM   branch_totals
),
stats AS (
    SELECT t.*, yr.*, mo.*, dw.*, hf.*, bt.*
    FROM   totals t CROSS JOIN yr CROSS JOIN mo CROSS JOIN dw CROSS JOIN hf CROSS JOIN bt
)
SELECT '--- OVERALL ---' AS metric_name, ' ' AS metric_value FROM dual
UNION ALL SELECT 'Total Reservations',
       TRIM(TO_CHAR(num_reservations, '999,999,990'))                 FROM stats
UNION ALL SELECT 'Total Service Revenue (RM)',
       TRIM(TO_CHAR(revenue, '999,999,999,990.00'))                   FROM stats
UNION ALL SELECT 'Number of Years Covered',
       TO_CHAR(num_years)                                             FROM stats
UNION ALL SELECT 'Best Year (Demand)',
       TO_CHAR(best_year)  || '  (' || TRIM(TO_CHAR(best_year_res,  '999,999,990')) || ' reservations)' FROM stats
UNION ALL SELECT 'Worst Year (Demand)',
       TO_CHAR(worst_year) || '  (' || TRIM(TO_CHAR(worst_year_res, '999,999,990')) || ' reservations)' FROM stats
UNION ALL SELECT 'Busiest Month (All Years Combined)',
       busiest_month || '  (' || TRIM(TO_CHAR(busiest_month_res, '999,999,990')) || ' reservations)' FROM stats
UNION ALL SELECT 'Top Branch by Reservations',
       top_branch || '  (' || TRIM(TO_CHAR(top_branch_res, '999,999,990')) || ' reservations)' FROM stats
UNION ALL SELECT ' ', ' ' FROM dual
UNION ALL SELECT '--- FOCUS YEAR &focus_y ---', ' ' FROM dual
UNION ALL SELECT 'Busiest Day of Week',
       busiest_day || '  (' || TRIM(TO_CHAR(busiest_day_res, '999,999,990')) || ' reservations)' FROM stats
UNION ALL SELECT 'Peak Hour',
       TO_CHAR(peak_hour) || ':00  (' || TRIM(TO_CHAR(peak_hour_res, '999,999,990')) || ' reservations)' FROM stats
UNION ALL SELECT 'Peak Res-per-Staff Ratio',
       TRIM(TO_CHAR(max_res_per_staff, '990.0')) || ' per staff' FROM stats;

PROMPT
PROMPT +==========================================================+
PROMPT |    END OF SERVICE DEMAND AND PEAK-HOUR PRODUCTIVITY      |
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
