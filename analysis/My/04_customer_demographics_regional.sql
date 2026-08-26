-- ===================================================================
-- 04_customer_demographics_regional.sql
-- LOYALTY TIER REVENUE AND DISCOUNT RETURN ANALYSIS
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\My\04_customer_demographics_regional.sql
--
-- PARAMETERS (prompted)
--   start year / end year   the analysis window        (default 2019 / 2025)
--   drill-down year         which year to open up      (Section C)
--   drill-down tier         which loyalty tier to open (Section C)
--
-- WHAT IT ANSWERS
--   1. How much revenue does each loyalty tier actually bring in, how
--      much does an average customer in that tier spend, and how many
--      of them are spending less than they did last year?     [A]
--   2. The loyalty programme costs real money - every tier discount is
--      revenue given away. Does the higher spending of the upper tiers
--      earn that discount back?                               [B]
--   3. For one tier in one year - which age band and gender are those
--      customers, and which of them spend the most?           [C]
--
-- THE TIER USED HERE IS THE STORED ONE
--   customer_dim.cus_loyalty_tier - Bronze / Silver / Gold / Platinum.
--   It is real data (it exists in the OLTP customer table too), and it
--   is what actually drives the discount the customer receives at the
--   till. Nothing in this report invents or re-derives a tier: every
--   figure is grouped on the tier the business itself assigned.
--
-- MEASURES  (Completed rows only, from both revenue facts)
--   Gross Revenue   what the customer would have paid at list price,
--                   before any discount: order_net_amt +
--                   order_discount_amt (and the serv_ equivalents).
--   Discount Given  order_discount_amt + serv_discount_amt - the money
--                   actually handed back to the customer.
--   Net Revenue     order_net_amt + serv_net_amt - what Glow Beauty
--                   keeps. Both already exclude SST, which is collected
--                   for the government (see dwh\create_dwh.sql).
--                   Net Revenue = Gross Revenue - Discount Given.
--   Effective Disc% Discount Given / Gross Revenue * 100. Expect this
--                   to run ABOVE the tier's nominal rate: the fact rows
--                   carry the tier discount AND any promotion running
--                   that day, and the warehouse stores only the
--                   combined amount, so the two cannot be split apart.
--   Net per RM Disc Net Revenue / Discount Given - how many Ringgit of
--                   kept revenue each Ringgit of discount brings back.
--                   HIGHER is better. Read it against Rev per Customer
--                   in the same row: a lower ratio is only acceptable
--                   if that tier's customers spend enough more to
--                   compensate.
--   At Risk         A customer is flagged in a year when that year's
--                   net revenue is LOWER than their own previous year's.
--                   Their first year can never be flagged (nothing to
--                   fall from). Note this catches DECLINE, not total
--                   churn - a customer who stops coming entirely has no
--                   row that year and so is never flagged.
--
-- DIMENSIONS USED (two)
--   customer_dim  cus_ID (natural key - SCD2, so grouped on it, never
--                 customer_key, per CLAUDE.md), cus_loyalty_tier,
--                 cus_age_group, cus_gender  (cus_state is carried by
--                 the view but no section displays it - the hook is
--                 there if a regional cut is ever wanted)
--   date_dim      cal_year
-- FACTS USED (two)
--   order_fact (product revenue), reservation_fact (service revenue)
--
-- VIEWS BUILT AND DROPPED BY THIS SCRIPT (three, layered)
--   customer_annual_value_v    gross / discount / net per customer-year
--   customer_annual_trend_v    + previous year and the at-risk flag
--   customer_profile_value_v   + loyalty tier and demographics
--   All three are dropped at the end so the schema is left as found.
--
-- SECTIONS
--   A  REVENUE BY LOYALTY TIER AND YEAR
--   B  DISCOUNT COST VS REVENUE RETURN BY TIER
--   C  DRILL-DOWN: AGE BAND AND GENDER  (prompted year + tier)
--
-- NOTE ON cus_age_group
--   customer_dim stores the age BAND, not the date of birth, and it is
--   a Type 1 attribute derived against SYSDATE (see CLAUDE.md). So the
--   band is the customer's age TODAY, not their age in the analysis
--   year - a 2019 row shows the band they are in now. That is a
--   property of the dimension design, not a defect in this report.
-- ===================================================================

CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
TTITLE OFF
BTITLE OFF
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 120
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON

ACCEPT start_year NUMBER DEFAULT 2019 PROMPT 'Enter the START year of the analysis (default 2019): '
ACCEPT end_year   NUMBER DEFAULT 2025 PROMPT 'Enter the END year of the analysis   (default 2025): '

SET TERMOUT OFF
COLUMN run_dt NEW_VALUE run_dt NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN yr_range NEW_VALUE yr_range NOPRINT
SELECT TO_CHAR(&start_year) || ' - ' || TO_CHAR(&end_year) AS yr_range FROM dual;
CLEAR COLUMNS
SET TERMOUT ON


-- ###################################################################
-- VIEW 1 - GROSS, DISCOUNT AND NET PER CUSTOMER PER YEAR
-- Product revenue and service revenue are aggregated separately and
-- then FULL OUTER JOINed, so a customer who only ever bought products
-- (or only ever booked services) still gets a row instead of being
-- dropped by an inner join.
-- Grouped on cus_ID, the natural key: customer_dim is SCD2, so one
-- customer can own several customer_key values and grouping on the
-- surrogate would split that customer into two.
-- ###################################################################
CREATE OR REPLACE VIEW customer_annual_value_v AS
SELECT
    COALESCE(p.cus_ID,   s.cus_ID)   AS cus_ID,
    COALESCE(p.cal_year, s.cal_year) AS cal_year,
    NVL(p.prod_net, 0)  + NVL(s.serv_net, 0)  AS net_revenue,
    NVL(p.prod_disc, 0) + NVL(s.serv_disc, 0) AS discount_given,
    NVL(p.prod_net, 0)  + NVL(s.serv_net, 0)
      + NVL(p.prod_disc, 0) + NVL(s.serv_disc, 0) AS gross_revenue,
    NVL(p.prod_net, 0)  AS product_net,
    NVL(s.serv_net, 0)  AS service_net
FROM (
        SELECT c.cus_ID, d.cal_year,
               SUM(o.order_net_amt)      AS prod_net,
               SUM(o.order_discount_amt) AS prod_disc
        FROM   order_fact   o
        JOIN   date_dim     d ON d.date_key     = o.date_key
        JOIN   customer_dim c ON c.customer_key = o.customer_key
        WHERE  o.order_status = 'Completed'
        GROUP  BY c.cus_ID, d.cal_year
     ) p
FULL OUTER JOIN (
        SELECT c.cus_ID, d.cal_year,
               SUM(r.serv_net_amt)      AS serv_net,
               SUM(r.serv_discount_amt) AS serv_disc
        FROM   reservation_fact r
        JOIN   date_dim     d ON d.date_key     = r.date_key
        JOIN   customer_dim c ON c.customer_key = r.customer_key
        WHERE  r.res_status = 'Completed'
        GROUP  BY c.cus_ID, d.cal_year
     ) s ON s.cus_ID = p.cus_ID AND s.cal_year = p.cal_year;


-- ###################################################################
-- VIEW 2 - THE AT-RISK FLAG
-- LAG looks at the SAME customer's previous year (PARTITION BY cus_ID),
-- so "at risk" means the customer is spending less than they used to,
-- not less than other people. The default of 0 in LAG means a
-- customer's first-ever year compares against 0 and is never flagged.
-- ###################################################################
CREATE OR REPLACE VIEW customer_annual_trend_v AS
SELECT
    v.cus_ID,
    v.cal_year,
    v.net_revenue,
    v.discount_given,
    v.gross_revenue,
    v.product_net,
    v.service_net,
    LAG(v.net_revenue, 1, 0) OVER (PARTITION BY v.cus_ID ORDER BY v.cal_year) AS prev_year_net,
    CASE WHEN v.net_revenue <
              LAG(v.net_revenue, 1, 0) OVER (PARTITION BY v.cus_ID ORDER BY v.cal_year)
         THEN 1 ELSE 0 END AS is_at_risk
FROM customer_annual_value_v v;


-- ###################################################################
-- VIEW 3 - PLUS THE STORED LOYALTY TIER AND DEMOGRAPHICS
-- is_current_flag = 'Y' picks ONE row per customer from the SCD2
-- dimension, so joining it cannot multiply a customer's revenue by the
-- number of versions they happen to have.
-- ###################################################################
CREATE OR REPLACE VIEW customer_profile_value_v AS
SELECT
    t.cus_ID, t.cal_year,
    t.net_revenue, t.discount_given, t.gross_revenue,
    t.product_net, t.service_net,
    t.prev_year_net, t.is_at_risk,
    c.cus_loyalty_tier,
    c.cus_age_group,
    c.cus_gender,
    c.cus_state
FROM   customer_annual_trend_v t
JOIN   customer_dim c ON c.cus_ID = t.cus_ID
                     AND c.is_current_flag = 'Y';


-- ###################################################################
-- SECTION A - REVENUE BY LOYALTY TIER AND YEAR
-- Does the tier ladder actually correspond to a revenue ladder? And is
-- each tier's share of the business holding up over time?
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - A. REVENUE BY LOYALTY TIER AND YEAR' SKIP 1 -
       CENTER 'STORED cus_loyalty_tier, &yr_range' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cus_loyalty_tier HEADING 'LOYALTY|TIER'     FORMAT A9
COLUMN cal_year         HEADING 'YEAR'             FORMAT 9999
COLUMN customers        HEADING 'ACTIVE|CUSTOMERS' FORMAT 999,990
COLUMN net_revenue      HEADING 'NET REVENUE|(RM)' FORMAT 999,999,990.00
COLUMN rev_per_cust     HEADING 'REV PER|CUSTOMER' FORMAT 99,990.00
COLUMN pct_revenue      HEADING '% OF YEAR|REVENUE' FORMAT 990.0
COLUMN pct_at_risk      HEADING '% AT|RISK'        FORMAT 990.0

BREAK ON cus_loyalty_tier SKIP 1
COMPUTE SUM LABEL 'Tier Total:' OF net_revenue ON cus_loyalty_tier

WITH tier_year AS (
    SELECT cus_loyalty_tier,
           cal_year,
           COUNT(DISTINCT cus_ID) AS customers,
           SUM(net_revenue)       AS net_revenue,
           SUM(is_at_risk)        AS at_risk_count
    FROM   customer_profile_value_v
    WHERE  cal_year BETWEEN &start_year AND &end_year
    GROUP  BY cus_loyalty_tier, cal_year
)
SELECT cus_loyalty_tier,
       cal_year,
       customers,
       ROUND(net_revenue, 2)                                    AS net_revenue,
       ROUND(net_revenue / NULLIF(customers, 0), 2)             AS rev_per_cust,
       ROUND(net_revenue * 100.0
             / SUM(net_revenue) OVER (PARTITION BY cal_year), 1) AS pct_revenue,
       ROUND(at_risk_count * 100.0 / NULLIF(customers, 0), 1)    AS pct_at_risk
FROM   tier_year
ORDER  BY DECODE(cus_loyalty_tier, 'Platinum', 1, 'Gold', 2, 'Silver', 3, 'Bronze', 4),
          cal_year;


-- ###################################################################
-- SECTION B - DISCOUNT COST VS REVENUE RETURN BY TIER
-- The loyalty programme is not free: Silver, Gold and Platinum all get
-- money taken off at the till. This section prices that.
--   NET PER RM DISC  = Net Revenue / Discount Given. Higher is better.
--                      It will FALL as the tier rises - that is the
--                      whole design of a discount ladder. The real
--                      question is whether REV PER CUSTOMER rises
--                      fast enough to pay for the fall.
-- Read the two columns together: if Platinum returns half the revenue
-- per Ringgit of discount that Bronze does, it needs to be bringing in
-- more than twice the revenue per customer to be worth it.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - B. DISCOUNT COST VS REVENUE RETURN' SKIP 1 -
       CENTER 'BY LOYALTY TIER, &yr_range' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cus_loyalty_tier HEADING 'LOYALTY|TIER'       FORMAT A9
COLUMN customers        HEADING 'CUSTOMERS'          FORMAT 999,990
COLUMN gross_revenue    HEADING 'GROSS REVENUE|(RM)' FORMAT 999,999,990.00
COLUMN discount_given   HEADING 'DISCOUNT GIVEN|(RM)' FORMAT 99,999,990.00
COLUMN net_revenue      HEADING 'NET REVENUE|(RM)'   FORMAT 999,999,990.00
COLUMN eff_disc_pct     HEADING 'EFFECTIVE|DISCOUNT %' FORMAT 990.0
COLUMN net_per_disc     HEADING 'NET REV PER|RM DISCOUNT' FORMAT 9,990.00
COLUMN rev_per_cust     HEADING 'REV PER|CUSTOMER'   FORMAT 99,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL TIERS' OF customers gross_revenue discount_given net_revenue ON REPORT

WITH by_tier AS (
    SELECT cus_loyalty_tier,
           COUNT(DISTINCT cus_ID) AS customers,
           SUM(gross_revenue)     AS gross_revenue,
           SUM(discount_given)    AS discount_given,
           SUM(net_revenue)       AS net_revenue
    FROM   customer_profile_value_v
    WHERE  cal_year BETWEEN &start_year AND &end_year
    GROUP  BY cus_loyalty_tier
)
SELECT cus_loyalty_tier,
       customers,
       ROUND(gross_revenue, 2)                                       AS gross_revenue,
       ROUND(discount_given, 2)                                      AS discount_given,
       ROUND(net_revenue, 2)                                         AS net_revenue,
       ROUND(discount_given * 100.0 / NULLIF(gross_revenue, 0), 1)   AS eff_disc_pct,
       ROUND(net_revenue / NULLIF(discount_given, 0), 2)             AS net_per_disc,
       ROUND(net_revenue / NULLIF(customers, 0), 2)                  AS rev_per_cust
FROM   by_tier
ORDER  BY DECODE(cus_loyalty_tier, 'Platinum', 1, 'Gold', 2, 'Silver', 3, 'Bronze', 4);


-- ###################################################################
-- SECTION C - DRILL-DOWN: WHO THEY ARE
-- Pick one year and one loyalty tier, then see which age band and
-- gender those customers fall into - the targeting question.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
PROMPT ==================================================
PROMPT DRILL-DOWN: ONE YEAR, ONE LOYALTY TIER
PROMPT ==================================================
PROMPT

ACCEPT drill_year NUMBER DEFAULT 2025      PROMPT 'Enter the year to drill into (default 2025): '
ACCEPT drill_tier CHAR   DEFAULT 'Platinum' PROMPT 'Enter the loyalty tier (Bronze/Silver/Gold/Platinum, default Platinum): '

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - C. WHO THE &drill_tier CUSTOMERS ARE' SKIP 1 -
       CENTER 'AGE BAND AND GENDER, LOYALTY TIER &drill_tier, YEAR &drill_year' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cus_age_group HEADING 'AGE BAND'         FORMAT A24
COLUMN female_cnt    HEADING 'FEMALE'           FORMAT 999,990
COLUMN male_cnt      HEADING 'MALE'             FORMAT 999,990
COLUMN customers     HEADING 'CUSTOMERS'        FORMAT 999,990
COLUMN net_revenue   HEADING 'NET REVENUE|(RM)' FORMAT 99,999,990.00
COLUMN pct_revenue   HEADING '% OF TIER|REVENUE' FORMAT 990.0
COLUMN rev_per_cust  HEADING 'REV PER|CUSTOMER' FORMAT 99,990.00
COLUMN pct_at_risk   HEADING '% AT|RISK'        FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL AGES' OF female_cnt male_cnt customers net_revenue ON REPORT

WITH by_age AS (
    SELECT cus_age_group,
           COUNT(DISTINCT CASE WHEN cus_gender = 'Female' THEN cus_ID END) AS female_cnt,
           COUNT(DISTINCT CASE WHEN cus_gender = 'Male'   THEN cus_ID END) AS male_cnt,
           COUNT(DISTINCT cus_ID) AS customers,
           SUM(net_revenue)       AS net_revenue,
           SUM(is_at_risk)        AS at_risk_count
    FROM   customer_profile_value_v
    WHERE  cal_year = &drill_year
    AND    UPPER(cus_loyalty_tier) = UPPER(TRIM('&drill_tier'))
    GROUP  BY cus_age_group
)
SELECT cus_age_group,
       female_cnt,
       male_cnt,
       customers,
       ROUND(net_revenue, 2)                                    AS net_revenue,
       ROUND(net_revenue * 100.0 / SUM(net_revenue) OVER (), 1) AS pct_revenue,
       ROUND(net_revenue / NULLIF(customers, 0), 2)             AS rev_per_cust,
       ROUND(at_risk_count * 100.0 / NULLIF(customers, 0), 1)   AS pct_at_risk
FROM   by_age
ORDER  BY cus_age_group;


-- ===================================================================
-- tidy up: drop the views in reverse dependency order, then reset
-- SQL*Plus so the next script starts clean
-- ===================================================================
DROP VIEW customer_profile_value_v;
DROP VIEW customer_annual_trend_v;
DROP VIEW customer_annual_value_v;

PROMPT
PROMPT +==========================================================+
PROMPT |  END OF LOYALTY TIER REVENUE AND DISCOUNT REPORT         |
PROMPT +==========================================================+
PROMPT

TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE start_year
UNDEFINE end_year
UNDEFINE drill_year
UNDEFINE drill_tier
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
