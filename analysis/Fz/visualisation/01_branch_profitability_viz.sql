-- ===================================================================
-- 01_branch_profitability_viz.sql
-- GLOW BEAUTY - CHART FEED FOR 01_branch_profitability.sql
--   ONE view with everything the report covers, at the finest grain:
--   one row per BRANCH per YEAR, all five facts drilled across.
--   Every graph of the report is an aggregation or filter of this
--   table - the plotting tool (Excel / Power BI / Python) does the
--   grouping the report's prompts and sections do.
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\visualisation\01_branch_profitability_viz.sql
--
-- VIEW CREATED
--   viz01_branch_profit_v
--     br_id, br_name,          the branch axis - one row per branch
--     br_state, br_city        per year (~101 rows)
--     cal_year                 the time axis (2019-2025)
--     order_sales              order_fact.order_net_amt, Completed
--     service_sales            reservation_fact.serv_net_amt, Completed
--     total_sales              order + service
--     purchase_cost            purchase_fact.purchase_total_cost
--     staff_cost               salary base_amt + bonus_amt (gross)
--     utility_cost             branch_utils_fact.payment_amt
--     total_cost               purchase + staff + utility
--     net_profit               total_sales - total_cost
--     margin_pct               net_profit / total_sales x 100
--
-- HOW TO REBUILD EACH REPORT SECTION FROM IT
--   1  ranking     bar chart of AVERAGE(net_profit) by br_name -
--                  because the grain is branch x year, the AVERAGE
--                  aggregation IS the report's avg-profit-per-year;
--                  sort ascending for the LOWEST n, use a Top N
--                  filter for the cutoff
--   2  drill-down  filter one br_name, cal_year on the axis:
--                  sales split, cost lines, net_profit, margin_pct
--
-- CONVENTIONS (same as the report - see its header for the why)
--   revenue = the *_net_amt columns (net of discount and 6 % SST),
--   'Completed' rows only; branches grouped on the NATURAL key br_ID
--   (branch_dim is SCD2) and labelled by br_name
-- ===================================================================

SET SQLBLANKLINES ON

CREATE OR REPLACE VIEW viz01_branch_profit_v AS
WITH branch_year AS (
    SELECT b.br_ID,
           MAX(b.br_name)  AS br_name,
           MAX(b.br_state) AS br_state,
           MAX(b.br_city)  AS br_city,
           d.cal_year,
           SUM(CASE WHEN x.measure = 'PROD_REV' THEN x.amt ELSE 0 END) AS order_sales,
           SUM(CASE WHEN x.measure = 'SERV_REV' THEN x.amt ELSE 0 END) AS service_sales,
           SUM(CASE WHEN x.measure = 'PURCHASE' THEN x.amt ELSE 0 END) AS purchase_cost,
           SUM(CASE WHEN x.measure = 'STAFF'    THEN x.amt ELSE 0 END) AS staff_cost,
           SUM(CASE WHEN x.measure = 'UTILITY'  THEN x.amt ELSE 0 END) AS utility_cost
    FROM   (SELECT f.date_key, f.branch_key, 'PROD_REV' AS measure,
                   f.order_net_amt AS amt
            FROM   order_fact f
            WHERE  f.order_status = 'Completed'
            UNION ALL
            SELECT f.date_key, f.branch_key, 'SERV_REV',
                   f.serv_net_amt
            FROM   reservation_fact f
            WHERE  f.res_status = 'Completed'
            UNION ALL
            SELECT f.date_key, f.branch_key, 'PURCHASE', f.purchase_total_cost
            FROM   purchase_fact f
            UNION ALL
            SELECT f.date_key, f.branch_key, 'STAFF', f.base_amt + f.bonus_amt
            FROM   salary_payment_fact f
            UNION ALL
            SELECT f.date_key, f.branch_key, 'UTILITY', f.payment_amt
            FROM   branch_utils_fact f) x
    JOIN   date_dim   d ON d.date_key   = x.date_key
    JOIN   branch_dim b ON b.branch_key = x.branch_key
    GROUP  BY b.br_ID, d.cal_year
)
SELECT br_ID                        AS br_id,
       br_name,
       br_state,
       br_city,
       cal_year,
       order_sales,
       service_sales,
       order_sales + service_sales  AS total_sales,
       purchase_cost,
       staff_cost,
       utility_cost,
       purchase_cost + staff_cost + utility_cost   AS total_cost,
       order_sales + service_sales
         - purchase_cost - staff_cost - utility_cost AS net_profit,
       ROUND((order_sales + service_sales
              - purchase_cost - staff_cost - utility_cost)
             / NULLIF(order_sales + service_sales, 0) * 100, 1) AS margin_pct
FROM   branch_year;

-- ###################################################################
-- sanity (0 rows on an empty warehouse is fine)
-- ###################################################################
SELECT 'viz01_branch_profit_v' AS view_name, COUNT(*) AS row_count
FROM   viz01_branch_profit_v;
