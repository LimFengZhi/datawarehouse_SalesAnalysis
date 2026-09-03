-- ===================================================================
-- 03_customer_hotspot_viz.sql
-- GLOW BEAUTY - CHART FEED FOR customer_hotspot_analysis.sql
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
--     revenue               order_net_amt + serv_net_amt, Completed
--     product_rev           the order_fact part - fulfillable ONLINE
--                           since 2022, so a shopless city's product
--                           money is already served
--     service_rev           the reservation_fact part - the customer
--                           must TRAVEL to a branch, so in a shopless
--                           city this is the expansion evidence
--     per_head              revenue / customers, within that year
--
-- HOW TO REBUILD EACH REPORT SECTION FROM IT
--   1  states    group by cus_state, slice the years: the report's
--                AVG PER YEAR columns are the AVERAGE over cal_year
--                of the yearly SUMs (sum the cities within each year
--                first, then average the years); shops = count of
--                DISTINCT cities with has_shop = 'Y'
--   2  cities    filter one cus_state and has_shop = 'N', rank by
--                revenue; share of state = city revenue / the WHOLE
--                state's (filter has_shop AFTER the ratio)
--
-- TWO TRAPS
--   never SUM(customers) ACROSS YEARS - it is a distinct count per
--   year, and a returning customer sits in every year they bought
--   (summing 2019-2025 counts them up to seven times). Summing
--   across CITIES within one year is fine (a person lives in exactly
--   one city). For a true multi-year unique-customer figure, run the
--   report - its prompts count distinct over the window you give it.
--
--   never chart service_rev / revenue as separating cities - the
--   product/service MIX is flat (~21 % service) everywhere by
--   generator construction. Chart the service RM itself: in a
--   shopless city it is demand travelling to another town.
--
-- CONVENTIONS (same as the report - see its header for the why)
--   revenue    net of discount and the 6 % SST, 'Completed' only
--   customers  the natural key cus_ID, never customer_key
--              (customer_dim is SCD2 - one person, several rows)
-- ===================================================================

SET SQLBLANKLINES ON

CREATE OR REPLACE VIEW viz03_customer_hotspot_v AS
WITH spend AS (
    SELECT c.cus_ID, c.cus_state, c.cus_city, d.cal_year, x.amt, x.src
    FROM   (SELECT customer_key, date_key, order_net_amt AS amt,
                   'P' AS src
            FROM   order_fact WHERE order_status = 'Completed'
            UNION ALL
            SELECT customer_key, date_key, serv_net_amt, 'S'
            FROM   reservation_fact WHERE res_status = 'Completed') x
    JOIN   date_dim     d ON d.date_key     = x.date_key
    JOIN   customer_dim c ON c.customer_key = x.customer_key
),
by_city_year AS (
    SELECT cus_state, cus_city, cal_year,
           COUNT(DISTINCT cus_ID) AS customers,
           SUM(amt)               AS revenue,
           SUM(CASE WHEN src = 'P' THEN amt ELSE 0 END) AS product_rev,
           SUM(CASE WHEN src = 'S' THEN amt ELSE 0 END) AS service_rev
    FROM   spend
    GROUP  BY cus_state, cus_city, cal_year
),
shop_city AS (
    -- deliberately br_city, NOT br_name: this compares a branch
    -- LOCATION with a customer's home city. branch_dim holds one row
    -- per branch; DISTINCT just folds branches sharing a city.
    SELECT DISTINCT UPPER(br_city) AS ucity
    FROM   branch_dim
)
SELECT b.cus_state,
       b.cus_city,
       b.cal_year,
       CASE WHEN s.ucity IS NULL THEN 'N' ELSE 'Y' END   AS has_shop,
       b.customers,
       b.revenue,
       b.product_rev,
       b.service_rev,
       ROUND(b.revenue / NULLIF(b.customers, 0), 2)      AS per_head
FROM   by_city_year b
LEFT   JOIN shop_city s ON s.ucity = UPPER(b.cus_city);

-- ###################################################################
-- sanity (0 rows on an empty warehouse is fine)
-- ###################################################################
SELECT 'viz03_customer_hotspot_v' AS view_name, COUNT(*) AS row_count
FROM   viz03_customer_hotspot_v;
