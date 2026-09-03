-- ===================================================================
-- 01b_branch_profitability_both_viz.sql
-- GLOW BEAUTY - CHART FEED FOR 01b_branch_profitability_both.sql
--   ONE view holding EVERY line the report can print, at the finest
--   grain it works at: one row per BRANCH per YEAR, all five facts
--   drilled across. Both report sections and every chart drawn from
--   them are an aggregation or a filter of this one table - the
--   plotting tool (Excel / Power BI / Python) does the grouping that
--   the report's prompts and sections do.
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\visualisation\01b_branch_profitability_both_viz.sql
--
-- VIEW CREATED
--   viz01b_branch_pnl_v
--     br_id, br_name,          the branch axis - one row per branch
--     br_state, br_city        per year (99 rows on the full dataset:
--                              13 branches x 7 years + 4 x 2 years)
--     cal_year                 the time axis (2019-2025)
--     order_revenue            order_fact.order_net_amt, Completed
--     service_revenue          reservation_fact.serv_net_amt, Completed
--     total_revenue            order + service
--     purchase_cost            purchase_fact.purchase_total_cost
--     staff_cost               salary base_amt + bonus_amt (gross)
--     utility_cost             branch_utils_fact.payment_amt
--     total_cost               purchase + staff + utility
--     net_profit               total_revenue - total_cost
--     margin_pct               net_profit / total_revenue x 100
--     purch_pct_revenue        purchase_cost / total_revenue x 100
--   Naming follows the rewritten report: revenue, not sales.
--
-- HOW TO REBUILD EACH REPORT SECTION FROM IT
--   1  ranking      AVERAGE(net_profit) by br_name, sorted descending
--                   - because the grain is branch x year, the AVERAGE
--                   aggregation IS the report's avg-profit-per-year,
--                   and it ranks all 17 branches with no TOP n cut.
--                   AVERAGE the cost columns the same way for the
--                   AVG PURCH / AVG STAFF / AVG UTIL / AVG TOTAL COST
--                   columns. Filter cal_year for the report's period.
--   2  drill-down   filter one br_name, cal_year on the axis: the
--                   revenue split, the three cost lines, total_cost,
--                   net_profit, margin_pct
--
-- DO NOT SUM net_profit ACROSS YEARS TO RANK BRANCHES. The four
-- branches that opened 2024-01-01 (Seremban, Kuantan, Subang Jaya,
-- Bukit Jalil) hold 2 rows each against everyone else's 7; a SUM
-- ranks them last for having traded less, which is exactly what the
-- report's average-per-year measure exists to avoid. COUNT(*) per
-- branch gives the report's YRS column - carry it onto the chart so
-- a short trading life is visible.
--
-- CONVENTIONS (same as the report - see its header for the why)
--   revenue = the *_net_amt columns (net of discount and 6 % SST),
--   'Completed' rows only; branches grouped on the NATURAL key br_ID
--   and labelled by br_name (branch_dim is no longer SCD2 - one
--   row per branch - so the natural-key grouping is now just tidy)
-- ===================================================================

SET SQLBLANKLINES ON

CREATE OR REPLACE VIEW viz01b_branch_pnl_v AS
WITH branch_year AS (
    SELECT b.br_ID,
           MAX(b.br_name)  AS br_name,
           MAX(b.br_state) AS br_state,
           MAX(b.br_city)  AS br_city,
           d.cal_year,
           SUM(CASE WHEN x.measure = 'PROD_REV' THEN x.amt ELSE 0 END) AS order_revenue,
           SUM(CASE WHEN x.measure = 'SERV_REV' THEN x.amt ELSE 0 END) AS service_revenue,
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
SELECT br_ID                            AS br_id,
       br_name,
       br_state,
       br_city,
       cal_year,
       order_revenue,
       service_revenue,
       order_revenue + service_revenue  AS total_revenue,
       purchase_cost,
       staff_cost,
       utility_cost,
       purchase_cost + staff_cost + utility_cost     AS total_cost,
       order_revenue + service_revenue
         - purchase_cost - staff_cost - utility_cost AS net_profit,
       ROUND((order_revenue + service_revenue
              - purchase_cost - staff_cost - utility_cost)
             / NULLIF(order_revenue + service_revenue, 0) * 100, 1) AS margin_pct,
       ROUND(purchase_cost
             / NULLIF(order_revenue + service_revenue, 0) * 100, 1) AS purch_pct_revenue
FROM   branch_year;

-- ###################################################################
-- sanity (0 rows on an empty warehouse is fine)
-- ###################################################################
SELECT 'viz01b_branch_pnl_v' AS view_name, COUNT(*) AS row_count
FROM   viz01b_branch_pnl_v;
