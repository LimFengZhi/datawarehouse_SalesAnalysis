-- ===================================================================
-- 04_customer_demographics_regional.sql
-- CUSTOMER DEMOGRAPHICS & REGIONAL MARKET PENETRATION
--   base growth  ->  demographic mix  ->  regional spread  ->
--   branch catchment  ->  spend by age
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\My\04_customer_demographics_regional.sql
--
-- PARAMETERS (prompted)
--   state        e.g. Selangor, Johor  - or ALL         (default ALL)
--   focus year   the year to zoom into                  (default 2025)
--
-- WHAT IT ANSWERS
--   1. Who is the customer base and how is it growing - by age band,
--      gender, and home state?
--   2. Are branches drawing customers mainly from their own state, or
--      pulling in a lot of cross-region traffic?
--   3. Does spend per visit differ by age band - is any one segment
--      worth targeting harder?
--
-- SCOPE NOTE
--   Every other report in analysis\My drives off a transaction fact
--   (reservation_fact). This one leads with customer_dim itself -
--   who the customers ARE, not just what they bought - and only
--   brings in reservation_fact where a transactional angle (catchment,
--   spend) genuinely needs it. customer_dim is SCD2 (cus_loyalty_tier
--   can version), so every demographic query here filters
--   is_current_flag = 'Y' - otherwise a customer whose tier changed
--   would be counted twice.
--
-- MEASURES
--   Customers            = COUNT(DISTINCT cus_ID), current snapshot only
--   Home-state match %   = share of a branch's Completed reservations
--                          where the customer's cus_state equals the
--                          branch's br_state
--   Avg spend/reservation = (serv_price - serv_discount_amt) averaged
--                          per Completed reservation, by age band
--
-- DIMENSIONS USED  (three)
--   customer_dim  cus_age_band, cus_gender, cus_state, cus_reg_date
--   branch_dim    br_city / br_state                    -> section 4
--   date_dim      cal_year                                -> section 4, 5
--   plus reservation_fact for sections 4 and 5, where a transaction
--   count/amount is actually needed.
--
-- REPORT SECTIONS (the drill-down path)
--   1  CUSTOMER BASE GROWTH BY REGISTRATION YEAR   2019-2025, running
--                                                   total
--   2  DEMOGRAPHIC MIX: AGE BAND x GENDER           company-wide
--   3  REGIONAL DISTRIBUTION: HOME STATE            ranked
--   4  FOCUS YEAR - BRANCH CATCHMENT                home-state vs
--                                                    cross-region %
--   5  FOCUS YEAR - AVG SPEND BY AGE BAND           ranked
--   6  SUMMARY STATISTICS                           grouped OVERALL /
--                                                    FOCUS YEAR
--   Sections 1, 2 and 3 look at the WHOLE customer base and are not
--   filterable by state (there would be nothing left to compare
--   against); sections 4, 5 and 6 honour the state filter.
--
-- WHAT TO LOOK FOR
--   - Section 1: the running total should track the "customer base
--     grows from 26,000 to ..." figure documented in README.md
--   - Section 4: a branch with a LOW home-state match % is pulling
--     customers from further away than its own catchment - worth
--     knowing whether that is by design (a destination branch) or a
--     sign the branch's own state is under-penetrated
--   - Section 5: if spend doesn't vary much by age band, age-targeted
--     marketing is unlikely to move revenue much on its own
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

ACCEPT state      CHAR   DEFAULT 'ALL' PROMPT 'Enter customer home state (e.g. Selangor) or ALL (default ALL): '
ACCEPT focus_year NUMBER DEFAULT 2025  PROMPT 'Enter the focus year to zoom into (default 2025): '

SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN focus_y NEW_VALUE focus_y NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;

COLUMN st_label NEW_VALUE st_label NOPRINT
SELECT CASE WHEN UPPER(TRIM('&state')) IN ('', 'ALL') THEN 'ALL STATES'
            ELSE UPPER(TRIM('&state')) END AS st_label
FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

-- The state filter, used in sections 4, 5 and 6. Matches on cus_state
-- with LIKE, so 'Selangor' and 'selangor' both work.
--   (UPPER(TRIM('&state')) IN ('', 'ALL')
--    OR UPPER(c.cus_state) LIKE '%' || UPPER(TRIM('&state')) || '%')

SPOOL customer_demographics_regional_output.txt


-- ###################################################################
-- SECTION 1 - CUSTOMER BASE GROWTH BY REGISTRATION YEAR
-- Always the whole base - a running total only means something
-- uninterrupted, so this section ignores the state filter.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. CUSTOMER BASE GROWTH BY REGISTRATION YEAR' SKIP 1 -
       CENTER 'ALL CUSTOMERS, 2019 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN reg_year    HEADING 'YEAR'              FORMAT 9999
COLUMN new_cus     HEADING 'NEW|CUSTOMERS'     FORMAT 999,999
COLUMN running_tot HEADING 'RUNNING|TOTAL'     FORMAT 999,999
COLUMN yoy_pct     HEADING 'GROWTH|YOY %'      FORMAT S990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL NEW' OF new_cus ON REPORT

WITH by_year AS (
    SELECT EXTRACT(YEAR FROM c.cus_reg_date) AS reg_year,
           COUNT(DISTINCT c.cus_ID)          AS new_cus
    FROM   customer_dim c
    WHERE  c.is_current_flag = 'Y'
    GROUP  BY EXTRACT(YEAR FROM c.cus_reg_date)
)
SELECT reg_year, new_cus,
       SUM(new_cus) OVER (ORDER BY reg_year)                                       AS running_tot,
       ROUND( (new_cus - LAG(new_cus) OVER (ORDER BY reg_year))
             / NULLIF(LAG(new_cus) OVER (ORDER BY reg_year), 0) * 100, 1)          AS yoy_pct
FROM   by_year
ORDER  BY reg_year;


-- ###################################################################
-- SECTION 2 - DEMOGRAPHIC MIX: AGE BAND x GENDER  (company-wide)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. DEMOGRAPHIC MIX: AGE BAND BY GENDER' SKIP 1 -
       CENTER 'ALL CURRENT CUSTOMERS' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cus_age_band HEADING 'AGE BAND' FORMAT A10
COLUMN male_cnt      HEADING 'MALE'     FORMAT 999,999
COLUMN female_cnt    HEADING 'FEMALE'   FORMAT 999,999
COLUMN total_cnt     HEADING 'TOTAL'    FORMAT 999,999
COLUMN share_pct     HEADING 'SHARE|%'  FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL AGES' OF male_cnt female_cnt total_cnt ON REPORT

WITH cust AS (
    SELECT c.cus_age_band, c.cus_gender
    FROM   customer_dim c
    WHERE  c.is_current_flag = 'Y'
)
SELECT cus_age_band,
       SUM(CASE WHEN cus_gender = 'Male'   THEN 1 ELSE 0 END) AS male_cnt,
       SUM(CASE WHEN cus_gender = 'Female' THEN 1 ELSE 0 END) AS female_cnt,
       COUNT(*)                                                AS total_cnt,
       ROUND(RATIO_TO_REPORT(COUNT(*)) OVER () * 100, 1)        AS share_pct
FROM   cust
GROUP  BY cus_age_band
ORDER  BY cus_age_band;


-- ###################################################################
-- SECTION 3 - REGIONAL DISTRIBUTION: HOME STATE  (ranked)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. REGIONAL DISTRIBUTION: CUSTOMER HOME STATE' SKIP 1 -
       CENTER 'ALL CURRENT CUSTOMERS, RANKED' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk       HEADING 'RANK'      FORMAT 99
COLUMN cus_state HEADING 'STATE'     FORMAT A22
COLUMN cus_cnt   HEADING 'CUSTOMERS' FORMAT 999,999
COLUMN share_pct HEADING 'SHARE|%'   FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF cus_cnt ON REPORT

WITH by_state AS (
    SELECT c.cus_state, COUNT(*) AS cus_cnt
    FROM   customer_dim c
    WHERE  c.is_current_flag = 'Y'
    GROUP  BY c.cus_state
)
SELECT RANK() OVER (ORDER BY cus_cnt DESC) AS rnk,
       cus_state, cus_cnt,
       ROUND(RATIO_TO_REPORT(cus_cnt) OVER () * 100, 1) AS share_pct
FROM   by_state
ORDER  BY rnk;


-- ###################################################################
-- SECTION 4 - FOCUS YEAR: BRANCH CATCHMENT  (home-state vs cross-region)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. FOCUS YEAR &focus_y: BRANCH CATCHMENT' SKIP 1 -
       CENTER 'HOME-STATE VS CROSS-REGION CUSTOMERS, &st_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city         HEADING 'BRANCH'            FORMAT A15
COLUMN total_res       HEADING 'RESERVATIONS'      FORMAT 99,999
COLUMN home_res        HEADING 'HOME-STATE'        FORMAT 99,999
COLUMN cross_res       HEADING 'CROSS-|REGION'     FORMAT 99,999
COLUMN cross_pct       HEADING 'CROSS-REGION|%'    FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF total_res home_res cross_res ON REPORT

WITH catch AS (
    SELECT b.br_ID, b.br_city,
           COUNT(f.res_det_ID)                                              AS total_res,
           SUM(CASE WHEN c.cus_state = b.br_state THEN 1 ELSE 0 END)        AS home_res,
           SUM(CASE WHEN c.cus_state != b.br_state THEN 1 ELSE 0 END)       AS cross_res
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(c.cus_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    GROUP  BY b.br_ID, b.br_city
)
SELECT br_city, total_res, home_res, cross_res,
       ROUND(cross_res / NULLIF(total_res, 0) * 100, 1) AS cross_pct
FROM   catch
ORDER  BY br_ID;


-- ###################################################################
-- SECTION 5 - FOCUS YEAR: AVG SPEND BY AGE BAND  (ranked)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. FOCUS YEAR &focus_y: AVG SPEND BY AGE BAND' SKIP 1 -
       CENTER '&st_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cus_age_band HEADING 'AGE BAND'         FORMAT A10
COLUMN num_res      HEADING 'RESERVATIONS'     FORMAT 99,999
COLUMN total_rev    HEADING 'TOTAL REV (RM)'   FORMAT 999,999,990.00
COLUMN avg_spend    HEADING 'AVG SPEND|/RES (RM)' FORMAT 9,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL AGES' OF num_res total_rev ON REPORT

WITH spend AS (
    SELECT c.cus_age_band,
           COUNT(f.res_det_ID)                      AS num_res,
           SUM(f.serv_price - f.serv_discount_amt)   AS total_rev
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(c.cus_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    GROUP  BY c.cus_age_band
)
SELECT cus_age_band, num_res, total_rev,
       ROUND(total_rev / NULLIF(num_res, 0), 2) AS avg_spend
FROM   spend
ORDER  BY avg_spend DESC;


-- ###################################################################
-- SECTION 6 - SUMMARY STATISTICS
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 6. CUSTOMER DEMOGRAPHICS SUMMARY STATISTICS' SKIP 1 -
       CENTER '&st_label, FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC'  FORMAT A38
COLUMN metric_value HEADING 'VALUE'   FORMAT A38

WITH cust AS (
    SELECT c.cus_ID, c.cus_age_band, c.cus_gender, c.cus_state
    FROM   customer_dim c
    WHERE  c.is_current_flag = 'Y'
),
totals AS (
    SELECT COUNT(*) AS num_customers FROM cust
),
by_age AS (
    SELECT cus_age_band, COUNT(*) AS cnt FROM cust GROUP BY cus_age_band
),
ab AS (
    SELECT MAX(cus_age_band) KEEP (DENSE_RANK FIRST ORDER BY cnt DESC) AS top_age_band,
           MAX(cnt)          KEEP (DENSE_RANK FIRST ORDER BY cnt DESC) AS top_age_band_cnt
    FROM   by_age
),
by_state AS (
    SELECT cus_state, COUNT(*) AS cnt FROM cust GROUP BY cus_state
),
st AS (
    SELECT MAX(cus_state) KEEP (DENSE_RANK FIRST ORDER BY cnt DESC) AS top_state,
           MAX(cnt)       KEEP (DENSE_RANK FIRST ORDER BY cnt DESC) AS top_state_cnt
    FROM   by_state
),
gen AS (
    SELECT SUM(CASE WHEN cus_gender = 'Female' THEN 1 ELSE 0 END) AS female_cnt,
           SUM(CASE WHEN cus_gender = 'Male'   THEN 1 ELSE 0 END) AS male_cnt
    FROM   cust
),
focus_lines AS (
    SELECT c.cus_age_band, b.br_city, b.br_state, c.cus_state,
           f.res_det_ID, f.serv_price - f.serv_discount_amt AS revenue
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(c.cus_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
),
by_branch_focus AS (
    SELECT br_city,
           COUNT(res_det_ID)                                        AS total_res,
           SUM(CASE WHEN cus_state != br_state THEN 1 ELSE 0 END)   AS cross_res
    FROM   focus_lines GROUP BY br_city
),
fb AS (
    SELECT MAX(br_city) KEEP (DENSE_RANK FIRST ORDER BY cross_res / NULLIF(total_res, 0) DESC) AS most_cross_branch,
           MAX(ROUND(cross_res / NULLIF(total_res, 0) * 100, 1))
               KEEP (DENSE_RANK FIRST ORDER BY cross_res / NULLIF(total_res, 0) DESC)           AS most_cross_pct
    FROM   by_branch_focus
),
by_age_focus AS (
    SELECT cus_age_band, COUNT(res_det_ID) AS num_res, SUM(revenue) AS total_rev
    FROM   focus_lines GROUP BY cus_age_band
),
af AS (
    SELECT MAX(cus_age_band) KEEP (DENSE_RANK FIRST ORDER BY total_rev / NULLIF(num_res, 0) DESC) AS top_spend_band,
           MAX(ROUND(total_rev / NULLIF(num_res, 0), 2))
               KEEP (DENSE_RANK FIRST ORDER BY total_rev / NULLIF(num_res, 0) DESC)                AS top_spend_amt
    FROM   by_age_focus
),
active_focus AS (
    SELECT COUNT(DISTINCT c.cus_ID) AS active_customers
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(c.cus_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
),
stats AS (
    SELECT t.*, ab.*, st.*, gen.*, fb.*, af.*, af2.active_customers
    FROM   totals t CROSS JOIN ab CROSS JOIN st CROSS JOIN gen CROSS JOIN fb CROSS JOIN af
           CROSS JOIN active_focus af2
)
SELECT '--- OVERALL ---' AS metric_name, ' ' AS metric_value FROM dual
UNION ALL SELECT 'Total Registered Customers',
       TRIM(TO_CHAR(num_customers, '999,999,990'))                     FROM stats
UNION ALL SELECT 'Gender Split (Female / Male)',
       TRIM(TO_CHAR(female_cnt, '999,990')) || ' / ' || TRIM(TO_CHAR(male_cnt, '999,990')) FROM stats
UNION ALL SELECT 'Largest Age Band',
       top_age_band || '  (' || TRIM(TO_CHAR(top_age_band_cnt, '999,990')) || ' customers)' FROM stats
UNION ALL SELECT 'Top State by Customer Count',
       top_state || '  (' || TRIM(TO_CHAR(top_state_cnt, '999,990')) || ' customers)' FROM stats
UNION ALL SELECT ' ', ' ' FROM dual
UNION ALL SELECT '--- FOCUS YEAR &focus_y ---', ' ' FROM dual
UNION ALL SELECT 'Active Customers (>=1 Completed Res.)',
       TRIM(TO_CHAR(active_customers, '999,999,990'))                  FROM stats
UNION ALL SELECT 'Branch with Most Cross-Region Traffic',
       most_cross_branch || '  (' || TRIM(TO_CHAR(most_cross_pct, '990.0')) || '% cross-region)' FROM stats
UNION ALL SELECT 'Age Band with Highest Avg Spend',
       top_spend_band || '  (RM ' || TRIM(TO_CHAR(top_spend_amt, '9,990.00')) || '/res)' FROM stats;

PROMPT
PROMPT +==========================================================+
PROMPT |  END OF CUSTOMER DEMOGRAPHICS AND REGIONAL REPORT        |
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
UNDEFINE state
UNDEFINE focus_year
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
