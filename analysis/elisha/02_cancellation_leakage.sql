-- ===================================================================
-- 02_cancellation_leakage.sql
-- CANCELLATION LEAKAGE ANALYSIS  (lost revenue from transactions
-- that never completed)
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\elisha\02_cancellation_leakage.sql
--
-- WHAT IT ANSWERS (5W1H)
--   WHAT   revenue LEAKED: the value of cancelled product orders and
--          cancelled / no-show service reservations, vs the revenue
--          actually realized from completed ones
--   WHEN   any year range (prompted); yearly trend + quarterly split
--   WHERE  which branch loses the most to cancellations
--   WHO    which products and services get cancelled the most
--          (product_dim / service_dim)
--   WHY    cancellations are invisible in revenue-only reports; this
--          quantifies the money left on the table and where to act
--   HOW    each transaction is bucketed by status - REALIZED
--          (Completed), LEAKED (Cancelled / No-Show), PIPELINE
--          (Pending / Processing / Booked / Confirmed) - then value
--          and counts are aggregated per dimension.
--          Leak rate = leaked / (realized + leaked)
--
-- OLAP TECHNIQUE: SLICING
--   The whole report slices date_dim to the prompted year range -
--   every section analyses the cube INSIDE that time slice.
--   Section 1 trends the leak per year, Section 2 ranks branches,
--   Section 3 ranks the most-cancelled products and services.
--
-- DIMENSIONS USED (four)  date_dim, branch_dim, product_dim,
--   service_dim
--   FACTS: order_fact + reservation_fact (drill-across on status)
--
-- MEASURE DEFINITION
--   Value = the fact's stored line total, taken as-is (no
--   recomputation): order_total_amt / serv_total_amt, both defined
--   in the DWH as price - discount + tax.
--   Reservation No-Show counts as LEAKED - the slot was consumed
--   but produced no revenue.
--
-- NOTE: branch_dim / product_dim / service_dim are SCD2, so grouping
--   is on the NATURAL keys (br_ID, product_ID, serv_ID) - one item
--   rolls up as one line no matter how many price versions it owns.
-- ===================================================================

SET VERIFY OFF
SET FEEDBACK OFF
SET PAGESIZE 200
SET LINESIZE 100

ACCEPT start_year_prompt CHAR PROMPT 'Enter Start Year for Analysis (e.g., 2019): '
ACCEPT end_year_prompt   CHAR PROMPT 'Enter End Year for Analysis (e.g., 2025): '
PROMPT

CREATE OR REPLACE VIEW CANCELLATION_LEAKAGE_V AS
SELECT
    'Product Order'   AS channel,
    bd.br_ID,
    MAX(bd.br_city)   AS br_city,
    pd.product_ID             AS item_ID,
    MAX(pd.product_name)      AS item_name,
    MAX(pd.product_category)  AS item_category,
    dd.cal_year,
    dd.cal_quarter,
    CASE
        WHEN f.order_status = 'Completed' THEN 'REALIZED'
        WHEN f.order_status = 'Cancelled' THEN 'LEAKED'
        ELSE 'PIPELINE'
    END               AS sales_bucket,
    SUM(f.order_total_amt)                        AS sales_value,
    COUNT(DISTINCT f.order_ID)                    AS txn_count
FROM order_fact f
JOIN date_dim     dd ON f.date_key     = dd.date_key
JOIN branch_dim   bd ON f.branch_key   = bd.branch_key
JOIN product_dim  pd ON f.product_key  = pd.product_key
WHERE
    dd.cal_year BETWEEN TO_NUMBER('&start_year_prompt') AND
TO_NUMBER('&end_year_prompt')
GROUP BY
    bd.br_ID,
    pd.product_ID,
    dd.cal_year,
    dd.cal_quarter,
    CASE
        WHEN f.order_status = 'Completed' THEN 'REALIZED'
        WHEN f.order_status = 'Cancelled' THEN 'LEAKED'
        ELSE 'PIPELINE'
    END
UNION ALL
SELECT
    'Service Reservation' AS channel,
    bd.br_ID,
    MAX(bd.br_city)   AS br_city,
    sv.serv_ID                AS item_ID,
    MAX(sv.serv_name)         AS item_name,
    MAX(sv.serv_category)     AS item_category,
    dd.cal_year,
    dd.cal_quarter,
    CASE
        WHEN f.res_status = 'Completed'               THEN 'REALIZED'
        WHEN f.res_status IN ('Cancelled', 'No-Show') THEN 'LEAKED'
        ELSE 'PIPELINE'
    END               AS sales_bucket,
    SUM(f.serv_total_amt)                         AS sales_value,
    COUNT(DISTINCT f.res_ID)                      AS txn_count
FROM reservation_fact f
JOIN date_dim     dd ON f.date_key     = dd.date_key
JOIN branch_dim   bd ON f.branch_key   = bd.branch_key
JOIN service_dim  sv ON f.service_key  = sv.service_key
WHERE
    dd.cal_year BETWEEN TO_NUMBER('&start_year_prompt') AND
TO_NUMBER('&end_year_prompt')
GROUP BY
    bd.br_ID,
    sv.serv_ID,
    dd.cal_year,
    dd.cal_quarter,
    CASE
        WHEN f.res_status = 'Completed'               THEN 'REALIZED'
        WHEN f.res_status IN ('Cancelled', 'No-Show') THEN 'LEAKED'
        ELSE 'PIPELINE'
    END;

PROMPT 

-- Report Section 1: Company Leakage per Year
TTITLE CENTER '=====================================================' SKIP 1 -
       CENTER 'Sales Leakage from Cancellations per Year' SKIP 1 -
       CENTER 'For Year &start_year_prompt to &end_year_prompt' SKIP 1 -
       CENTER '=====================================================' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'Page: ' SQL.PNO SKIP 2

-- Define column formats
COLUMN cal_year      FORMAT A6            HEADING 'Year'
COLUMN realized_sales  FORMAT 999,999,990.00 HEADING 'Realized (RM)'
COLUMN product_leak  FORMAT 9,999,990.00  HEADING 'Product Leak'
COLUMN service_leak  FORMAT 9,999,990.00  HEADING 'Service Leak'
COLUMN total_leak    FORMAT 99,999,990.00 HEADING 'Total Leaked'
COLUMN lost_txns     FORMAT 9,999,999     HEADING 'Lost Txns'
COLUMN leak_rate     FORMAT A8            HEADING 'Leak %'

-- one blank line after EVERY row, plus a grand-total row
BREAK ON ROW SKIP 1 ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF realized_sales product_leak service_leak total_leak lost_txns ON REPORT

SELECT
    TO_CHAR(cal_year) AS cal_year,
    SUM(CASE WHEN sales_bucket = 'REALIZED'
             THEN sales_value ELSE 0 END)               AS realized_sales,
    SUM(CASE WHEN sales_bucket = 'LEAKED'
              AND channel = 'Product Order'
             THEN sales_value ELSE 0 END)               AS product_leak,
    SUM(CASE WHEN sales_bucket = 'LEAKED'
              AND channel = 'Service Reservation'
             THEN sales_value ELSE 0 END)               AS service_leak,
    SUM(CASE WHEN sales_bucket = 'LEAKED'
             THEN sales_value ELSE 0 END)               AS total_leak,
    SUM(CASE WHEN sales_bucket = 'LEAKED'
             THEN txn_count ELSE 0 END)                   AS lost_txns,
    TO_CHAR(ROUND(
        SUM(CASE WHEN sales_bucket = 'LEAKED' THEN sales_value ELSE 0 END) * 100.0 /
        NULLIF(SUM(CASE WHEN sales_bucket IN ('REALIZED','LEAKED')
                        THEN sales_value ELSE 0 END), 0), 1),
        '990.9') || '%'                                   AS leak_rate
FROM CANCELLATION_LEAKAGE_V
GROUP BY
    cal_year
ORDER BY
    cal_year;

-- Report Section 2: Branch Ranking by Leaked Sales
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
PROMPT

SET LINESIZE 130
TTITLE CENTER '=====================================================' SKIP 1 -
       CENTER 'Branch Ranking by Leaked Sales' SKIP 1 -
       CENTER 'For Year &start_year_prompt to &end_year_prompt' SKIP 1 -
       CENTER '=====================================================' SKIP 2

COLUMN ranking       FORMAT 99999         HEADING 'Rank'
COLUMN br_city       FORMAT A15           HEADING 'Branch'
COLUMN realized_sales  FORMAT 999,999,990.00 HEADING 'Realized (RM)'
COLUMN product_leak  FORMAT 9,999,990.00  HEADING 'Product Leak'
COLUMN service_leak  FORMAT 9,999,990.00  HEADING 'Service Leak'
COLUMN total_leak    FORMAT 99,999,990.00 HEADING 'Total Leaked'
COLUMN leak_rate     FORMAT A8            HEADING 'Leak %'
COLUMN pct_of_leak   FORMAT A10           HEADING '% of Leak'

-- one blank line after EVERY row, plus a grand-total row
BREAK ON ROW SKIP 1 ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF realized_sales product_leak service_leak total_leak ON REPORT

WITH
BRANCH_LEAKAGE AS (
    SELECT
        br_ID,
        MAX(br_city) AS br_city,
        SUM(CASE WHEN sales_bucket = 'REALIZED'
                 THEN sales_value ELSE 0 END)           AS realized_sales,
        SUM(CASE WHEN sales_bucket = 'LEAKED'
                  AND channel = 'Product Order'
                 THEN sales_value ELSE 0 END)           AS product_leak,
        SUM(CASE WHEN sales_bucket = 'LEAKED'
                  AND channel = 'Service Reservation'
                 THEN sales_value ELSE 0 END)           AS service_leak,
        SUM(CASE WHEN sales_bucket = 'LEAKED'
                 THEN sales_value ELSE 0 END)           AS total_leak
    FROM CANCELLATION_LEAKAGE_V
    GROUP BY br_ID
)
SELECT
    RANK() OVER (ORDER BY bl.total_leak DESC)             AS ranking,
    bl.br_city,
    bl.realized_sales,
    bl.product_leak,
    bl.service_leak,
    bl.total_leak,
    TO_CHAR(ROUND(bl.total_leak * 100.0 /
        NULLIF(bl.realized_sales + bl.total_leak, 0), 1),
        '990.9') || '%'                                   AS leak_rate,
    TO_CHAR(ROUND(RATIO_TO_REPORT(bl.total_leak) OVER () * 100, 1),
        '990.9') || '%'                                   AS pct_of_leak
FROM BRANCH_LEAKAGE bl
ORDER BY
    ranking;

PROMPT

-- Report Section 3: Most-Cancelled Items per Branch and Channel
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
TTITLE CENTER '=============================================================' SKIP 1 -
       CENTER 'Top 3 Most-Cancelled Products and Services per Branch' SKIP 1 -
       CENTER 'For Year &start_year_prompt to &end_year_prompt' SKIP 1 -
       CENTER '=============================================================' SKIP 2

COLUMN br_city          FORMAT A15           HEADING 'Branch'
COLUMN channel          FORMAT A20           HEADING 'Channel'
COLUMN ranking          FORMAT 999           HEADING 'Rank'
COLUMN item_name        FORMAT A30           HEADING 'Product / Service'
COLUMN item_category    FORMAT A18           HEADING 'Category'
COLUMN lost_txns        FORMAT 999,999       HEADING 'Lost Txns'
COLUMN leaked_value     FORMAT 999,990.00    HEADING 'Leaked (RM)'
COLUMN leak_rate        FORMAT A8            HEADING 'Leak %'
COLUMN branch_leak      NOPRINT

-- branch printed once per group (2 blank lines between branches),
-- channel printed once per block, 1 blank line between channels
BREAK ON br_city SKIP 2 ON channel SKIP 1

-- Top N most-cancelled items of EACH branch x channel: rank restarts
-- per branch/channel via PARTITION BY. Leak % is against that item's
-- own realized + leaked value AT THAT BRANCH.
WITH
ITEM_LEAKAGE AS (
    SELECT
        br_ID,
        MAX(br_city)       AS br_city,
        channel,
        item_ID,
        MAX(item_name)     AS item_name,
        MAX(item_category) AS item_category,
        SUM(CASE WHEN sales_bucket = 'LEAKED'
                 THEN sales_value ELSE 0 END)           AS leaked_value,
        SUM(CASE WHEN sales_bucket = 'LEAKED'
                 THEN txn_count ELSE 0 END)               AS lost_txns,
        SUM(CASE WHEN sales_bucket IN ('REALIZED','LEAKED')
                 THEN sales_value ELSE 0 END)           AS winnable_value,
        SUM(SUM(CASE WHEN sales_bucket = 'LEAKED'
                     THEN sales_value ELSE 0 END))
            OVER (PARTITION BY br_ID)                     AS branch_leak
    FROM CANCELLATION_LEAKAGE_V
    GROUP BY
        br_ID, channel, item_ID
),
RANKED_ITEMS AS (
    SELECT
        il.*,
        RANK() OVER (PARTITION BY il.br_ID, il.channel
                     ORDER BY il.leaked_value DESC)       AS ranking
    FROM ITEM_LEAKAGE il
)
SELECT
    br_city,
    channel,
    ranking,
    item_name,
    item_category,
    lost_txns,
    leaked_value,
    TO_CHAR(ROUND(leaked_value * 100.0 /
        NULLIF(winnable_value, 0), 1), '990.9') || '%'    AS leak_rate,
    branch_leak
FROM RANKED_ITEMS
WHERE ranking <= 3
ORDER BY
    branch_leak DESC,
    br_city,
    channel,
    ranking;

PROMPT
DROP VIEW CANCELLATION_LEAKAGE_V;

CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE start_year_prompt
UNDEFINE end_year_prompt
SET LINESIZE 100
SET FEEDBACK ON
SET VERIFY ON
TTITLE OFF

PROMPT Report complete.
PROMPT
