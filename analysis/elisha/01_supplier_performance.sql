CLEAR BREAKS
CLEAR COMPUTES
CLEAR COLUMNS
SET DEFINE ON
SET VERIFY OFF
SET FEEDBACK OFF
SET ECHO OFF
SET PAGESIZE 200
SET LINESIZE 100

ACCEPT start_year_prompt CHAR PROMPT 'Enter Start Year for Analysis (e.g., 2019): '
ACCEPT end_year_prompt   CHAR PROMPT 'Enter End Year for Analysis (e.g., 2025): '
PROMPT

CREATE OR REPLACE VIEW SUPPLIER_PROCUREMENT_V AS
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
    dd.cal_year BETWEEN TO_NUMBER('&start_year_prompt') AND
TO_NUMBER('&end_year_prompt')
GROUP BY
    sd.sup_ID,
    pd.product_ID,
    bd.br_ID,
    dd.cal_year,
    dd.cal_quarter;

PROMPT

-- Report Section 1: Supplier-Level Procurement Summary
TTITLE CENTER '=====================================================' SKIP 1 -
       CENTER 'Supplier-Level Procurement Performance Summary' SKIP 1 -
       CENTER 'For Year &start_year_prompt to &end_year_prompt' SKIP 1 -
       CENTER '=====================================================' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'Page: ' SQL.PNO SKIP 2

-- Define column formats
COLUMN supplier_name     FORMAT A29          HEADING 'Supplier'
COLUMN total_spend       FORMAT 99,999,990.00 HEADING 'Total Spend|(RM)'
COLUMN purchase_orders   FORMAT 999,999      HEADING 'Purchase|Orders'
COLUMN avg_unit_cost     FORMAT 9,990.99     HEADING 'Avg Cost|Per Unit (RM)'
COLUMN pct_total_spend   FORMAT A10          HEADING '% of Total|Spend'
COLUMN pct_total_orders  FORMAT A10          HEADING '% of Total|Orders'

BREAK ON ROW SKIP 1

-- The query aggregates the view up to supplier level.
WITH
SUPPLIER_AGGREGATES AS (
    SELECT
        sup_ID,
        MAX(sup_name)       AS supplier_name,
        SUM(spend_in_geo)   AS spend_of_supplier,
        SUM(units_in_geo)   AS units_of_supplier,
        SUM(orders_in_geo)  AS orders_of_supplier
    FROM SUPPLIER_PROCUREMENT_V
    GROUP BY sup_ID
),
PERIOD_TOTALS AS (
    SELECT
        SUM(spend_in_geo)  AS total_spend_in_period,
        SUM(orders_in_geo) AS total_orders_in_period
    FROM SUPPLIER_PROCUREMENT_V
)
SELECT
    sa.supplier_name,
    sa.spend_of_supplier                          AS total_spend,
    sa.orders_of_supplier                         AS purchase_orders,
    sa.spend_of_supplier / sa.units_of_supplier   AS avg_unit_cost,
    TO_CHAR(ROUND((sa.spend_of_supplier  * 100.0 /
pt.total_spend_in_period), 2), '990.99') || '%'   AS pct_total_spend,
    TO_CHAR(ROUND((sa.orders_of_supplier * 100.0 /
pt.total_orders_in_period), 2), '990.99') || '%'  AS pct_total_orders
FROM
    SUPPLIER_AGGREGATES sa,
    PERIOD_TOTALS pt
WHERE
    sa.units_of_supplier > 0
ORDER BY
    total_spend DESC;

-- Report Section 2: Top N Products per Supplier
PROMPT
ACCEPT top_n_prompt CHAR PROMPT 'Enter the number of Top Products per supplier to display (e.g., 3): '
PROMPT

SET LINESIZE 140
CLEAR COLUMNS
CLEAR BREAKS
TTITLE CENTER '======================================================' SKIP 1 -
       CENTER 'Top &top_n_prompt Products per Supplier by Procurement Spend' SKIP 1 -
       CENTER 'For Year &start_year_prompt to &end_year_prompt' SKIP 1 -
       CENTER '======================================================' SKIP 2

COLUMN supplier_name      FORMAT A29           HEADING 'Supplier'
COLUMN ranking            FORMAT 999           HEADING 'Rank'
COLUMN product_name       FORMAT A37           HEADING 'Product'
COLUMN product_category   FORMAT A16           HEADING 'Category'
COLUMN units_bought       FORMAT 999,999       HEADING 'Units'
COLUMN spend_on_product   FORMAT 9,999,990.00  HEADING 'Spend (RM)'
COLUMN pct_supplier_spend FORMAT A8            HEADING 'Spend %'
COLUMN cumulative_pct     FORMAT A8           HEADING 'Cum %'
COLUMN supplier_total     NOPRINT

BREAK ON supplier_name SKIP 1

WITH
RANKED_PRODUCTS AS (
    SELECT
        pv.sup_ID,
        MAX(pv.sup_name)         AS supplier_name,
        RANK() OVER (PARTITION BY pv.sup_ID
                     ORDER BY SUM(pv.spend_in_geo) DESC) AS ranking,
        MAX(pv.product_name)     AS product_name,
        MAX(pv.product_category) AS product_category,
        SUM(pv.units_in_geo)     AS units_bought,
        SUM(pv.spend_in_geo)     AS spend_on_product,
        SUM(SUM(pv.spend_in_geo))
            OVER (PARTITION BY pv.sup_ID) AS supplier_total
    FROM
        SUPPLIER_PROCUREMENT_V pv
    GROUP BY
        pv.sup_ID, pv.product_ID
),
CUMULATIVE_PRODUCTS AS (
    SELECT
        rp.*,
        (rp.spend_on_product * 100.0 / rp.supplier_total) AS pct_supplier_spend,
        SUM(rp.spend_on_product * 100.0 / rp.supplier_total)
            OVER (PARTITION BY rp.sup_ID ORDER BY rp.ranking) AS cumulative_pct
    FROM RANKED_PRODUCTS rp
)
SELECT
    supplier_name,
    ranking,
    product_name,
    product_category,
    units_bought,
    spend_on_product,
    TO_CHAR(ROUND(pct_supplier_spend, 1), '990.9') || '%' AS pct_supplier_spend,
    TO_CHAR(ROUND(cumulative_pct, 1),     '990.9') || '%' AS cumulative_pct,
    supplier_total
FROM CUMULATIVE_PRODUCTS
WHERE ranking <= TO_NUMBER('&top_n_prompt')
ORDER BY
    supplier_total DESC, ranking;

-- Report Section 3: Branch and Quarterly Split per Supplier
PROMPT

CLEAR COLUMNS
CLEAR BREAKS
TTITLE CENTER '================================================================' SKIP 1 -
       CENTER 'Procurement by Branch and Quarter per Supplier' SKIP 1 -
       CENTER 'For Year &start_year_prompt to &end_year_prompt' SKIP 1 -
       CENTER '================================================================' SKIP 2

COLUMN supplier_name  FORMAT A29           HEADING 'Supplier'
COLUMN br_city        FORMAT A15           HEADING 'Branch'
COLUMN q1_spend       FORMAT 9,999,990.00  HEADING 'Q1 (RM)'
COLUMN q2_spend       FORMAT 9,999,990.00  HEADING 'Q2 (RM)'
COLUMN q3_spend       FORMAT 9,999,990.00  HEADING 'Q3 (RM)'
COLUMN q4_spend       FORMAT 9,999,990.00  HEADING 'Q4 (RM)'
COLUMN branch_total   FORMAT 99,999,990.00 HEADING 'Total (RM)'
COLUMN pct_of_branch_buying FORMAT A9     HEADING 'Total (%)'
COLUMN supplier_total NOPRINT

BREAK ON supplier_name SKIP 1
COMPUTE SUM LABEL 'TOTAL' OF q1_spend q2_spend q3_spend q4_spend branch_total ON supplier_name

SELECT
    MAX(pv.sup_name) AS supplier_name,
    MAX(pv.br_city)  AS br_city,
    SUM(CASE WHEN pv.cal_quarter = 1 THEN pv.spend_in_geo ELSE 0 END) AS q1_spend,
    SUM(CASE WHEN pv.cal_quarter = 2 THEN pv.spend_in_geo ELSE 0 END) AS q2_spend,
    SUM(CASE WHEN pv.cal_quarter = 3 THEN pv.spend_in_geo ELSE 0 END) AS q3_spend,
    SUM(CASE WHEN pv.cal_quarter = 4 THEN pv.spend_in_geo ELSE 0 END) AS q4_spend,
    SUM(pv.spend_in_geo)                                              AS branch_total,
    TO_CHAR(ROUND(SUM(pv.spend_in_geo) * 100.0 /
SUM(SUM(pv.spend_in_geo)) OVER (PARTITION BY pv.sup_ID), 1), '990.9') || '%'
                                                                      AS pct_of_branch_buying,
    SUM(SUM(pv.spend_in_geo)) OVER (PARTITION BY pv.sup_ID)           AS supplier_total
FROM
    SUPPLIER_PROCUREMENT_V pv
GROUP BY
    pv.sup_ID, pv.br_ID
ORDER BY
    supplier_total DESC, branch_total DESC;

PROMPT
PROMPT Report complete.
PROMPT
DROP VIEW SUPPLIER_PROCUREMENT_V;
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE start_year_prompt
UNDEFINE end_year_prompt
UNDEFINE top_n_prompt
SET FEEDBACK ON
SET VERIFY ON
TTITLE OFF



