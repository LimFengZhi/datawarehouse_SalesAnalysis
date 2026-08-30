-- ===================================================================
-- 01_supplier_performance_viz_v.sql
-- SUPPLIER PROCUREMENT VIEW FOR VISUALIZATION (Power BI / Tableau /
-- Excel / etc.)
--
-- Run once in SQL*Plus as the warehouse owner to (re)create it:
--   sqlplus dwh/yourpassword@XE
--   @analysis\elisha\01_supplier_performance_viz_v.sql
--
-- WHY A SEPARATE VIEW
--   SUPPLIER_PROCUREMENT_V (defined inside 01_supplier_performance.sql)
--   filters on &start_year_prompt / &end_year_prompt via SQL*Plus
--   ACCEPT, and is DROPped at the end of that script. A BI tool
--   connects over ODBC/JDBC and can neither answer an ACCEPT prompt
--   nor rely on a view that only exists for the duration of one
--   SQL*Plus session. This view hardcodes the slice to the full
--   dataset (2019-2025) instead, and is left in the schema
--   permanently (CREATE OR REPLACE, never DROPped) so a
--   visualization tool can query it directly at any time:
--     SELECT * FROM SUPPLIER_PROCUREMENT_VIZ_V;
--
-- GRAIN: supplier x product x branch x quarter (same grain as the
-- interactive report's view) - deliberately NOT pre-aggregated to
-- supplier level, so the BI tool can filter/group/drill down on
-- its own (by product, by branch, by quarter, etc.) instead of
-- only ever seeing one fixed rollup.
--
-- NOTE: supplier_dim / product_dim are SCD2, so grouping is on the
-- NATURAL keys (sup_ID, product_ID) - one supplier/product rolls up
-- as one line no matter how many price versions it owns in the
-- 2019-2025 window.
-- ===================================================================

CREATE OR REPLACE VIEW SUPPLIER_PROCUREMENT_VIZ_V AS
SELECT
    sd.sup_ID,
    MAX(sd.sup_name)          AS sup_name,
    pd.product_ID,
    MAX(pd.product_name)      AS product_name,
    MAX(pd.product_category)  AS product_category,
    bd.br_ID,
    MAX(bd.br_city)           AS br_city,
    dd.cal_year,
    dd.cal_quarter,
    SUM(pf.purchase_total_cost)      AS spend_in_geo,
    SUM(pf.purchase_qty)             AS units_in_geo,
    COUNT(DISTINCT pf.purchase_ID)   AS orders_in_geo
FROM purchase_fact pf
JOIN date_dim     dd ON pf.date_key     = dd.date_key
JOIN supplier_dim sd ON pf.supplier_key = sd.supplier_key
JOIN product_dim  pd ON pf.product_key  = pd.product_key
JOIN branch_dim   bd ON pf.branch_key   = bd.branch_key
WHERE
    dd.cal_year BETWEEN 2019 AND 2025
GROUP BY
    sd.sup_ID,
    pd.product_ID,
    bd.br_ID,
    dd.cal_year,
    dd.cal_quarter;

PROMPT View SUPPLIER_PROCUREMENT_VIZ_V created (or replaced).
PROMPT This view is persistent - point your visualization tool at it
PROMPT directly. Re-run this script any time to refresh its definition.
PROMPT

-- ===================================================================
-- Formatted preview - for eyeballing the view's contents in SQL*Plus.
-- NOTE: this COLUMN formatting lives in the SQL*Plus session only -
-- Oracle views carry no display formatting of their own, and a BI
-- tool ignores all of this and renders the raw columns its own way.
-- The raw sup_ID/product_ID/br_ID surrogate-ish columns are hidden
-- here (NOPRINT) since the *_name columns already identify each row
-- for a human reading this preview; a BI tool still sees them.
-- ===================================================================
SET PAGESIZE 200
SET LINESIZE 150

COLUMN sup_ID            NOPRINT
COLUMN product_ID        NOPRINT
COLUMN br_ID              NOPRINT
COLUMN sup_name           FORMAT A29           HEADING 'Supplier'
COLUMN product_name       FORMAT A43           HEADING 'Product'
COLUMN product_category   FORMAT A16           HEADING 'Category'
COLUMN br_city            FORMAT A15           HEADING 'Branch'
COLUMN cal_year           FORMAT 9999          HEADING 'Year'
COLUMN cal_quarter        FORMAT 9             HEADING 'Qtr'
COLUMN spend_in_geo       FORMAT 9,999,990.00  HEADING 'Spend (RM)'
COLUMN units_in_geo       FORMAT 999,999       HEADING 'Units'
COLUMN orders_in_geo      FORMAT 999,999       HEADING 'Orders'

TTITLE CENTER 'SUPPLIER_PROCUREMENT_VIZ_V - Preview' SKIP 2

SELECT *
FROM SUPPLIER_PROCUREMENT_VIZ_V
ORDER BY sup_name, cal_year, cal_quarter, product_name;

CLEAR COLUMNS
TTITLE OFF
SET LINESIZE 100
SET PAGESIZE 14
PROMPT
PROMPT Preview complete. View SUPPLIER_PROCUREMENT_VIZ_V remains in the
PROMPT schema for your visualization tool to query directly.
