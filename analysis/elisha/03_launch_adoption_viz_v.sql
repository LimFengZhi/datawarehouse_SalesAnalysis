-- ===================================================================
-- 03_launch_adoption_viz_v.sql
-- LAUNCH ADOPTION VIEW FOR VISUALIZATION (Power BI / Tableau /
-- Excel / etc.)
--
-- Run once in SQL*Plus as the warehouse owner to (re)create it:
--   sqlplus dwh/yourpassword@XE
--   @analysis\elisha\03_launch_adoption_viz_v.sql
--
-- WHY A SEPARATE VIEW
--   LAUNCH_ADOPTION_V (defined inside 03_launch_adoption.sql) already
--   covers the full history with no ACCEPT-driven year filter, so
--   nothing needs hardcoding there. What DOES need changing for a BI
--   tool is the shape: 03_launch_adoption.sql pivots each item's
--   ramp-up into wide M1..M6 columns for a text report, but a BI
--   tool wants long/tall data so it can draw a proper line chart.
--   This view adds MONTHS_SINCE_LAUNCH as its own column instead, so
--   "months since launch" becomes a normal axis a chart can use
--   directly - no UNPIVOT, no re-deriving MONTHS_BETWEEN in DAX.
--   Left in the schema permanently (CREATE OR REPLACE, never
--   DROPped): SELECT * FROM LAUNCH_ADOPTION_VIZ_V;
--
-- GRAIN: channel x item x branch x month, same as the interactive
-- report's view, plus MONTHS_SINCE_LAUNCH derived per row.
--
-- KEY INSIGHT FOR THE BI TOOL: in this dataset, LAUNCH_YEAR already
-- segregates by channel - 2021 is services-only, 2025 is
-- products-only, 2019 is the original catalogue (both channels). So
-- ONE launch-year slicer picks the right channel automatically; a
-- separate channel slicer is not required for filtering (though
-- CHANNEL is still useful as a legend/colour field).
--
-- NOTE: product_dim / service_dim are SCD2, so items are grouped on
-- the NATURAL keys (product_ID, serv_ID). LAUNCH_DATE is each item's
-- first completed-sale month (not its dimension effective_start_date
-- - see 03_launch_adoption.sql's header for why). Sales = stored fact
-- net revenue (order_net_amt / serv_net_amt), Completed only.
-- ===================================================================

CREATE OR REPLACE VIEW LAUNCH_ADOPTION_VIZ_V AS
SELECT
    base.*,
    MONTHS_BETWEEN(base.month_start, base.launch_date) AS months_since_launch
FROM (
    SELECT
        'Product Order'   AS channel,
        pd.product_ID              AS item_ID,
        MAX(pd.product_name)       AS item_name,
        MAX(pd.product_category)   AS item_category,
        MIN(MIN(TRUNC(dd.cal_date, 'MM')))
            OVER (PARTITION BY pd.product_ID)  AS launch_date,
        EXTRACT(YEAR FROM MIN(MIN(TRUNC(dd.cal_date, 'MM')))
            OVER (PARTITION BY pd.product_ID)) AS launch_year,
        bd.br_ID,
        MAX(bd.br_city)    AS br_city,
        TRUNC(dd.cal_date, 'MM')   AS month_start,
        SUM(f.order_net_amt)       AS sales_value,
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
        sv.serv_ID                 AS item_ID,
        MAX(sv.serv_name)          AS item_name,
        MAX(sv.serv_category)      AS item_category,
        MIN(MIN(TRUNC(dd.cal_date, 'MM')))
            OVER (PARTITION BY sv.serv_ID)  AS launch_date,
        EXTRACT(YEAR FROM MIN(MIN(TRUNC(dd.cal_date, 'MM')))
            OVER (PARTITION BY sv.serv_ID)) AS launch_year,
        bd.br_ID,
        MAX(bd.br_city)    AS br_city,
        TRUNC(dd.cal_date, 'MM')   AS month_start,
        SUM(f.serv_net_amt)        AS sales_value,
        COUNT(DISTINCT f.res_ID)   AS txn_count
    FROM reservation_fact f
    JOIN date_dim     dd ON f.date_key     = dd.date_key
    JOIN branch_dim   bd ON f.branch_key   = bd.branch_key
    JOIN service_dim  sv ON f.service_key  = sv.service_key
    WHERE
        f.res_status = 'Completed'
    GROUP BY
        sv.serv_ID,
        bd.br_ID,
        TRUNC(dd.cal_date, 'MM')
) base;

PROMPT View LAUNCH_ADOPTION_VIZ_V created (or replaced).
PROMPT This view is persistent - point your visualization tool at it
PROMPT directly. Re-run this script any time to refresh its definition.
PROMPT

-- ===================================================================
-- Formatted preview - for eyeballing the view's contents in SQL*Plus.
-- Aggregated to channel x launch_year x months_since_launch here so
-- the preview stays readable; the view itself keeps the full detail
-- grain (item x branch x month).
-- ===================================================================
SET PAGESIZE 200
SET LINESIZE 100

COLUMN channel              FORMAT A20            HEADING 'Channel'
COLUMN launch_year          FORMAT 9999           HEADING 'Launch Year'
COLUMN months_since_launch  FORMAT 990            HEADING 'Months Since'
COLUMN sales_value          FORMAT 999,999,990.00 HEADING 'Sales (RM)'
COLUMN txn_count            FORMAT 9,999,999      HEADING 'Txns'

BREAK ON channel SKIP 1 ON launch_year SKIP 1

TTITLE CENTER 'LAUNCH_ADOPTION_VIZ_V - Preview' SKIP 2

SELECT
    channel,
    launch_year,
    months_since_launch,
    SUM(sales_value) AS sales_value,
    SUM(txn_count)   AS txn_count
FROM LAUNCH_ADOPTION_VIZ_V
WHERE months_since_launch BETWEEN 0 AND 5
GROUP BY channel, launch_year, months_since_launch
ORDER BY channel, launch_year, months_since_launch;

CLEAR COLUMNS
CLEAR BREAKS
TTITLE OFF
SET LINESIZE 100
SET PAGESIZE 14
PROMPT
PROMPT Preview complete. View LAUNCH_ADOPTION_VIZ_V remains in the
PROMPT schema for your visualization tool to query directly.
