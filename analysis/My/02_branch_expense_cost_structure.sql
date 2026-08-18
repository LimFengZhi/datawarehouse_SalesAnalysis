-- ===================================================================
-- 02_branch_expense_cost_structure.sql
-- BRANCH EXPENSE ANALYSIS - FIXED VS VARIABLE COST STRUCTURE
--   company trend  ->  branch exposure  ->  focus year  ->  category
--   growth  ->  COVID impact
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\My\02_branch_expense_cost_structure.sql
--
-- PARAMETERS (prompted)
--   branch       city or name, e.g. Ipoh   - or ALL   (default ALL)
--   focus year   the year to zoom into                (default 2025)
--
-- WHAT IT ANSWERS
--   1. How much of Glow Beauty's overhead is FIXED (can't be cut
--      quickly) versus VARIABLE (scales with usage), and how is that
--      mix trending 2018-2025?
--   2. Which branches carry the least flexible cost base - i.e. the
--      highest Fixed-cost exposure - and is that getting worse?
--   3. Which individual cost line (Rent, Electricity, Water, Internet,
--      Maintenance, Waste Management) is growing fastest right now?
--   4. Does the data actually show the COVID-19 rent-rebate dip in
--      Fixed costs that the business is known to have had in 2020?
--
-- SCOPE NOTE
--   branch_utils_dim (see ETL_Process\initial_loading\init_dimension\
--   02_init_branch_utils_dim.sql) is a Type 1 lookup carrying only
--   util_name (Rent/Electricity/Water/Internet/Maintenance/Waste
--   Management) - it does not store a Fixed/Variable classification, so
--   every section here derives one from util_name instead of reading a
--   util_category column:
--   FIXED    = Rent, Internet, Waste Management
--   VARIABLE = Electricity, Water, Maintenance
--   This asks a cost-STRUCTURE question distinct from a plain expense
--   breakdown: how locked-in is each branch's overhead, and how fast is
--   each cost line growing - not "expense vs revenue".
--
-- MEASURES  (branch_expense_fact, no status filter - every payment is
--            real cash out, unlike order/reservation lines)
--   Cost (RM)   = SUM(payment_amount)
--   Fixed %     = Fixed cost / total cost * 100 - the exposure metric
--   YoY %       = (this year - last year) / last year * 100
--
-- DIMENSIONS USED  (three)
--   branch_dim       br_ID, br_city / br_name    -> sections 2, 3, 5,
--                                                    filter
--   branch_utils_dim util_name                    -> sections 1, 4;
--                                                    Fixed/Variable is
--                                                    derived from it, not
--                                                    a stored column
--   date_dim          cal_year                    -> the drill path
--
-- REPORT SECTIONS (the drill-down path)
--   1  COMPANY-WIDE FIXED VS VARIABLE COST PER YEAR   2018-2025 overview
--   2  FIXED COST EXPOSURE BY BRANCH                  years ACROSS, %
--   3  FOCUS YEAR - COST STRUCTURE BY BRANCH          ranked by Fixed %
--   4  FOCUS YEAR - COST GROWTH BY UTILITY CATEGORY   3rd dimension
--   5  2019-2021 FIXED COST - COVID IMPACT BY BRANCH  fixed 3-year window
--   6  SUMMARY STATISTICS                             grouped OVERALL /
--                                                      FOCUS YEAR
--   Sections 1, 3, 4 and 6 honour the branch filter; sections 2 and 5
--   always show every branch so there is something to compare against.
--
-- WHAT TO LOOK FOR
--   - Section 1: Fixed % should be the majority of cost every year -
--     rent dominates - and should barely move even as totals grow
--   - Section 2: exposure should be fairly flat per branch (the Fixed/
--     Variable split doesn't change often), so a branch that jumps is
--     worth investigating
--   - Section 4: Rent and Internet should show the steady ~3%/year
--     rise the business is known to apply; Electricity/Water/
--     Maintenance move more with usage
--   - Section 5: 2020 Fixed cost should dip versus 2019 (landlord rent
--     rebates during MCO), then partially recover in 2021
--
-- WHY "PAGE: 1" NEVER CHANGES
--   SQL.PNO in the TTITLE counts pages WITHIN the current SELECT's own
--   output (driven by PAGESIZE = 60 lines). Every table here is far
--   shorter than that, so it never rolls to page 2 - PAGE: 1 on every
--   section is expected. The 1 / 2 / 3 / 4 ... in each section's own
--   title is the real section index.
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

-- The branch filter, used in sections 1, 3, 4 and 6. Matches on the
-- branch NAME with LIKE, so 'Ipoh', 'ipoh' and 'Glow Beauty Ipoh' all
-- work.
--   (UPPER(TRIM('&branch')) IN ('', 'ALL')
--    OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')

SPOOL branch_expense_cost_structure_output.txt


-- ###################################################################
-- SECTION 1 - COMPANY-WIDE FIXED VS VARIABLE COST PER YEAR
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. FIXED VS VARIABLE COST PER YEAR' SKIP 1 -
       CENTER '&br_label, 2018 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year      HEADING 'YEAR'              FORMAT 9999
COLUMN fixed_cost    HEADING 'FIXED|COST (RM)'    FORMAT 999,999,990.00
COLUMN variable_cost HEADING 'VARIABLE|COST (RM)' FORMAT 999,999,990.00
COLUMN total_cost    HEADING 'TOTAL|COST (RM)'    FORMAT 999,999,990.00
COLUMN fixed_pct     HEADING 'FIXED|%'            FORMAT 990.0
COLUMN fixed_yoy_pct HEADING 'FIXED|YOY %'        FORMAT S990.0
COLUMN var_yoy_pct   HEADING 'VARIABLE|YOY %'     FORMAT S990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF fixed_cost variable_cost total_cost ON REPORT

-- branch_utils_dim has no util_category column - Fixed/Variable is
-- derived from util_name (Rent/Internet/Waste Management = Fixed).
WITH yearly AS (
    SELECT d.cal_year,
           SUM(CASE WHEN u.util_name IN ('Rent','Internet','Waste Management')
                    THEN f.payment_amount ELSE 0 END) AS fixed_cost,
           SUM(CASE WHEN u.util_name NOT IN ('Rent','Internet','Waste Management')
                    THEN f.payment_amount ELSE 0 END) AS variable_cost,
           SUM(f.payment_amount)                                             AS total_cost
    FROM   branch_expense_fact f
    JOIN   date_dim         d ON d.date_key         = f.date_key
    JOIN   branch_dim       b ON b.branch_key       = f.branch_key
    JOIN   branch_utils_dim u ON u.branch_utils_key = f.branch_utils_key
    WHERE (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY d.cal_year
)
SELECT cal_year, fixed_cost, variable_cost, total_cost,
       ROUND(fixed_cost / NULLIF(total_cost, 0) * 100, 1) AS fixed_pct,
       ROUND( (fixed_cost - LAG(fixed_cost) OVER (ORDER BY cal_year))
             / NULLIF(LAG(fixed_cost) OVER (ORDER BY cal_year), 0) * 100, 1) AS fixed_yoy_pct,
       ROUND( (variable_cost - LAG(variable_cost) OVER (ORDER BY cal_year))
             / NULLIF(LAG(variable_cost) OVER (ORDER BY cal_year), 0) * 100, 1) AS var_yoy_pct
FROM   yearly
ORDER  BY cal_year;


-- ###################################################################
-- SECTION 2 - FIXED COST EXPOSURE BY BRANCH  (years across, always all)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. FIXED COST EXPOSURE BY BRANCH' SKIP 1 -
       CENTER 'FIXED COST AS % OF TOTAL EXPENSE, 2018 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city HEADING 'BRANCH' FORMAT A15
COLUMN y2018   HEADING '2018'   FORMAT 990.0
COLUMN y2019   HEADING '2019'   FORMAT 990.0
COLUMN y2020   HEADING '2020'   FORMAT 990.0
COLUMN y2021   HEADING '2021'   FORMAT 990.0
COLUMN y2022   HEADING '2022'   FORMAT 990.0
COLUMN y2023   HEADING '2023'   FORMAT 990.0
COLUMN y2024   HEADING '2024'   FORMAT 990.0
COLUMN y2025   HEADING '2025'   FORMAT 990.0
COLUMN br_ID   NOPRINT

BREAK ON REPORT
COMPUTE AVG LABEL 'COMPANY AVG' OF y2018 y2019 y2020 y2021 y2022 y2023 y2024 y2025 ON REPORT

WITH branch_year AS (
    SELECT b.br_ID, b.br_city, d.cal_year,
           SUM(CASE WHEN u.util_name IN ('Rent','Internet','Waste Management')
                    THEN f.payment_amount ELSE 0 END) AS fixed_cost,
           SUM(f.payment_amount)                                             AS total_cost
    FROM   branch_expense_fact f
    JOIN   date_dim         d ON d.date_key         = f.date_key
    JOIN   branch_dim       b ON b.branch_key       = f.branch_key
    JOIN   branch_utils_dim u ON u.branch_utils_key = f.branch_utils_key
    GROUP  BY b.br_ID, b.br_city, d.cal_year
)
SELECT br_city,
       ROUND(SUM(CASE WHEN cal_year = 2018 THEN fixed_cost END)
             / NULLIF(SUM(CASE WHEN cal_year = 2018 THEN total_cost END), 0) * 100, 1) AS y2018,
       ROUND(SUM(CASE WHEN cal_year = 2019 THEN fixed_cost END)
             / NULLIF(SUM(CASE WHEN cal_year = 2019 THEN total_cost END), 0) * 100, 1) AS y2019,
       ROUND(SUM(CASE WHEN cal_year = 2020 THEN fixed_cost END)
             / NULLIF(SUM(CASE WHEN cal_year = 2020 THEN total_cost END), 0) * 100, 1) AS y2020,
       ROUND(SUM(CASE WHEN cal_year = 2021 THEN fixed_cost END)
             / NULLIF(SUM(CASE WHEN cal_year = 2021 THEN total_cost END), 0) * 100, 1) AS y2021,
       ROUND(SUM(CASE WHEN cal_year = 2022 THEN fixed_cost END)
             / NULLIF(SUM(CASE WHEN cal_year = 2022 THEN total_cost END), 0) * 100, 1) AS y2022,
       ROUND(SUM(CASE WHEN cal_year = 2023 THEN fixed_cost END)
             / NULLIF(SUM(CASE WHEN cal_year = 2023 THEN total_cost END), 0) * 100, 1) AS y2023,
       ROUND(SUM(CASE WHEN cal_year = 2024 THEN fixed_cost END)
             / NULLIF(SUM(CASE WHEN cal_year = 2024 THEN total_cost END), 0) * 100, 1) AS y2024,
       ROUND(SUM(CASE WHEN cal_year = 2025 THEN fixed_cost END)
             / NULLIF(SUM(CASE WHEN cal_year = 2025 THEN total_cost END), 0) * 100, 1) AS y2025,
       br_ID
FROM   branch_year
GROUP  BY br_ID, br_city
ORDER  BY br_ID;


-- ###################################################################
-- SECTION 3 - FOCUS YEAR: COST STRUCTURE BY BRANCH  (ranked by Fixed %)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. FOCUS YEAR &focus_y: COST STRUCTURE BY BRANCH' SKIP 1 -
       CENTER '&br_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk           HEADING 'RANK'              FORMAT 99
COLUMN br_city        HEADING 'BRANCH'            FORMAT A15
COLUMN fixed_cost     HEADING 'FIXED|COST (RM)'    FORMAT 999,999,990.00
COLUMN variable_cost  HEADING 'VARIABLE|COST (RM)' FORMAT 999,999,990.00
COLUMN total_cost     HEADING 'TOTAL|COST (RM)'    FORMAT 999,999,990.00
COLUMN fixed_pct      HEADING 'FIXED|%'            FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF fixed_cost variable_cost total_cost ON REPORT

WITH branch_cost AS (
    SELECT b.br_ID, b.br_city,
           SUM(CASE WHEN u.util_name IN ('Rent','Internet','Waste Management')
                    THEN f.payment_amount ELSE 0 END) AS fixed_cost,
           SUM(CASE WHEN u.util_name NOT IN ('Rent','Internet','Waste Management')
                    THEN f.payment_amount ELSE 0 END) AS variable_cost,
           SUM(f.payment_amount)                                             AS total_cost
    FROM   branch_expense_fact f
    JOIN   date_dim         d ON d.date_key         = f.date_key
    JOIN   branch_dim       b ON b.branch_key       = f.branch_key
    JOIN   branch_utils_dim u ON u.branch_utils_key = f.branch_utils_key
    WHERE  d.cal_year = &focus_year
    GROUP  BY b.br_ID, b.br_city
)
SELECT RANK() OVER (ORDER BY fixed_cost / NULLIF(total_cost, 0) DESC) AS rnk,
       br_city, fixed_cost, variable_cost, total_cost,
       ROUND(fixed_cost / NULLIF(total_cost, 0) * 100, 1) AS fixed_pct
FROM   branch_cost
ORDER  BY rnk;


-- ###################################################################
-- SECTION 4 - FOCUS YEAR: COST GROWTH BY UTILITY CATEGORY
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. FOCUS YEAR &focus_y: COST GROWTH BY UTILITY' SKIP 1 -
       CENTER '&br_label, VS &focus_y MINUS 1' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN util_name     HEADING 'UTILITY'         FORMAT A18
COLUMN util_category HEADING 'CATEGORY'        FORMAT A9
COLUMN prior_yr      HEADING 'PRIOR YR (RM)'   FORMAT 999,999,990.00
COLUMN focus_yr      HEADING 'FOCUS YR (RM)'   FORMAT 999,999,990.00
COLUMN yoy_pct       HEADING 'YOY %'           FORMAT S990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF prior_yr focus_yr ON REPORT

WITH cat_yr AS (
    SELECT u.util_name,
           CASE WHEN u.util_name IN ('Rent','Internet','Waste Management')
                THEN 'Fixed' ELSE 'Variable' END AS util_category,
           d.cal_year,
           SUM(f.payment_amount) AS amt
    FROM   branch_expense_fact f
    JOIN   date_dim         d ON d.date_key         = f.date_key
    JOIN   branch_dim       b ON b.branch_key       = f.branch_key
    JOIN   branch_utils_dim u ON u.branch_utils_key = f.branch_utils_key
    WHERE  d.cal_year IN (&focus_year - 1, &focus_year)
    AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY u.util_name,
              CASE WHEN u.util_name IN ('Rent','Internet','Waste Management')
                   THEN 'Fixed' ELSE 'Variable' END,
              d.cal_year
)
SELECT util_name, util_category,
       SUM(CASE WHEN cal_year = &focus_year - 1 THEN amt ELSE 0 END) AS prior_yr,
       SUM(CASE WHEN cal_year = &focus_year     THEN amt ELSE 0 END) AS focus_yr,
       ROUND( (SUM(CASE WHEN cal_year = &focus_year     THEN amt ELSE 0 END)
             - SUM(CASE WHEN cal_year = &focus_year - 1 THEN amt ELSE 0 END))
             / NULLIF(SUM(CASE WHEN cal_year = &focus_year - 1 THEN amt ELSE 0 END), 0)
             * 100, 1) AS yoy_pct
FROM   cat_yr
GROUP  BY util_name, util_category
ORDER  BY util_category, yoy_pct DESC;


-- ###################################################################
-- SECTION 5 - 2019-2021 FIXED COST: COVID IMPACT BY BRANCH
-- Fixed 3-year window regardless of the focus year parameter - this
-- section exists specifically to test the rent-rebate hypothesis.
-- Always shows every branch, ignoring the branch filter too. Ipoh
-- opened March 2023 (see README.md), so it has NO rows for 2019-2021
-- and will not appear at all in this section - that is correct, not
-- a bug (the same thing you already saw in 01_service_demand_peak_
-- hour.sql when testing Ipoh against an early focus year).
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. FIXED COST: COVID IMPACT BY BRANCH' SKIP 1 -
       CENTER '2019 (PRE-COVID) VS 2020 (MCO) VS 2021 (FMCO)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city    HEADING 'BRANCH'         FORMAT A15
COLUMN y2019      HEADING '2019 (RM)'      FORMAT 9,999,990.00
COLUMN y2020      HEADING '2020 (RM)'      FORMAT 9,999,990.00
COLUMN y2021      HEADING '2021 (RM)'      FORMAT 9,999,990.00
COLUMN pct_20_19  HEADING '2020 VS|2019 %' FORMAT S990.0
COLUMN pct_21_20  HEADING '2021 VS|2020 %' FORMAT S990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL BRANCHES' OF y2019 y2020 y2021 ON REPORT

WITH yr3 AS (
    SELECT b.br_city, d.cal_year,
           SUM(CASE WHEN u.util_name IN ('Rent','Internet','Waste Management')
                    THEN f.payment_amount ELSE 0 END) AS fixed_cost
    FROM   branch_expense_fact f
    JOIN   date_dim         d ON d.date_key         = f.date_key
    JOIN   branch_dim       b ON b.branch_key       = f.branch_key
    JOIN   branch_utils_dim u ON u.branch_utils_key = f.branch_utils_key
    WHERE  d.cal_year IN (2019, 2020, 2021)
    GROUP  BY b.br_city, d.cal_year
)
SELECT br_city,
       SUM(CASE WHEN cal_year = 2019 THEN fixed_cost END) AS y2019,
       SUM(CASE WHEN cal_year = 2020 THEN fixed_cost END) AS y2020,
       SUM(CASE WHEN cal_year = 2021 THEN fixed_cost END) AS y2021,
       ROUND( (SUM(CASE WHEN cal_year = 2020 THEN fixed_cost END)
             - SUM(CASE WHEN cal_year = 2019 THEN fixed_cost END))
             / NULLIF(SUM(CASE WHEN cal_year = 2019 THEN fixed_cost END), 0) * 100, 1) AS pct_20_19,
       ROUND( (SUM(CASE WHEN cal_year = 2021 THEN fixed_cost END)
             - SUM(CASE WHEN cal_year = 2020 THEN fixed_cost END))
             / NULLIF(SUM(CASE WHEN cal_year = 2020 THEN fixed_cost END), 0) * 100, 1) AS pct_21_20
FROM   yr3
GROUP  BY br_city
ORDER  BY br_city;


-- ###################################################################
-- SECTION 6 - SUMMARY STATISTICS
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 6. COST STRUCTURE SUMMARY STATISTICS' SKIP 1 -
       CENTER '&br_label, 2018 - 2025, FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC'  FORMAT A38
COLUMN metric_value HEADING 'VALUE'   FORMAT A38

WITH lines AS (
    SELECT d.cal_year, b.br_city, u.util_name,
           CASE WHEN u.util_name IN ('Rent','Internet','Waste Management')
                THEN 'Fixed' ELSE 'Variable' END AS util_category,
           f.payment_amount AS amt
    FROM   branch_expense_fact f
    JOIN   date_dim         d ON d.date_key         = f.date_key
    JOIN   branch_dim       b ON b.branch_key       = f.branch_key
    JOIN   branch_utils_dim u ON u.branch_utils_key = f.branch_utils_key
    WHERE (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
),
totals AS (
    SELECT SUM(CASE WHEN util_category = 'Fixed'    THEN amt ELSE 0 END) AS total_fixed,
           SUM(CASE WHEN util_category = 'Variable' THEN amt ELSE 0 END) AS total_variable,
           SUM(amt)                                                      AS total_expense,
           COUNT(DISTINCT cal_year)                                      AS num_years,
           COUNT(DISTINCT br_city)                                       AS num_branches
    FROM   lines
),
by_branch AS (
    SELECT br_city,
           SUM(CASE WHEN util_category = 'Fixed' THEN amt ELSE 0 END) AS fixed_cost,
           SUM(amt)                                                   AS total_cost
    FROM   lines GROUP BY br_city
),
bx AS (
    SELECT MAX(br_city) KEEP (DENSE_RANK FIRST ORDER BY fixed_cost / NULLIF(total_cost, 0) DESC) AS most_fixed_branch,
           MAX(ROUND(fixed_cost / NULLIF(total_cost, 0) * 100, 1))
               KEEP (DENSE_RANK FIRST ORDER BY fixed_cost / NULLIF(total_cost, 0) DESC)           AS most_fixed_pct,
           MIN(br_city) KEEP (DENSE_RANK LAST  ORDER BY fixed_cost / NULLIF(total_cost, 0) DESC)  AS least_fixed_branch,
           MIN(ROUND(fixed_cost / NULLIF(total_cost, 0) * 100, 1))
               KEEP (DENSE_RANK LAST  ORDER BY fixed_cost / NULLIF(total_cost, 0) DESC)           AS least_fixed_pct
    FROM   by_branch
),
by_year_fixed AS (
    SELECT cal_year, SUM(CASE WHEN util_category = 'Fixed' THEN amt ELSE 0 END) AS fixed_cost
    FROM   lines GROUP BY cal_year
),
cv AS (
    SELECT MAX(CASE WHEN cal_year = 2019 THEN fixed_cost END) AS fixed_2019,
           MAX(CASE WHEN cal_year = 2020 THEN fixed_cost END) AS fixed_2020,
           MAX(CASE WHEN cal_year = 2021 THEN fixed_cost END) AS fixed_2021
    FROM   by_year_fixed
),
by_cat_focus AS (
    SELECT util_name,
           SUM(CASE WHEN cal_year = &focus_year     THEN amt ELSE 0 END) AS fy_amt,
           SUM(CASE WHEN cal_year = &focus_year - 1 THEN amt ELSE 0 END) AS py_amt
    FROM   lines
    WHERE  cal_year IN (&focus_year - 1, &focus_year)
    GROUP  BY util_name
),
fg AS (
    SELECT MAX(util_name) KEEP (DENSE_RANK FIRST ORDER BY (fy_amt - py_amt) / NULLIF(py_amt, 0) DESC) AS fastest_cat,
           MAX(ROUND((fy_amt - py_amt) / NULLIF(py_amt, 0) * 100, 1))
               KEEP (DENSE_RANK FIRST ORDER BY (fy_amt - py_amt) / NULLIF(py_amt, 0) DESC)             AS fastest_pct
    FROM   by_cat_focus
),
by_branch_focus AS (
    SELECT br_city,
           SUM(CASE WHEN util_category = 'Fixed' THEN amt ELSE 0 END) AS fixed_cost,
           SUM(amt)                                                   AS total_cost
    FROM   lines WHERE cal_year = &focus_year GROUP BY br_city
),
fb AS (
    SELECT MAX(br_city) KEEP (DENSE_RANK FIRST ORDER BY fixed_cost / NULLIF(total_cost, 0) DESC) AS focus_most_fixed_branch,
           MAX(ROUND(fixed_cost / NULLIF(total_cost, 0) * 100, 1))
               KEEP (DENSE_RANK FIRST ORDER BY fixed_cost / NULLIF(total_cost, 0) DESC)           AS focus_most_fixed_pct,
           SUM(total_cost)                                                                        AS focus_total_expense
    FROM   by_branch_focus
),
stats AS (
    SELECT t.*, bx.*, cv.*, fg.*, fb.*
    FROM   totals t CROSS JOIN bx CROSS JOIN cv CROSS JOIN fg CROSS JOIN fb
)
SELECT '--- OVERALL ---' AS metric_name, ' ' AS metric_value FROM dual
UNION ALL SELECT 'Total Fixed Cost (RM)',
       TRIM(TO_CHAR(total_fixed, '999,999,999,990.00'))                FROM stats
UNION ALL SELECT 'Total Variable Cost (RM)',
       TRIM(TO_CHAR(total_variable, '999,999,999,990.00'))             FROM stats
UNION ALL SELECT 'Total Expense (RM)',
       TRIM(TO_CHAR(total_expense, '999,999,999,990.00'))              FROM stats
UNION ALL SELECT 'Overall Fixed % of Total',
       TRIM(TO_CHAR(total_fixed / NULLIF(total_expense, 0) * 100, '990.0')) || '%' FROM stats
UNION ALL SELECT 'Number of Branches',
       TRIM(TO_CHAR(num_branches))                                     FROM stats
UNION ALL SELECT 'Number of Years Covered',
       TRIM(TO_CHAR(num_years))                                        FROM stats
UNION ALL SELECT 'Most Fixed-Cost-Exposed Branch',
       most_fixed_branch || '  (' || TRIM(TO_CHAR(most_fixed_pct, '990.0')) || '% fixed)' FROM stats
UNION ALL SELECT 'Least Fixed-Cost-Exposed Branch',
       least_fixed_branch || '  (' || TRIM(TO_CHAR(least_fixed_pct, '990.0')) || '% fixed)' FROM stats
UNION ALL SELECT 'Fixed Cost Chg 2019-2020 (COVID)',
       TRIM(TO_CHAR((fixed_2020 - fixed_2019) / NULLIF(fixed_2019, 0) * 100, 'S990.0')) || '%' FROM stats
UNION ALL SELECT 'Fixed Cost Chg 2020-2021',
       TRIM(TO_CHAR((fixed_2021 - fixed_2020) / NULLIF(fixed_2020, 0) * 100, 'S990.0')) || '%' FROM stats
UNION ALL SELECT ' ', ' ' FROM dual
UNION ALL SELECT '--- FOCUS YEAR &focus_y ---', ' ' FROM dual
UNION ALL SELECT 'Total Expense (RM)',
       TRIM(TO_CHAR(focus_total_expense, '999,999,999,990.00'))        FROM stats
UNION ALL SELECT 'Most Fixed-Cost-Exposed Branch',
       focus_most_fixed_branch || '  (' || TRIM(TO_CHAR(focus_most_fixed_pct, '990.0')) || '% fixed)' FROM stats
UNION ALL SELECT 'Fastest-Growing Cost Category',
       fastest_cat || '  (' || TRIM(TO_CHAR(fastest_pct, 'S990.0')) || '%)' FROM stats;

PROMPT
PROMPT +==========================================================+
PROMPT |  END OF BRANCH EXPENSE COST STRUCTURE REPORT             |
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
