-- ===================================================================
-- 01_branch_profitability_viz.sql
-- GLOW BEAUTY - CHART FEEDS FOR 01_branch_profitability.sql
--   the two queries of the branch profitability report as plain
--   views, one per graph - no prompts, no SQL*Plus formatting,
--   raw numbers only. Load them with SELECT * FROM <view> in
--   Excel / Power BI / Python and do the filtering there.
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\visualisation\01_branch_profitability_viz.sql
--
-- VIEWS CREATED (both cover every year in the warehouse)
--   viz01_branch_rank_v   mirrors section 1 - one row per branch,
--                         the average year and the chain-wide rank.
--                         GRAPH: ranking bar chart (profit or margin)
--   viz01_branch_year_v   mirrors section 2 - one row per branch per
--                         year, revenue split and every cost line.
--                         GRAPH: year-by-year lines / stacked bars for
--                         one branch (filter br_name in the tool)
--
-- CONVENTIONS (same as the report - see its header for the why)
--   revenue     = order_net_amt / serv_net_amt, 'Completed' rows only
--   staff cost  = base_amt + bonus_amt (gross pay)
--   net profit  = revenue - purchase - staff - utilities
--   margin_pct  = profit / revenue x 100, one decimal, as a NUMBER
--   branches grouped on the NATURAL key br_ID (branch_dim is SCD2)
-- ===================================================================

SET SQLBLANKLINES ON

-- ###################################################################
-- viz01_branch_year_v - one row per branch per YEAR
-- The report's BRANCH_YEAR drill-across, ungated: all five facts on
-- one (branch, year) grain. Everything else derives from this.
-- ###################################################################
CREATE OR REPLACE VIEW viz01_branch_year_v AS
WITH branch_year AS (
    SELECT b.br_ID,
           -- attributes via MAX so an SCD2 attribute change can never
           -- split one branch-year into two rows
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
-- viz01_branch_rank_v - one row per BRANCH, the average year
-- Built on the view above so the two graphs can never disagree.
-- Averaging over the years a branch actually traded is what makes a
-- 2024 opening comparable with a 2019 branch (see the report's NOTE).
-- ###################################################################
CREATE OR REPLACE VIEW viz01_branch_rank_v AS
WITH branch_pnl AS (
    SELECT br_id,
           MAX(br_name)       AS br_name,
           MAX(br_state)      AS br_state,
           MAX(br_city)       AS br_city,
           COUNT(*)           AS yrs,
           AVG(total_sales)   AS avg_sales,
           AVG(purchase_cost) AS avg_purchase,
           AVG(staff_cost)    AS avg_staff,
           AVG(utility_cost)  AS avg_utility,
           AVG(net_profit)    AS avg_profit
    FROM   viz01_branch_year_v
    GROUP  BY br_id
)
SELECT RANK() OVER (ORDER BY avg_profit DESC) AS profit_rank,
       br_id,
       br_name,
       br_state,
       br_city,
       yrs,
       avg_sales,
       avg_purchase,
       avg_staff,
       avg_utility,
       avg_profit,
       ROUND(avg_profit / NULLIF(avg_sales, 0) * 100, 1) AS margin_pct
FROM   branch_pnl;

-- ###################################################################
-- sanity - one count per view (0 rows on an empty warehouse is fine)
-- ###################################################################
SELECT 'viz01_branch_rank_v' AS view_name, COUNT(*) AS row_count
FROM   viz01_branch_rank_v;
SELECT 'viz01_branch_year_v' AS view_name, COUNT(*) AS row_count
FROM   viz01_branch_year_v;
