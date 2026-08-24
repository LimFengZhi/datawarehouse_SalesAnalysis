-- ===================================================================
-- 03_customer_hotspot_viz.sql
-- GLOW BEAUTY - CHART FEED FOR 03_customer_hotspot.sql
--   ONE view with everything the report covers: one row per customer
--   HOME CITY per YEAR, with the has_shop flag. Every graph of the
--   report is an aggregation or filter of this table - the plotting
--   tool (Excel / Power BI / Python) does the grouping the report's
--   prompts and sections do, and cal_year gives it a year slicer.
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\visualisation\03_customer_hotspot_viz.sql
--
-- VIEW CREATED
--   viz03_customer_hotspot_v
--     cus_state, cus_city   where the buyer LIVES (not where they
--                           paid - since 2022 online orders ship
--                           from any branch)
--     cal_year              the year the money was spent (2019-2025)
--     has_shop              'Y' if Glow Beauty has a branch in that
--                           city, 'N' if not - the N rows are the
--                           expansion candidates
--     customers             COUNT(DISTINCT cus_ID) who spent THAT
--                           YEAR - customers ACTIVE in the year, not
--                           everyone who ever bought
--     sales                 order_net_amt + serv_net_amt, Completed
--     per_head              sales / customers, within that year
--
-- HOW TO REBUILD EACH REPORT SECTION FROM IT
--   1  states    group by cus_state (slice the years you want):
--                SUM(sales) is safe across cities AND years; shops =
--                count of DISTINCT cities with has_shop = 'Y'
--   2  cities    filter one cus_state and has_shop = 'N', rank by
--                sales; share of state = city sales / the WHOLE
--                state's sales (filter has_shop AFTER the ratio)
--
-- THE ONE TRAP: never SUM(customers) ACROSS YEARS. It is a distinct
-- count per year, and a returning customer sits in every year they
-- bought - summing 2019-2025 would count them up to seven times.
-- Summing across CITIES within one year is fine (a person lives in
-- exactly one city). For a true multi-year unique-customer figure,
-- run the report (03_customer_hotspot.sql) - its prompts count
-- distinct over exactly the window you give it.
--
-- CONVENTIONS (same as the report - see its header for the why)
--   sales      net of discount and the 6 % SST, 'Completed' only
--   customers  the natural key cus_ID, never customer_key
--              (customer_dim is SCD2 - one person, several rows)
-- ===================================================================

SET SQLBLANKLINES ON

CREATE OR REPLACE VIEW viz03_customer_hotspot_v AS
WITH spend AS (
    SELECT c.cus_ID, c.cus_state, c.cus_city, d.cal_year, x.amt
    FROM   (SELECT customer_key, date_key, order_net_amt AS amt
            FROM   order_fact WHERE order_status = 'Completed'
            UNION ALL
            SELECT customer_key, date_key, serv_net_amt
            FROM   reservation_fact WHERE res_status = 'Completed') x
    JOIN   date_dim     d ON d.date_key     = x.date_key
    JOIN   customer_dim c ON c.customer_key = x.customer_key
),
by_city_year AS (
    SELECT cus_state, cus_city, cal_year,
           COUNT(DISTINCT cus_ID) AS customers,
           SUM(amt)               AS sales
    FROM   spend
    GROUP  BY cus_state, cus_city, cal_year
),
shop_city AS (
    -- deliberately br_city, NOT br_name: this compares a branch
    -- LOCATION with a customer's home city. branch_dim is SCD2, so
    -- DISTINCT folds the versions of one branch back to one city.
    SELECT DISTINCT UPPER(br_city) AS ucity
    FROM   branch_dim
)
SELECT b.cus_state,
       b.cus_city,
       b.cal_year,
       CASE WHEN s.ucity IS NULL THEN 'N' ELSE 'Y' END   AS has_shop,
       b.customers,
       b.sales,
       ROUND(b.sales / NULLIF(b.customers, 0), 2)        AS per_head
FROM   by_city_year b
LEFT   JOIN shop_city s ON s.ucity = UPPER(b.cus_city);

-- ###################################################################
-- sanity (0 rows on an empty warehouse is fine)
-- ###################################################################
SELECT 'viz03_customer_hotspot_v' AS view_name, COUNT(*) AS row_count
FROM   viz03_customer_hotspot_v;
