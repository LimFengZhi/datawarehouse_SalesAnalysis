-- ===================================================================
-- 02_cancellation_leakage_viz_v.sql
-- CANCELLATION LEAKAGE VIEW FOR VISUALIZATION (Power BI / Tableau /
-- Excel / etc.)
--
-- Run once in SQL*Plus as the warehouse owner to (re)create it:
--   sqlplus dwh/yourpassword@XE
--   @analysis\elisha\02_cancellation_leakage_viz_v.sql
--
-- WHY A SEPARATE VIEW
--   CANCELLATION_LEAKAGE_V (defined inside 02_cancellation_leakage.sql)
--   filters on &start_year_prompt / &end_year_prompt via SQL*Plus
--   ACCEPT, and is DROPped at the end of that script. A BI tool
--   connects over ODBC/JDBC and can neither answer an ACCEPT prompt
--   nor rely on a view that only exists for the duration of one
--   SQL*Plus session. This view hardcodes the slice to the
--   report's window (2020-2023) instead, and is left in the schema
--   permanently (CREATE OR REPLACE, never DROPped) so a
--   visualization tool can query it directly at any time:
--     SELECT * FROM CANCELLATION_LEAKAGE_VIZ_V;
--
-- GRAIN: channel x branch x item x year x quarter x sales_bucket
-- (same grain as the interactive report's view) - deliberately NOT
-- pre-aggregated, so the BI tool can filter/group/drill down on its
-- own instead of only ever seeing one fixed rollup.
--
-- SALES_BUCKET is the measure that makes leakage visible:
--   REALIZED = Completed
--   LEAKED   = Cancelled (orders) / Cancelled or No-Show (reservations)
--   PIPELINE = still in flight (Pending / Processing / Booked /
--              Confirmed) - excluded from leak rate on both sides
--   Leak rate = LEAKED / (REALIZED + LEAKED)
--
-- NOTE: branch_dim / product_dim / service_dim are SCD2, so grouping
-- is on the NATURAL keys (br_ID, product_ID, serv_ID) - one branch or
-- item rolls up as one line no matter how many versions it owns in
-- the 2020-2023 window.
-- Value = order_net_amt / serv_net_amt, excluding SST tax.
-- ===================================================================

CREATE OR REPLACE VIEW CANCELLATION_LEAKAGE_VIZ_V AS
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
    SUM(f.order_net_amt)                          AS sales_value,
    COUNT(DISTINCT f.order_ID)                    AS txn_count
FROM order_fact f
JOIN date_dim     dd ON f.date_key     = dd.date_key
JOIN branch_dim   bd ON f.branch_key   = bd.branch_key
JOIN product_dim  pd ON f.product_key  = pd.product_key
WHERE
    dd.cal_year BETWEEN 2020 AND 2023
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
    SUM(f.serv_net_amt)                           AS sales_value,
    COUNT(DISTINCT f.res_ID)                      AS txn_count
FROM reservation_fact f
JOIN date_dim     dd ON f.date_key     = dd.date_key
JOIN branch_dim   bd ON f.branch_key   = bd.branch_key
JOIN service_dim  sv ON f.service_key  = sv.service_key
WHERE
    dd.cal_year BETWEEN 2020 AND 2023
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

PROMPT View CANCELLATION_LEAKAGE_VIZ_V created (or replaced).
PROMPT This view is persistent - point your visualization tool at it
PROMPT directly. Re-run this script any time to refresh its definition.
PROMPT

-- ===================================================================
-- Formatted preview - for eyeballing the view's contents in SQL*Plus.
-- NOTE: this COLUMN formatting lives in the SQL*Plus session only -
-- Oracle views carry no display formatting of their own, and a BI
-- tool ignores all of this and renders the raw columns its own way.
-- Aggregated to channel x bucket x year here so the preview stays
-- readable; the view itself keeps the full detail grain.
-- ===================================================================
SET PAGESIZE 200
SET LINESIZE 100

COLUMN channel       FORMAT A20           HEADING 'Channel'
COLUMN sales_bucket  FORMAT A10           HEADING 'Bucket'
COLUMN cal_year      FORMAT 9999          HEADING 'Year'
COLUMN sales_value   FORMAT 999,999,990.00 HEADING 'Value (RM)'
COLUMN txn_count     FORMAT 9,999,999     HEADING 'Txns'

BREAK ON channel SKIP 1

TTITLE CENTER 'CANCELLATION_LEAKAGE_VIZ_V - Preview' SKIP 2

SELECT
    channel,
    sales_bucket,
    cal_year,
    SUM(sales_value) AS sales_value,
    SUM(txn_count)   AS txn_count
FROM CANCELLATION_LEAKAGE_VIZ_V
GROUP BY channel, sales_bucket, cal_year
ORDER BY channel, sales_bucket, cal_year;

CLEAR COLUMNS
CLEAR BREAKS
TTITLE OFF
SET LINESIZE 100
SET PAGESIZE 14
PROMPT
PROMPT Preview complete. View CANCELLATION_LEAKAGE_VIZ_V remains in the
PROMPT schema for your visualization tool to query directly.
