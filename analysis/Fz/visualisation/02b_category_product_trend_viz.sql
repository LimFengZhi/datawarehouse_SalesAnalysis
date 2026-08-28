-- ===================================================================
-- 02b_category_product_trend_viz.sql
-- GLOW BEAUTY - CHART FEED FOR 02b_category_product_trend.sql
--   ONE view with everything the report covers, at the finest grain:
--   product x branch x year x quarter, costed - the PERMANENT twin of
--   the temporary costed_sales_v the report creates and drops. Every
--   graph of the report is an aggregation of this one table; the
--   plotting tool (Excel / Power BI / Python) does the grouping the
--   report's prompts and sections do.
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\visualisation\02b_category_product_trend_viz.sql
--
-- VIEW CREATED
--   viz02b_costed_sales_v
--     cal_year, cal_quarter          the time axis
--     br_id, br_name, br_state,      the branch axis
--     br_city
--     product_category, product_id,  the product axis
--     product_name
--     units_sold, revenue, cogs,     the measures - all additive, so
--     gross_profit                   they sum cleanly to any cut
--
-- HOW TO REBUILD EACH REPORT SECTION FROM IT
--   0a state menu    group by br_state. The report's AVG ANNUAL
--                    REVENUE / BR divides SUM(revenue) by the
--                    DISTINCT COUNT of (br_id, cal_year) PAIRS -
--                    branch-years actually traded. Do NOT divide by
--                    (branch count x years): the four 2024 openings
--                    trade fewer years and would drag their state
--                    down for being young. Same denominator for the
--                    avg COGS and avg GP columns.
--   0b branch menu   group by br_name, divide by its DISTINCT years
--                    traded (carry the year count onto the chart so
--                    a short trading life is visible)
--   1  year x cat    group by cal_year, product_category; rank on
--                    gross profit within each year; share = category
--                    GP / that year's total GP
--   2  avg product   filter one product_category, group by cal_year,
--                    divide every SUM by the DISTINCT COUNT of
--                    product_id in that year (the report prints that
--                    count as PRODUCTS - keep it on the chart)
--   3  top products  filter one product_category + one cal_year,
--                    group by product_name, rank on gross profit,
--                    pivot cal_quarter for the quarter columns,
--                    share = product GP / the shelf's GP that year
--
-- CONVENTIONS (same as the report - see its header for the why)
--   revenue = order_net_amt, 'Completed' rows only
--   COGS    = units sold x unit cost from purchase_fact, matched on
--             (product, branch, year), falling back to the chain's
--             product-year cost when a branch sold a SKU in a year
--             it did not restock it
--   gross margin % is flat by construction (~59 % on every product) -
--   rank and compare on gross profit in RM, never on the margin
--   PRODUCT sales only, exactly like the report - services have no
--   product dimension and no COGS
-- ===================================================================

SET SQLBLANKLINES ON

CREATE OR REPLACE VIEW viz02b_costed_sales_v AS
WITH cby AS (
    SELECT p.product_ID, b.br_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, b.br_ID, d.cal_year
),
cy AS (
    SELECT p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, d.cal_year
),
line AS (
    SELECT p.product_ID,
           -- attributes via MAX so an SCD2 rename can never split one
           -- product-quarter into two rows
           MAX(p.product_name)     AS product_name,
           MAX(p.product_category) AS product_category,
           b.br_ID,
           MAX(b.br_name)          AS br_name,
           MAX(b.br_state)         AS br_state,
           MAX(b.br_city)          AS br_city,
           d.cal_year, d.cal_quarter,
           SUM(f.order_qty)        AS units,
           SUM(f.order_net_amt)    AS rev
    FROM   order_fact  f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY p.product_ID, b.br_ID, d.cal_year, d.cal_quarter
)
SELECT l.cal_year,
       l.cal_quarter,
       l.br_ID                            AS br_id,
       l.br_name,
       l.br_state,
       l.br_city,
       l.product_category,
       l.product_ID                       AS product_id,
       l.product_name,
       l.units                            AS units_sold,
       l.rev                              AS revenue,
       l.units * NVL(cby.ucost, cy.ucost) AS cogs,
       l.rev - l.units * NVL(cby.ucost, cy.ucost) AS gross_profit
FROM   line l
LEFT   JOIN cby ON cby.product_ID = l.product_ID
               AND cby.br_ID      = l.br_ID
               AND cby.cal_year   = l.cal_year
LEFT   JOIN cy  ON cy.product_ID  = l.product_ID
               AND cy.cal_year    = l.cal_year;

-- ###################################################################
-- sanity (0 rows on an empty warehouse is fine)
-- ###################################################################
SELECT 'viz02b_costed_sales_v' AS view_name, COUNT(*) AS row_count
FROM   viz02b_costed_sales_v;
