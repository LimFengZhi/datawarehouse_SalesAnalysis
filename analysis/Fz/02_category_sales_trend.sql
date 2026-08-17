-- ===================================================================
-- 02_category_sales_trend.sql
-- SALES ANALYSIS - PRODUCT CATEGORY SALES TREND
--   which branch  ->  year  ->  quarter  ->  category
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\laoli\Downloads\datawarehouseAnalysis\analysis\Fz\02_category_sales_trend.sql
--
-- PARAMETERS (prompted)
--   branch       city or name, e.g. Ipoh   - or ALL   (default ALL)
--   focus year   the year to zoom into                (default 2025)
--
-- WHAT IT ANSWERS
--   1. Which branch sells the most product, and how has that moved
--      year by year?
--   2. For the chosen branch: which product categories are growing,
--      which quarters carry the year, and which branch leads in
--      each category?
--
-- MEASURES  (order_fact, Completed lines only)
--   Sales (RM)  = gross - discount, EXCLUDING tax (SST is passed on
--                 to the government)
--   Units       = SUM(order_qty)
--   Avg price   = gross / units                    realised unit price
--
-- DIMENSIONS USED  (three)
--   branch_dim   br_city / br_name     -> section 1, section 4, filter
--   date_dim     cal_year, cal_quarter -> the drill path
--   product_dim  product_category      -> the rows
--
-- REPORT SECTIONS  (the drill-down path)
--   1  PRODUCT SALES PER BRANCH, YEARS ACROSS      which branch?
--        (always all branches, so you can pick one)
--   2  CATEGORY SALES, YEARS ACROSS                 year trend
--   3  FOCUS YEAR - CATEGORY SALES BY QUARTER       year -> quarter
--   4  FOCUS YEAR - CATEGORY SALES BY BRANCH        category x branch
--   5  SUMMARY STATISTICS
--   Sections 2, 3 and 5 honour the branch filter; 1 and 4 show every
--   branch so there is always something to compare against.
--
-- WHAT TO LOOK FOR
--   - Section 1: KL first every year, Ipoh appears 2023 and ramps
--   - Section 2: 2020-21 dip is milder for products than services
--     (delivery kept going during lockdown); 2023 and 2025 lifted by
--     the price rises. Serum and Moisturizer are the big categories
--   - Section 3: Q4 strongest (Deepavali, 11.11 / 12.12, Christmas);
--     Q2 2020 collapses in every category (MCO 1.0)
--   - Section 4: the top branch is KL in every category
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

COLUMN focus_y   NEW_VALUE focus_y   NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;

COLUMN br_label  NEW_VALUE br_label  NOPRINT
SELECT CASE WHEN UPPER(TRIM('&branch')) IN ('', 'ALL') THEN 'ALL BRANCHES'
            ELSE UPPER(TRIM('&branch')) END AS br_label
FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

-- The branch filter, used in sections 2, 3 and 5. Matches on the
-- branch NAME with LIKE, so 'Ipoh', 'ipoh' and 'Glow Beauty Ipoh'
-- all work.
--   (UPPER(TRIM('&branch')) IN ('', 'ALL')
--    OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')

SPOOL category_sales_trend_output.txt


-- ###################################################################
-- SECTION 1 - PRODUCT SALES PER BRANCH, YEARS ACROSS  (which branch?)
-- Always shows every branch, so this is where you choose one.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. PRODUCT SALES PER BRANCH PER YEAR' SKIP 1 -
       CENTER 'ALL BRANCHES, 2019 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city     HEADING 'BRANCH'      FORMAT A15
COLUMN y2019       HEADING '2019'        FORMAT 9,999,990
COLUMN y2020       HEADING '2020'        FORMAT 9,999,990
COLUMN y2021       HEADING '2021'        FORMAT 9,999,990
COLUMN y2022       HEADING '2022'        FORMAT 9,999,990
COLUMN y2023       HEADING '2023'        FORMAT 9,999,990
COLUMN y2024       HEADING '2024'        FORMAT 9,999,990
COLUMN y2025       HEADING '2025'        FORMAT 9,999,990
COLUMN total_sales HEADING 'TOTAL (RM)'  FORMAT 99,999,990
COLUMN share_pct   HEADING 'SHARE|%'     FORMAT 90.0
COLUMN best_yr     HEADING 'BEST|YEAR'   FORMAT 9999
COLUMN br_ID       NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL BRANCHES' OF y2019 y2020 y2021 y2022 y2023 y2024 y2025 total_sales ON REPORT

WITH br_year AS (
    SELECT b.br_ID, b.br_city, d.cal_year,
           SUM(f.order_gross_amt - f.order_discount_amt) AS sales
    FROM   order_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY b.br_ID, b.br_city, d.cal_year
)
SELECT br_city,
       -- whole ringgit so seven years fit on one line; no ELSE so a
       -- year the branch did not trade (Ipoh before 2023) prints blank
       ROUND(SUM(CASE WHEN cal_year = 2019 THEN sales END)) AS y2019,
       ROUND(SUM(CASE WHEN cal_year = 2020 THEN sales END)) AS y2020,
       ROUND(SUM(CASE WHEN cal_year = 2021 THEN sales END)) AS y2021,
       ROUND(SUM(CASE WHEN cal_year = 2022 THEN sales END)) AS y2022,
       ROUND(SUM(CASE WHEN cal_year = 2023 THEN sales END)) AS y2023,
       ROUND(SUM(CASE WHEN cal_year = 2024 THEN sales END)) AS y2024,
       ROUND(SUM(CASE WHEN cal_year = 2025 THEN sales END)) AS y2025,
       ROUND(SUM(sales))                                     AS total_sales,
       ROUND(RATIO_TO_REPORT(SUM(sales)) OVER () * 100, 1)   AS share_pct,
       MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY sales DESC) AS best_yr,
       br_ID
FROM   br_year
GROUP  BY br_ID, br_city
ORDER  BY br_ID;


-- ###################################################################
-- SECTION 2 - CATEGORY SALES, YEARS ACROSS  (year trend)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. CATEGORY SALES PER YEAR' SKIP 1 -
       CENTER '&br_label, 2019 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN category    HEADING 'CATEGORY'    FORMAT A19
COLUMN y2019       HEADING '2019'        FORMAT 9,999,990
COLUMN y2020       HEADING '2020'        FORMAT 9,999,990
COLUMN y2021       HEADING '2021'        FORMAT 9,999,990
COLUMN y2022       HEADING '2022'        FORMAT 9,999,990
COLUMN y2023       HEADING '2023'        FORMAT 9,999,990
COLUMN y2024       HEADING '2024'        FORMAT 9,999,990
COLUMN y2025       HEADING '2025'        FORMAT 9,999,990
COLUMN total_sales HEADING 'TOTAL (RM)'  FORMAT 99,999,990
COLUMN share_pct   HEADING 'SHARE|%'     FORMAT 90.0
COLUMN best_yr     HEADING 'BEST|YEAR'   FORMAT 9999

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL CATEGORIES' OF y2019 y2020 y2021 y2022 y2023 y2024 y2025 total_sales ON REPORT

WITH cat_year AS (
    SELECT p.product_category AS category, d.cal_year,
           SUM(f.order_gross_amt - f.order_discount_amt) AS sales
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY p.product_category, d.cal_year
)
SELECT category,
       ROUND(SUM(CASE WHEN cal_year = 2019 THEN sales END)) AS y2019,
       ROUND(SUM(CASE WHEN cal_year = 2020 THEN sales END)) AS y2020,
       ROUND(SUM(CASE WHEN cal_year = 2021 THEN sales END)) AS y2021,
       ROUND(SUM(CASE WHEN cal_year = 2022 THEN sales END)) AS y2022,
       ROUND(SUM(CASE WHEN cal_year = 2023 THEN sales END)) AS y2023,
       ROUND(SUM(CASE WHEN cal_year = 2024 THEN sales END)) AS y2024,
       ROUND(SUM(CASE WHEN cal_year = 2025 THEN sales END)) AS y2025,
       ROUND(SUM(sales))                                     AS total_sales,
       ROUND(RATIO_TO_REPORT(SUM(sales)) OVER () * 100, 1)   AS share_pct,
       MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY sales DESC) AS best_yr
FROM   cat_year
GROUP  BY category
ORDER  BY total_sales DESC;


-- ###################################################################
-- SECTION 3 - FOCUS YEAR: CATEGORY SALES BY QUARTER  (year -> quarter)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. FOCUS YEAR &focus_y: CATEGORY SALES BY QUARTER' SKIP 1 -
       CENTER '&br_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN category  HEADING 'CATEGORY'        FORMAT A19
COLUMN q1        HEADING 'Q1 (RM)'         FORMAT 9,999,990.00
COLUMN q2        HEADING 'Q2 (RM)'         FORMAT 9,999,990.00
COLUMN q3        HEADING 'Q3 (RM)'         FORMAT 9,999,990.00
COLUMN q4        HEADING 'Q4 (RM)'         FORMAT 9,999,990.00
COLUMN yr_total  HEADING 'YEAR|TOTAL (RM)' FORMAT 99,999,990.00
COLUMN units     HEADING 'UNITS'           FORMAT 999,999
COLUMN share_pct HEADING 'SHARE|%'         FORMAT 90.0
COLUMN vs_prior  HEADING 'VS PRIOR|YEAR %' FORMAT S990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL CATEGORIES' OF q1 q2 q3 q4 yr_total units ON REPORT

WITH cat_year_qtr AS (
    -- focus year AND the year before, so vs-prior can be worked out
    SELECT p.product_category AS category, d.cal_year, d.cal_quarter,
           SUM(f.order_qty)                              AS units,
           SUM(f.order_gross_amt - f.order_discount_amt) AS sales
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year IN (&focus_year - 1, &focus_year)
    AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
    GROUP  BY p.product_category, d.cal_year, d.cal_quarter
)
SELECT category,
       SUM(CASE WHEN cal_year = &focus_year AND cal_quarter = 1 THEN sales ELSE 0 END) AS q1,
       SUM(CASE WHEN cal_year = &focus_year AND cal_quarter = 2 THEN sales ELSE 0 END) AS q2,
       SUM(CASE WHEN cal_year = &focus_year AND cal_quarter = 3 THEN sales ELSE 0 END) AS q3,
       SUM(CASE WHEN cal_year = &focus_year AND cal_quarter = 4 THEN sales ELSE 0 END) AS q4,
       SUM(CASE WHEN cal_year = &focus_year THEN sales ELSE 0 END)                    AS yr_total,
       SUM(CASE WHEN cal_year = &focus_year THEN units ELSE 0 END)                    AS units,
       ROUND(RATIO_TO_REPORT(SUM(CASE WHEN cal_year = &focus_year THEN sales ELSE 0 END))
             OVER () * 100, 1)                                                         AS share_pct,
       ROUND( (SUM(CASE WHEN cal_year = &focus_year     THEN sales ELSE 0 END)
             - SUM(CASE WHEN cal_year = &focus_year - 1 THEN sales ELSE 0 END))
             / NULLIF(SUM(CASE WHEN cal_year = &focus_year - 1 THEN sales ELSE 0 END), 0)
             * 100, 1)                                                                 AS vs_prior
FROM   cat_year_qtr
GROUP  BY category
HAVING SUM(CASE WHEN cal_year = &focus_year THEN sales ELSE 0 END) > 0
ORDER  BY yr_total DESC;


-- ###################################################################
-- SECTION 4 - FOCUS YEAR: CATEGORY SALES BY BRANCH  (branches across)
-- Always shows every branch, so the chosen one can be compared.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. FOCUS YEAR &focus_y: CATEGORY SALES BY BRANCH' SKIP 1 -
       CENTER 'ALL BRANCHES FOR COMPARISON' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN category  HEADING 'CATEGORY'      FORMAT A19
COLUMN kl        HEADING 'KUALA|LUMPUR'  FORMAT 9,999,990
COLUMN pj        HEADING 'PETALING|JAYA' FORMAT 9,999,990
COLUMN jb        HEADING 'JOHOR|BAHRU'   FORMAT 9,999,990
COLUMN gt        HEADING 'GEORGE|TOWN'   FORMAT 9,999,990
COLUMN mk        HEADING 'MELAKA'        FORMAT 9,999,990
COLUMN ip        HEADING 'IPOH'          FORMAT 9,999,990
COLUMN yr_total  HEADING 'TOTAL (RM)'    FORMAT 99,999,990
COLUMN top_br    HEADING 'TOP BRANCH'    FORMAT A13

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL CATEGORIES' OF kl pj jb gt mk ip yr_total ON REPORT

WITH cat_br AS (
    SELECT p.product_category AS category, b.br_city,
           SUM(f.order_gross_amt - f.order_discount_amt) AS sales
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year = &focus_year
    GROUP  BY p.product_category, b.br_city
)
SELECT category,
       -- whole ringgit so six branches fit on one line
       ROUND(SUM(CASE WHEN br_city = 'Kuala Lumpur'  THEN sales END)) AS kl,
       ROUND(SUM(CASE WHEN br_city = 'Petaling Jaya' THEN sales END)) AS pj,
       ROUND(SUM(CASE WHEN br_city = 'Johor Bahru'   THEN sales END)) AS jb,
       ROUND(SUM(CASE WHEN br_city = 'George Town'   THEN sales END)) AS gt,
       ROUND(SUM(CASE WHEN br_city = 'Melaka'        THEN sales END)) AS mk,
       ROUND(SUM(CASE WHEN br_city = 'Ipoh'          THEN sales END)) AS ip,
       ROUND(SUM(sales))                                               AS yr_total,
       MAX(br_city) KEEP (DENSE_RANK FIRST ORDER BY sales DESC)        AS top_br
FROM   cat_br
GROUP  BY category
ORDER  BY yr_total DESC;


-- ###################################################################
-- SECTION 5 - SUMMARY STATISTICS
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. CATEGORY SALES SUMMARY STATISTICS' SKIP 1 -
       CENTER '&br_label, 2019 - 2025, FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC'  FORMAT A36
COLUMN metric_value HEADING 'VALUE'   FORMAT A44

WITH lines AS (
    SELECT p.product_category, d.cal_year, d.cal_quarter,
           f.order_qty                                  AS units,
           f.order_gross_amt                            AS gross,
           f.order_gross_amt - f.order_discount_amt     AS sales
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND   (UPPER(TRIM('&branch')) IN ('', 'ALL')
           OR UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&branch')) || '%')
),
-- one-row helper blocks, CROSS JOINed below (Oracle 11g rejects KEEP
-- scalar subqueries inside an aggregate SELECT list - ORA-00937)
totals AS (
    SELECT SUM(units) AS units, SUM(gross) AS gross, SUM(sales) AS sales,
           COUNT(DISTINCT product_category) AS num_categories,
           SUM(CASE WHEN cal_year = &focus_year THEN sales END) AS focus_sales,
           SUM(CASE WHEN cal_year = &focus_year - 1 THEN sales END) AS prior_sales
    FROM   lines
),
by_year AS (
    SELECT cal_year, SUM(sales) AS sales FROM lines GROUP BY cal_year
),
by_cat AS (
    SELECT product_category, SUM(sales) AS sales FROM lines GROUP BY product_category
),
by_cat_focus AS (
    SELECT product_category, SUM(sales) AS sales
    FROM   lines WHERE cal_year = &focus_year GROUP BY product_category
),
by_qtr_focus AS (
    SELECT cal_quarter, SUM(sales) AS sales
    FROM   lines WHERE cal_year = &focus_year GROUP BY cal_quarter
),
yr AS (
    SELECT MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY sales DESC) AS best_year,
           MAX(sales)                                               AS best_year_sales,
           MIN(cal_year) KEEP (DENSE_RANK LAST  ORDER BY sales DESC) AS worst_year,
           MIN(sales)                                               AS worst_year_sales
    FROM   by_year
),
ct AS (
    SELECT MAX(product_category) KEEP (DENSE_RANK FIRST ORDER BY sales DESC) AS top_category,
           MAX(sales)                                                      AS top_cat_sales,
           MIN(product_category) KEEP (DENSE_RANK LAST  ORDER BY sales DESC) AS bottom_category,
           MIN(sales)                                                      AS bottom_cat_sales
    FROM   by_cat
),
cf AS (
    SELECT MAX(product_category) KEEP (DENSE_RANK FIRST ORDER BY sales DESC) AS focus_top_category,
           MAX(sales)                                                      AS focus_top_sales
    FROM   by_cat_focus
),
qf AS (
    SELECT MAX(cal_quarter) KEEP (DENSE_RANK FIRST ORDER BY sales DESC) AS focus_best_qtr,
           MAX(sales)                                                  AS focus_best_qtr_sales
    FROM   by_qtr_focus
),
stats AS (
    SELECT t.*, yr.*, ct.*, cf.*, qf.*
    FROM   totals t CROSS JOIN yr CROSS JOIN ct CROSS JOIN cf CROSS JOIN qf
)
SELECT 'Total Product Sales 2019-2025 (RM)'  AS metric_name,
       TO_CHAR(sales, '999,999,999,990.00')                            AS metric_value FROM stats
UNION ALL SELECT 'Total Units Sold 2019-2025',
       TO_CHAR(units, '999,999,990')                                   FROM stats
UNION ALL SELECT 'Average Realised Price (RM)',
       TO_CHAR(gross / NULLIF(units, 0), '9,990.00')                   FROM stats
UNION ALL SELECT 'Best Year',
       TO_CHAR(best_year)  || '  (RM ' || TRIM(TO_CHAR(best_year_sales,  '999,999,990.00')) || ')' FROM stats
UNION ALL SELECT 'Worst Year',
       TO_CHAR(worst_year) || '  (RM ' || TRIM(TO_CHAR(worst_year_sales, '999,999,990.00')) || ')' FROM stats
UNION ALL SELECT 'Top Category 2019-2025',
       top_category    || '  (RM ' || TRIM(TO_CHAR(top_cat_sales,    '999,999,990.00')) || ')'  FROM stats
UNION ALL SELECT 'Smallest Category 2019-2025',
       bottom_category || '  (RM ' || TRIM(TO_CHAR(bottom_cat_sales, '999,999,990.00')) || ')'  FROM stats
UNION ALL SELECT 'Sales in &focus_y (RM)',
       TO_CHAR(focus_sales, '999,999,999,990.00')                     FROM stats
UNION ALL SELECT 'Sales in &focus_y vs prior year',
       TO_CHAR((focus_sales - prior_sales) / NULLIF(prior_sales, 0) * 100, 'S990.0') || '%' FROM stats
UNION ALL SELECT 'Top Category in &focus_y',
       focus_top_category || '  (RM ' || TRIM(TO_CHAR(focus_top_sales, '999,999,990.00')) || ')' FROM stats
UNION ALL SELECT 'Best Quarter in &focus_y',
       'Q' || TO_CHAR(focus_best_qtr) || '  (RM ' || TRIM(TO_CHAR(focus_best_qtr_sales, '999,999,990.00')) || ')' FROM stats
UNION ALL SELECT 'Number of Categories',
       TO_CHAR(num_categories)                                         FROM stats;

PROMPT
PROMPT +==========================================================+
PROMPT |            END OF CATEGORY SALES TREND REPORT            |
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
