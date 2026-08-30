CLEAR BREAKS
CLEAR COMPUTES
CLEAR COLUMNS
SET DEFINE ON
SET VERIFY OFF
SET FEEDBACK OFF
SET ECHO OFF
SET PAGESIZE 60
SET LINESIZE 80

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
    SUM(f.order_net_amt)      AS sales_value,
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
    SUM(f.serv_net_amt)       AS sales_value,
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
ACCEPT launch_year_prompt CHAR PROMPT 'Enter the Launch Year cohort to slice into (e.g., 2023): '
PROMPT

CLEAR COLUMNS
CLEAR BREAKS
SET LINESIZE 132
TTITLE CENTER '=============================================================' SKIP 1 -
       CENTER 'Adoption Ramp-Up of the &launch_year_prompt Launch Cohort' SKIP 1 -
       CENTER 'Completed Sales in the First 6 Months After Launch' SKIP 1 -
       CENTER '=============================================================' SKIP 2

COLUMN channel         FORMAT A19           HEADING 'Channel'
COLUMN launch_month    FORMAT A8            HEADING 'Launched'
COLUMN item_name       FORMAT A33           HEADING 'Item Name'
COLUMN m1_sales        FORMAT 999,990       HEADING 'M1 (RM)'
COLUMN m2_sales        FORMAT 999,990       HEADING 'M2 (RM)'
COLUMN m3_sales        FORMAT 999,990       HEADING 'M3 (RM)'
COLUMN m4_sales        FORMAT 999,990       HEADING 'M4 (RM)'
COLUMN m5_sales        FORMAT 999,990       HEADING 'M5 (RM)'
COLUMN m6_sales        FORMAT 999,990       HEADING 'M6 (RM)'
COLUMN total_to_date   FORMAT 9,999,990.00  HEADING 'To Date (RM)'

BREAK ON channel SKIP 1 ON launch_month SKIP 1

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
    TO_CHAR(MIN(launch_date), 'MON-YYYY')   AS launch_month,
    MAX(item_name)                          AS item_name,
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
    MIN(launch_date),
    total_to_date DESC;

-- Report Section 3: Branch Adoption of the Cohort
PROMPT
CLEAR COLUMNS
CLEAR BREAKS
SET LINESIZE 89
TTITLE CENTER '=============================================================' SKIP 1 -
       CENTER 'Branch Adoption of the &launch_year_prompt Launch Cohort' SKIP 1 -
       CENTER 'Cohort Sales vs All Sales Since the Cohort Launched' SKIP 1 -
       CENTER '=============================================================' SKIP 2

COLUMN channel        FORMAT A20            HEADING 'Channel'
COLUMN br_city        FORMAT A15            HEADING 'Branch'
COLUMN cohort_sales   FORMAT 999,999,990.00 HEADING 'Cohort Sales (RM)'
COLUMN window_sales   FORMAT 999,999,990.00 HEADING 'All Sales Window (RM)'
COLUMN cohort_share   FORMAT A8             HEADING 'Share %'

BREAK ON channel SKIP 2 ON REPORT
COMPUTE SUM LABEL 'Channel Total (RM)' OF cohort_sales ON channel

WITH
COHORT AS (
    SELECT MIN(TRUNC(launch_date, 'MM')) AS cohort_start
    FROM LAUNCH_ADOPTION_V
    WHERE launch_year = TO_NUMBER('&launch_year_prompt')
),
COHORT_CHANNELS AS (
    SELECT DISTINCT channel
    FROM LAUNCH_ADOPTION_V
    WHERE launch_year = TO_NUMBER('&launch_year_prompt')
),
BRANCH_WINDOW AS (
    SELECT
        v.br_ID,
        MAX(v.br_city)      AS br_city,
        SUM(v.sales_value)  AS window_sales
    FROM LAUNCH_ADOPTION_V v
    CROSS JOIN COHORT c
    WHERE v.month_start >= c.cohort_start
    GROUP BY v.br_ID
),
BRANCH_ADOPTION AS (
    SELECT
        v.channel,
        v.br_ID,
        SUM(v.sales_value) AS cohort_sales
    FROM LAUNCH_ADOPTION_V v
    WHERE v.launch_year = TO_NUMBER('&launch_year_prompt')
    GROUP BY v.channel, v.br_ID
)
SELECT
    cc.channel,
    bw.br_city,
    NVL(ba.cohort_sales, 0)                                AS cohort_sales,
    bw.window_sales,
    TO_CHAR(ROUND(NVL(ba.cohort_sales, 0) * 100.0 /
        NULLIF(bw.window_sales, 0), 1), '990.9') || '%'    AS cohort_share
FROM COHORT_CHANNELS cc
CROSS JOIN BRANCH_WINDOW bw
LEFT JOIN BRANCH_ADOPTION ba
       ON ba.channel = cc.channel AND ba.br_ID = bw.br_ID
ORDER BY
    cc.channel,
    cohort_sales DESC;

DROP VIEW LAUNCH_ADOPTION_V;
PROMPT
PROMPT Report complete.
PROMPT
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE launch_year_prompt
SET FEEDBACK ON
SET VERIFY ON
TTITLE OFF

