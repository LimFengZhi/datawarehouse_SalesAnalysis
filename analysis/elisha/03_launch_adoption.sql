-- ===================================================================
-- 03_launch_adoption.sql
-- NEW PRODUCT / SERVICE LAUNCH COHORT & ADOPTION RAMP-UP ANALYSIS
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\elisha\03_launch_adoption.sql
--
-- WHAT IT ANSWERS (5W1H)
--   WHAT   completed sales of newly launched products and services in
--          their first months on the market, vs the established
--          catalogue as a baseline
--   WHEN   months since each item's launch (the adoption curve)
--   WHERE  which branch adopted the new items fastest (branch_dim)
--   WHO    the launch cohort itself - which products / services were
--          launched together (product_dim / service_dim)
--   WHY    tells management whether launching new items pays back,
--          how long ramp-up to steady sales takes, and informs the
--          next launch plan
--   HOW    an item's LAUNCH DATE = the first calendar month it ever
--          recorded a completed sale (MIN sale month in the facts).
--          Items first sold in the warehouse's opening month are the
--          ORIGINAL catalogue; any later first-sale is a launch.
--          Sales = the stored fact totals (order_total_amt /
--          serv_total_amt), Completed only.
--
-- OLAP TECHNIQUE: SLICING
--   Section 1 surveys every launch-year cohort. The report then
--   slices product_dim / service_dim to ONE launch cohort (prompted
--   year) - Sections 2 and 3 analyse date and branch INSIDE that
--   slice: per-item ramp-up by month, and branch adoption share.
--
-- DIMENSIONS USED (four)  date_dim, product_dim, service_dim,
--   branch_dim
--   FACTS: order_fact + reservation_fact (Completed only)
--
-- NOTE: product_dim / service_dim are SCD2, so items are grouped on
--   the NATURAL keys (product_ID, serv_ID) - price-change versions
--   never create "new" items. Launch is taken from the FACTS (first
--   completed sale) rather than the dimension's effective_start_date,
--   because the initial load stamps every original item with the
--   same version start date, which would put late additions in the
--   opening cohort.
-- ===================================================================

SET VERIFY OFF
SET FEEDBACK OFF
SET PAGESIZE 200
SET LINESIZE 100

PROMPT

CREATE OR REPLACE VIEW LAUNCH_ADOPTION_V AS
SELECT
    'Product Order'   AS channel,
    pd.product_ID             AS item_ID,
    MAX(pd.product_name)      AS item_name,
    MAX(pd.product_category)  AS item_category,
    MIN(MIN(TRUNC(dd.cal_date, 'MM')))
        OVER (PARTITION BY pd.product_ID)  AS launch_date,
    EXTRACT(YEAR FROM MIN(MIN(TRUNC(dd.cal_date, 'MM')))
        OVER (PARTITION BY pd.product_ID)) AS launch_year,
    bd.br_ID,
    MAX(bd.br_city)   AS br_city,
    TRUNC(dd.cal_date, 'MM')  AS month_start,
    SUM(f.order_total_amt)    AS sales_value,
    COUNT(DISTINCT f.order_ID) AS txn_count
FROM order_fact f
JOIN date_dim     dd ON f.date_key     = dd.date_key
JOIN branch_dim   bd ON f.branch_key   = bd.branch_key
JOIN product_dim  pd ON f.product_key  = pd.product_key
WHERE
    f.order_status = 'Completed'
GROUP BY
    pd.product_ID,
    bd.br_ID,
    TRUNC(dd.cal_date, 'MM')
UNION ALL
SELECT
    'Service Reservation' AS channel,
    sv.serv_ID                AS item_ID,
    MAX(sv.serv_name)         AS item_name,
    MAX(sv.serv_category)     AS item_category,
    MIN(MIN(TRUNC(dd.cal_date, 'MM')))
        OVER (PARTITION BY sv.serv_ID)  AS launch_date,
    EXTRACT(YEAR FROM MIN(MIN(TRUNC(dd.cal_date, 'MM')))
        OVER (PARTITION BY sv.serv_ID)) AS launch_year,
    bd.br_ID,
    MAX(bd.br_city)   AS br_city,
    TRUNC(dd.cal_date, 'MM')  AS month_start,
    SUM(f.serv_total_amt)     AS sales_value,
    COUNT(DISTINCT f.res_ID)  AS txn_count
FROM reservation_fact f
JOIN date_dim     dd ON f.date_key     = dd.date_key
JOIN branch_dim   bd ON f.branch_key   = bd.branch_key
JOIN service_dim  sv ON f.service_key  = sv.service_key
WHERE
    f.res_status = 'Completed'
GROUP BY
    sv.serv_ID,
    bd.br_ID,
    TRUNC(dd.cal_date, 'MM');

PROMPT
PROMPT

-- Report Section 1: Launch Cohort Overview (full history)
TTITLE CENTER '=====================================================' SKIP 1 -
       CENTER 'Launch Cohort Overview - Items Launched per Year' SKIP 1 -
       CENTER '(earliest year = the original opening catalogue)' SKIP 1 -
       CENTER '=====================================================' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'Page: ' SQL.PNO SKIP 2

COLUMN channel        FORMAT A20            HEADING 'Channel'
COLUMN launch_year    FORMAT 9999           HEADING 'Launch|Year'
COLUMN items_launched FORMAT 999            HEADING 'Items'
COLUMN total_sales    FORMAT 999,999,990.00 HEADING 'Sales To Date (RM)'
COLUMN avg_per_item   FORMAT 9,999,990.00   HEADING 'Avg Per Item (RM)'

-- channel printed once per group, blank line between channels
BREAK ON channel SKIP 1

SELECT
    channel,
    launch_year,
    COUNT(DISTINCT item_ID)               AS items_launched,
    SUM(sales_value)                      AS total_sales,
    SUM(sales_value) / COUNT(DISTINCT item_ID) AS avg_per_item
FROM LAUNCH_ADOPTION_V
GROUP BY
    channel,
    launch_year
ORDER BY
    channel,
    launch_year;

-- Report Section 2: Adoption Ramp-Up per Item (the SLICE)
PROMPT
PROMPT
ACCEPT launch_year_prompt CHAR PROMPT 'Enter the Launch Year cohort to slice into (e.g., 2023): '
PROMPT

CLEAR COLUMNS
CLEAR BREAKS
SET LINESIZE 150
TTITLE CENTER '=============================================================' SKIP 1 -
       CENTER 'Adoption Ramp-Up of the &launch_year_prompt Launch Cohort' SKIP 1 -
       CENTER 'Completed Sales in the First 6 Months After Launch' SKIP 1 -
       CENTER '=============================================================' SKIP 2

COLUMN channel        FORMAT A20           HEADING 'Channel'
COLUMN item_name      FORMAT A31           HEADING 'Product / Service'
COLUMN launch_month   FORMAT A8            HEADING 'Launched'
COLUMN m1_sales       FORMAT 999,990.00    HEADING 'M1 (RM)'
COLUMN m2_sales       FORMAT 999,990.00    HEADING 'M2 (RM)'
COLUMN m3_sales       FORMAT 999,990.00    HEADING 'M3 (RM)'
COLUMN m4_sales       FORMAT 999,990.00    HEADING 'M4 (RM)'
COLUMN m5_sales       FORMAT 999,990.00    HEADING 'M5 (RM)'
COLUMN m6_sales       FORMAT 999,990.00    HEADING 'M6 (RM)'
COLUMN total_to_date  FORMAT 9,999,990.00  HEADING 'To Date (RM)'

-- channel printed once per group, blank line between channels
BREAK ON channel SKIP 1

-- M1 = the item's own first calendar month on sale, M2 the second,
-- and so on - every item is aligned on ITS OWN launch, so items
-- launched in different months still compare fairly.
WITH
ITEM_MONTHS AS (
    SELECT
        v.channel,
        v.item_ID,
        v.item_name,
        v.launch_date,
        v.month_start,
        v.sales_value,
        MONTHS_BETWEEN(v.month_start, TRUNC(v.launch_date, 'MM')) AS msl
    FROM LAUNCH_ADOPTION_V v
    WHERE v.launch_year = TO_NUMBER('&launch_year_prompt')
)
SELECT
    channel,
    MAX(item_name)                          AS item_name,
    TO_CHAR(MIN(launch_date), 'MON-YYYY')   AS launch_month,
    SUM(CASE WHEN msl = 0 THEN sales_value ELSE 0 END) AS m1_sales,
    SUM(CASE WHEN msl = 1 THEN sales_value ELSE 0 END) AS m2_sales,
    SUM(CASE WHEN msl = 2 THEN sales_value ELSE 0 END) AS m3_sales,
    SUM(CASE WHEN msl = 3 THEN sales_value ELSE 0 END) AS m4_sales,
    SUM(CASE WHEN msl = 4 THEN sales_value ELSE 0 END) AS m5_sales,
    SUM(CASE WHEN msl = 5 THEN sales_value ELSE 0 END) AS m6_sales,
    SUM(sales_value)                        AS total_to_date
FROM ITEM_MONTHS
GROUP BY
    channel,
    item_ID
ORDER BY
    channel,
    total_to_date DESC;

-- Report Section 3: Branch Adoption of the Cohort
PROMPT
PROMPT

CLEAR COLUMNS
CLEAR BREAKS
TTITLE CENTER '=============================================================' SKIP 1 -
       CENTER 'Branch Adoption of the &launch_year_prompt Launch Cohort' SKIP 1 -
       CENTER 'Cohort Sales vs All Sales Since the Cohort Launched' SKIP 1 -
       CENTER '=============================================================' SKIP 2

COLUMN br_city        FORMAT A15            HEADING 'Branch'
COLUMN new_prod_sales FORMAT 99,999,990.00  HEADING 'New Products (RM)'
COLUMN new_serv_sales FORMAT 99,999,990.00  HEADING 'New Services (RM)'
COLUMN cohort_sales   FORMAT 99,999,990.00  HEADING 'Cohort Total (RM)'
COLUMN window_sales   FORMAT 999,999,990.00 HEADING 'All Sales Window (RM)'
COLUMN cohort_share   FORMAT A8             HEADING 'Share %'

-- one blank line after EVERY row, plus a grand-total row
BREAK ON ROW SKIP 1 ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF new_prod_sales new_serv_sales cohort_sales window_sales ON REPORT

-- Share % = the cohort's completed sales as a share of ALL completed
-- sales at that branch in the window since the cohort launched -
-- how much of the branch's business the new items became.
WITH
COHORT AS (
    SELECT MIN(TRUNC(launch_date, 'MM')) AS cohort_start
    FROM LAUNCH_ADOPTION_V
    WHERE launch_year = TO_NUMBER('&launch_year_prompt')
),
BRANCH_ADOPTION AS (
    SELECT
        v.br_ID,
        MAX(v.br_city) AS br_city,
        SUM(CASE WHEN v.launch_year = TO_NUMBER('&launch_year_prompt')
                  AND v.channel = 'Product Order'
                 THEN v.sales_value ELSE 0 END)           AS new_prod_sales,
        SUM(CASE WHEN v.launch_year = TO_NUMBER('&launch_year_prompt')
                  AND v.channel = 'Service Reservation'
                 THEN v.sales_value ELSE 0 END)           AS new_serv_sales,
        SUM(CASE WHEN v.launch_year = TO_NUMBER('&launch_year_prompt')
                 THEN v.sales_value ELSE 0 END)           AS cohort_sales,
        SUM(v.sales_value)                                AS window_sales
    FROM LAUNCH_ADOPTION_V v
    CROSS JOIN COHORT c
    WHERE v.month_start >= c.cohort_start
    GROUP BY v.br_ID
)
SELECT
    br_city,
    new_prod_sales,
    new_serv_sales,
    cohort_sales,
    window_sales,
    TO_CHAR(ROUND(cohort_sales * 100.0 /
        NULLIF(window_sales, 0), 1), '990.9') || '%'      AS cohort_share
FROM BRANCH_ADOPTION
ORDER BY
    cohort_sales DESC;

PROMPT
DROP VIEW LAUNCH_ADOPTION_V;

CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE launch_year_prompt
SET LINESIZE 100
SET FEEDBACK ON
SET VERIFY ON
TTITLE OFF
PROMPT
PROMPT Report complete.
PROMPT
