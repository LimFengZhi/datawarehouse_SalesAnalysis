-- ===================================================================
-- 08_product_service_crosssell.sql
-- CUSTOMER ANALYSIS - PRODUCT <-> SERVICE CROSS-SELL: ONE CUSTOMER,
--                     TWO BUSINESSES - DOES THE SHOP FEED THE SALON?
--   Glow Beauty runs a retail counter (product orders) and a salon
--   (service reservations), but every report so far reads them apart.
--   Here every active customer is classified PRODUCT-ONLY /
--   SERVICE-ONLY / DUAL, and the walk is: the company year by year
--   -> ONE YEAR by branch -> ONE BRANCH by loyalty tier -> then the
--   lifetime view: which side a customer starts on, whether he / she
--   ever crosses to the other, through which gateway category, and
--   how fast (the cross-sell curve).
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Fz\08_product_service_crosssell.sql
--
-- PARAMETERS (the year range at the start; the rest ONE AT A TIME,
-- each after the table it refers to has printed)
--   start year, end year   at the start   defaults 2018 and 2025
--   focus year   after section 1          default 2025
--   branch       after section 2          default Petaling Jaya
--   A year / name that matches nothing falls back to the biggest
--   member of that level (most active customers / biggest branch).
--   The spool is paused around every prompt, so the output file holds
--   only tables. Sections 4-6 are lifetime views over ALL years - the
--   range and the prompts do not restrict them.
--
-- WHAT IT ANSWERS
--   1. How much of the customer base uses BOTH sides of the business,
--      is that share growing, and what is a dual customer worth
--      against a single-side one?
--   2. Which branches and which loyalty tiers convert shoppers into
--      salon clients (and salon clients into shoppers)?
--   3. Which side do customers start on, how many ever cross, through
--      which first product / first service, and how many months does
--      the crossing take - where should the cross-sell push aim?
--
-- THE CUBE  (a DRILL-ACROSS of the two REVENUE facts on the conformed
--           customer / date / branch dimensions)
--   facts     order_fact        product lines sold  (Completed only)
--             reservation_fact  service visits kept (Completed only)
--   dims      customer_dim (cus_ID, loyalty tier), date_dim (cal_year,
--             cal_date), branch_dim (br_ID / br_city / br_state),
--             product_dim.product_category and service_dim.serv_category
--             for the gateway section
--   measures  Product net (RM) = order_total_amt - order_tax_amt
--             Service net (RM) = serv_total_amt - serv_tax_amt
--             PRODUCT-ONLY / SERVICE-ONLY / DUAL = did the customer,
--                within the scope of the row (a year, a branch-year),
--                buy products only, book services only, or both
--             DUAL MULTIPLE = net RM per dual customer / net RM per
--                single-side customer (both sides pooled)
--             DUAL REVENUE SHARE % = the scope's net revenue held by
--                its dual customers
--             FIRST SIDE (lifetime) = the side of the customer's first
--                completed activity; EVER CROSSED = has the other side
--                at any later (or same) date; MONTHS TO CROSS =
--                calendar months from first activity to the first
--                activity on the other side
--             HORIZON = the last calendar month with any activity
--
-- READ THIS BEFORE QUOTING A CROSS-SELL RATE
--   - The two facts are INDEPENDENT visits, not one basket: DUAL means
--     "used both sides within the scope", not "bought both on one
--     receipt". Widen or narrow the scope and the share moves - a
--     year's dual share is higher than any single month's.
--   - RIGHT-CENSORING: "CROSSED <= 12M %" is computed only on the
--     customers whose 12th month lies inside the data horizon, so late
--     cohorts do not drag the rate down. "EVER CROSSED %" carries no
--     such guard - a 2025 starter has had little time - so compare
--     EVER CROSSED only between groups of similar vintage, and trust
--     the censored column for trends.
--   - Services were ZERO in the lockdown windows (salons closed under
--     MCO while the shop kept selling), so 2020-21 dual and
--     service-only shares collapse mechanically. That is the pandemic,
--     not a cross-sell failure.
--   - Section 2 classifies a customer AT EACH BRANCH he / she visited
--     in the year (a customer active at two branches counts at both),
--     so the branch rows answer the branch manager's question - "of MY
--     customers, who uses both MY counters" - and do not sum to the
--     company row of section 1.
--
-- WHY GROUP BY cus_ID / br_ID / CATEGORY AND NOT THE SURROGATE KEYS
--   customer_dim, branch_dim, product_dim and service_dim are SCD
--   Type 2; the natural keys and the category names roll the versions
--   together. The tier used in section 3 is the customer's latest tier
--   within the branch-year scope.
--
-- REPORT SECTIONS  (each one is ONE OLAP operation)
--   1  BY YEAR             ROLL-UP    active customers split product-
--                                     only / service-only / dual, net
--                                     RM per customer of each group,
--                                     dual multiple, dual revenue share
--         -> prompt: focus year
--   2  THE YEAR BY BRANCH  DRILL-DOWN the same split per branch, ranked
--                                     by dual share
--         -> prompt: branch
--   3  BY LOYALTY TIER     DICE       branch x year x tier - who is
--                                     dual, and what each tier's dual
--                                     customer is worth
--   4  DIRECTION OF        DRILL-     lifetime: first side product vs
--      CROSSING            ACROSS     service, % ever crossed, %
--                                     crossed within 12 months, months
--                                     to cross, RM per customer on
--                                     each side
--   5  GATEWAY CATEGORY    DICE       first product category (product-
--                                     first customers) and first
--                                     service category (service-first),
--                                     ranked by the censored 12-month
--                                     crossing rate
--   6  CROSS-SELL CURVE    DRILL-DOWN cumulative % crossed by month +k
--                                     since the first activity (up to
--                                     36), product-first vs service-
--                                     first side by side
--
-- WHAT TO LOOK FOR  (defaults 2018-2025 > 2025 > Petaling Jaya,
--   revision-3 data; the shapes below follow from how the data was
--   generated - check the exact figures on your own run)
--   - Section 1: services run ~0.4 visits per product order, so
--     PRODUCT-ONLY is the biggest group everywhere and SERVICE-ONLY
--     the smallest; the dual share collapses in 2020-21 (salons shut
--     for months while the shop sold on) and recovers from 2022. The
--     DUAL MULTIPLE should sit well above 2x: the same heavy shoppers
--     are drawn to both sides, so dual customers concentrate the
--     spend - expect their revenue share to be far above their head-
--     count share.
--   - Section 2: dual share tracks branch size and lockdown exposure -
--     the Klang Valley branches lost the most salon weeks in 2020-21;
--     in a normal year the branches sit within a few points of each
--     other. Ipoh (opened 2023) has no pandemic scar in its history.
--   - Section 3: the tier ladder again - Platinum / Gold customers are
--     2-3x as active as Bronze on BOTH sides, so the dual share climbs
--     steeply with the tier; Bronze is the headcount, Platinum the
--     dual value. If the DUAL MULTIPLE stays high even within a tier,
--     the multiple is not only an activity artefact.
--   - Section 4: with ~2.4 orders for every visit, most customers meet
--     the shop first - expect PRODUCT FIRST to dominate the headcount.
--     Service-first customers are fewer but should cross at a HIGHER
--     rate (whoever books a facial is already in the chair next to the
--     shelf). BOTH SAME DAY is small.
--   - Section 5: gateway differences are expected to be mild (the
--     generator draws products and services independently), so read
--     the ranking as "which first basket marks a customer who will use
--     both sides" - bigger first baskets and service-side categories
--     with add-ons should edge ahead. A flat table is itself the
--     finding: any first purchase is as good an invitation as another.
--   - Section 6: the curve is the budget chart - if most crossing that
--     will ever happen has happened by M+6..M+12, the cross-sell
--     voucher belongs in the FIRST months of the relationship; the gap
--     between the product-first and service-first curves says which
--     direction needs the push.
-- ===================================================================

-- reset anything a previous script left behind in this session
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 180
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

-- SQL*Plus caps an ACCEPT prompt at 99 characters - keep it short.
ACCEPT p_from NUMBER DEFAULT 2018 PROMPT 'Start year (default 2018): '
ACCEPT p_to   NUMBER DEFAULT 2025 PROMPT 'End year   (default 2025): '

-- ---- values reused in every title ---------------------------------
-- TERMOUT OFF hides these helper queries (only works when the file is
-- run with @, which is how this report is meant to be run).
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

-- clamp the range to the data (2018-2025) and put it the right way round
COLUMN f_from NEW_VALUE f_from NOPRINT
COLUMN f_to   NEW_VALUE f_to   NOPRINT
SELECT TO_CHAR(GREATEST(2018, LEAST(&p_from, &p_to)))  AS f_from,
       TO_CHAR(LEAST(2025, GREATEST(&p_from, &p_to)))  AS f_to
FROM   dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL product_service_crosssell_output.txt


-- ###################################################################
-- SECTION 1 - PRODUCT-ONLY / SERVICE-ONLY / DUAL, BY YEAR
-- OLAP: ROLL-UP of the two facts to customer x year, whole company.
-- One row per year of the range: the active base split three ways,
-- what each group is worth per head, the dual multiple and the share
-- of the year's revenue held by the dual customers.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. PRODUCT / SERVICE / DUAL CUSTOMERS BY YEAR' SKIP 1 -
       CENTER 'ALL BRANCHES, &f_from - &f_to  (ROLL-UP: DRILL-ACROSS OF THE TWO REVENUE FACTS)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year   HEADING 'YEAR'                 FORMAT 9999
COLUMN active     HEADING 'ACTIVE|CUSTOMERS'     FORMAT 99,990
COLUMN p_pct      HEADING 'PRODUCT|ONLY %'       FORMAT 990.0
COLUMN s_pct      HEADING 'SERVICE|ONLY %'       FORMAT 990.0
COLUMN d_pct      HEADING 'DUAL|%'               FORMAT 990.0
COLUMN p_rm       HEADING 'RM/CUST|PROD ONLY'    FORMAT 99,990
COLUMN s_rm       HEADING 'RM/CUST|SERV ONLY'    FORMAT 99,990
COLUMN d_rm       HEADING 'RM/CUST|DUAL'         FORMAT 99,990
COLUMN d_serv_pct HEADING 'SERVICE %|OF DUAL RM' FORMAT 990.0
COLUMN d_mult     HEADING 'DUAL|MULT'            FORMAT 90.00
COLUMN d_share    HEADING 'DUAL REV|SHARE %'     FORMAT 990.0
COLUMN net        HEADING 'NET|SALES (RM)'       FORMAT 99,999,990

BREAK ON REPORT

WITH act AS (
    -- customer x year x side, net without tax (Completed only)
    SELECT c.cus_ID, d.cal_year, 'P' AS side,
           SUM(f.order_total_amt - f.order_tax_amt) AS net
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY c.cus_ID, d.cal_year
    UNION ALL
    SELECT c.cus_ID, d.cal_year, 'S',
           SUM(f.serv_total_amt - f.serv_tax_amt)
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY c.cus_ID, d.cal_year
),
cy AS (
    -- ONE ROW PER CUSTOMER-YEAR: which sides were used, worth how much
    SELECT cus_ID, cal_year,
           MAX(CASE WHEN side = 'P' THEN 1 ELSE 0 END)   AS has_p,
           MAX(CASE WHEN side = 'S' THEN 1 ELSE 0 END)   AS has_s,
           SUM(CASE WHEN side = 'P' THEN net ELSE 0 END) AS net_p,
           SUM(CASE WHEN side = 'S' THEN net ELSE 0 END) AS net_s
    FROM   act
    GROUP  BY cus_ID, cal_year
)
SELECT cal_year,
       COUNT(*)                                                        AS active,
       ROUND(SUM(has_p * (1 - has_s)) / COUNT(*) * 100, 1)             AS p_pct,
       ROUND(SUM(has_s * (1 - has_p)) / COUNT(*) * 100, 1)             AS s_pct,
       ROUND(SUM(has_p * has_s)       / COUNT(*) * 100, 1)             AS d_pct,
       ROUND(SUM(CASE WHEN has_p = 1 AND has_s = 0 THEN net_p END)
             / NULLIF(SUM(has_p * (1 - has_s)), 0), 0)                 AS p_rm,
       ROUND(SUM(CASE WHEN has_s = 1 AND has_p = 0 THEN net_s END)
             / NULLIF(SUM(has_s * (1 - has_p)), 0), 0)                 AS s_rm,
       ROUND(SUM(CASE WHEN has_p = 1 AND has_s = 1 THEN net_p + net_s END)
             / NULLIF(SUM(has_p * has_s), 0), 0)                       AS d_rm,
       ROUND(SUM(CASE WHEN has_p = 1 AND has_s = 1 THEN net_s END)
             / NULLIF(SUM(CASE WHEN has_p = 1 AND has_s = 1 THEN net_p + net_s END), 0) * 100, 1) AS d_serv_pct,
       ROUND((SUM(CASE WHEN has_p = 1 AND has_s = 1 THEN net_p + net_s END)
              / NULLIF(SUM(has_p * has_s), 0))
             / NULLIF(SUM(CASE WHEN has_p + has_s = 1 THEN net_p + net_s END)
                      / NULLIF(SUM(CASE WHEN has_p + has_s = 1 THEN 1 END), 0), 0), 2) AS d_mult,
       ROUND(SUM(CASE WHEN has_p = 1 AND has_s = 1 THEN net_p + net_s END)
             / NULLIF(SUM(net_p + net_s), 0) * 100, 1)                 AS d_share,
       SUM(net_p + net_s)                                              AS net
FROM   cy
GROUP  BY cal_year
ORDER  BY cal_year;

-- ---- prompt 1: which year? (spool paused, helper hidden) -----------
SPOOL OFF
ACCEPT p_year NUMBER DEFAULT 2025 PROMPT 'Year to open up (default 2025): '
SET TERMOUT OFF
-- resolve to a year inside the range: exact match first, else the year
-- with the most active customers
COLUMN f_year NEW_VALUE f_year NOPRINT
SELECT TO_CHAR(MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY miss, n DESC)) AS f_year
FROM (
    SELECT d.cal_year, COUNT(DISTINCT f.customer_key) AS n,
           CASE WHEN d.cal_year = &p_year THEN 0 ELSE 1 END AS miss
    FROM   order_fact f
    JOIN   date_dim   d ON d.date_key = f.date_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY d.cal_year
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL product_service_crosssell_output.txt APPEND



-- ###################################################################
-- SECTION 2 - THE FOCUS YEAR BY BRANCH
-- OLAP: DRILL-DOWN year -> branch. A customer is classified AT EACH
-- BRANCH he / she visited in the year (so the rows answer the branch
-- manager's question and do not sum to section 1's company row).
-- Ranked by dual share.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. &f_year: PRODUCT / SERVICE / DUAL BY BRANCH' SKIP 1 -
       CENTER 'A CUSTOMER IS CLASSIFIED AT EACH BRANCH VISITED  (DRILL-DOWN YEAR -> BRANCH, RANKED BY DUAL %)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city    HEADING 'BRANCH'               FORMAT A15
COLUMN br_state   HEADING 'STATE'                FORMAT A19
COLUMN active     HEADING 'ACTIVE|CUSTOMERS'     FORMAT 99,990
COLUMN p_pct      HEADING 'PRODUCT|ONLY %'       FORMAT 990.0
COLUMN s_pct      HEADING 'SERVICE|ONLY %'       FORMAT 990.0
COLUMN d_pct      HEADING 'DUAL|%'               FORMAT 990.0
COLUMN single_rm  HEADING 'RM/CUST|SINGLE'       FORMAT 99,990
COLUMN d_rm       HEADING 'RM/CUST|DUAL'         FORMAT 99,990
COLUMN d_mult     HEADING 'DUAL|MULT'            FORMAT 90.00
COLUMN d_share    HEADING 'DUAL REV|SHARE %'     FORMAT 990.0
COLUMN net        HEADING 'NET|SALES (RM)'       FORMAT 9,999,990
COLUMN br_ID      NOPRINT

BREAK ON REPORT

WITH act AS (
    -- customer x branch x side within the focus year
    SELECT c.cus_ID, b.br_ID, b.br_city, b.br_state, 'P' AS side,
           SUM(f.order_total_amt - f.order_tax_amt) AS net
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year = &f_year
    GROUP  BY c.cus_ID, b.br_ID, b.br_city, b.br_state
    UNION ALL
    SELECT c.cus_ID, b.br_ID, b.br_city, b.br_state, 'S',
           SUM(f.serv_total_amt - f.serv_tax_amt)
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &f_year
    GROUP  BY c.cus_ID, b.br_ID, b.br_city, b.br_state
),
cb AS (
    -- ONE ROW PER CUSTOMER-BRANCH: which of THIS branch's counters
    SELECT cus_ID, br_ID, MIN(br_city) AS br_city, MIN(br_state) AS br_state,
           MAX(CASE WHEN side = 'P' THEN 1 ELSE 0 END)   AS has_p,
           MAX(CASE WHEN side = 'S' THEN 1 ELSE 0 END)   AS has_s,
           SUM(net)                                      AS net
    FROM   act
    GROUP  BY cus_ID, br_ID
)
SELECT br_city, br_state,
       COUNT(*)                                                        AS active,
       ROUND(SUM(has_p * (1 - has_s)) / COUNT(*) * 100, 1)             AS p_pct,
       ROUND(SUM(has_s * (1 - has_p)) / COUNT(*) * 100, 1)             AS s_pct,
       ROUND(SUM(has_p * has_s)       / COUNT(*) * 100, 1)             AS d_pct,
       ROUND(SUM(CASE WHEN has_p + has_s = 1 THEN net END)
             / NULLIF(SUM(CASE WHEN has_p + has_s = 1 THEN 1 END), 0), 0) AS single_rm,
       ROUND(SUM(CASE WHEN has_p = 1 AND has_s = 1 THEN net END)
             / NULLIF(SUM(has_p * has_s), 0), 0)                       AS d_rm,
       ROUND((SUM(CASE WHEN has_p = 1 AND has_s = 1 THEN net END)
              / NULLIF(SUM(has_p * has_s), 0))
             / NULLIF(SUM(CASE WHEN has_p + has_s = 1 THEN net END)
                      / NULLIF(SUM(CASE WHEN has_p + has_s = 1 THEN 1 END), 0), 0), 2) AS d_mult,
       ROUND(SUM(CASE WHEN has_p = 1 AND has_s = 1 THEN net END)
             / NULLIF(SUM(net), 0) * 100, 1)                           AS d_share,
       SUM(net)                                                        AS net,
       br_ID
FROM   cb
GROUP  BY br_ID, br_city, br_state
ORDER  BY d_pct DESC, net DESC;

-- ---- prompt 2: which branch? ---------------------------------------
SPOOL OFF
ACCEPT p_branch CHAR DEFAULT 'Petaling Jaya' PROMPT 'Branch to open up (default Petaling Jaya): '
SET TERMOUT OFF
-- resolve to a real branch: name match first, else the biggest by sales
COLUMN f_br_id   NEW_VALUE f_br_id   NOPRINT
COLUMN f_branch  NEW_VALUE f_branch  NOPRINT
SELECT TO_CHAR(MAX(br_ID) KEEP (DENSE_RANK FIRST ORDER BY miss, amt DESC)) AS f_br_id,
       MAX(br_city)       KEEP (DENSE_RANK FIRST ORDER BY miss, amt DESC)  AS f_branch
FROM (
    SELECT br_ID, br_city, amt,
           CASE WHEN UPPER(br_city) LIKE '%' || UPPER(TRIM('&p_branch')) || '%' THEN 0 ELSE 1 END AS miss
    FROM  (SELECT b.br_ID, b.br_city,
                  SUM(f.order_total_amt - f.order_tax_amt) AS amt
           FROM   order_fact f
           JOIN   branch_dim b ON b.branch_key = f.branch_key
           WHERE  f.order_status = 'Completed'
           GROUP  BY b.br_ID, b.br_city)
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL product_service_crosssell_output.txt APPEND



-- ###################################################################
-- SECTION 3 - THE BRANCH-YEAR BY LOYALTY TIER
-- OLAP: DICE branch x year x tier. The tier is the one on the
-- customer_dim versions the branch-year's activity resolved to (tiers
-- are stable in this data). Pooled ALL TIERS row via ROLLUP.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. &f_branch &f_year: DUAL CUSTOMERS BY LOYALTY TIER' SKIP 1 -
       CENTER 'DICE BRANCH x YEAR x TIER - WHO USES BOTH SIDES, AND WHAT THEY ARE WORTH' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN tier       HEADING 'TIER'                 FORMAT A10
COLUMN active     HEADING 'ACTIVE|CUSTOMERS'     FORMAT 99,990
COLUMN share_pct  HEADING 'SHARE OF|BASE %'      FORMAT 990.0
COLUMN p_pct      HEADING 'PRODUCT|ONLY %'       FORMAT 990.0
COLUMN s_pct      HEADING 'SERVICE|ONLY %'       FORMAT 990.0
COLUMN d_pct      HEADING 'DUAL|%'               FORMAT 990.0
COLUMN single_rm  HEADING 'RM/CUST|SINGLE'       FORMAT 99,990
COLUMN d_rm       HEADING 'RM/CUST|DUAL'         FORMAT 99,990
COLUMN d_mult     HEADING 'DUAL|MULT'            FORMAT 90.00
COLUMN d_share    HEADING 'DUAL REV|SHARE %'     FORMAT 990.0
COLUMN net        HEADING 'NET|SALES (RM)'       FORMAT 9,999,990

BREAK ON REPORT

WITH act AS (
    -- the branch-year's activity: customer x side, with the tier of
    -- the customer_dim version on each activity date
    SELECT c.cus_ID, 'P' AS side, MAX(c.cus_loyalty_tier) AS tier,
           SUM(f.order_total_amt - f.order_tax_amt) AS net
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year = &f_year
    AND    b.br_ID = &f_br_id
    GROUP  BY c.cus_ID
    UNION ALL
    SELECT c.cus_ID, 'S', MAX(c.cus_loyalty_tier),
           SUM(f.serv_total_amt - f.serv_tax_amt)
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &f_year
    AND    b.br_ID = &f_br_id
    GROUP  BY c.cus_ID
),
cu AS (
    -- ONE ROW PER CUSTOMER of the branch-year
    SELECT cus_ID, MAX(tier) AS tier,
           MAX(CASE WHEN side = 'P' THEN 1 ELSE 0 END)   AS has_p,
           MAX(CASE WHEN side = 'S' THEN 1 ELSE 0 END)   AS has_s,
           SUM(net)                                      AS net
    FROM   act
    GROUP  BY cus_ID
)
SELECT CASE WHEN GROUPING(cu.tier) = 1 THEN 'ALL TIERS' ELSE cu.tier END AS tier,
       COUNT(*)                                                        AS active,
       ROUND(COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (PARTITION BY GROUPING(cu.tier)), 0) * 100, 1) AS share_pct,
       ROUND(SUM(has_p * (1 - has_s)) / COUNT(*) * 100, 1)             AS p_pct,
       ROUND(SUM(has_s * (1 - has_p)) / COUNT(*) * 100, 1)             AS s_pct,
       ROUND(SUM(has_p * has_s)       / COUNT(*) * 100, 1)             AS d_pct,
       ROUND(SUM(CASE WHEN has_p + has_s = 1 THEN net END)
             / NULLIF(SUM(CASE WHEN has_p + has_s = 1 THEN 1 END), 0), 0) AS single_rm,
       ROUND(SUM(CASE WHEN has_p = 1 AND has_s = 1 THEN net END)
             / NULLIF(SUM(has_p * has_s), 0), 0)                       AS d_rm,
       ROUND((SUM(CASE WHEN has_p = 1 AND has_s = 1 THEN net END)
              / NULLIF(SUM(has_p * has_s), 0))
             / NULLIF(SUM(CASE WHEN has_p + has_s = 1 THEN net END)
                      / NULLIF(SUM(CASE WHEN has_p + has_s = 1 THEN 1 END), 0), 0), 2) AS d_mult,
       ROUND(SUM(CASE WHEN has_p = 1 AND has_s = 1 THEN net END)
             / NULLIF(SUM(net), 0) * 100, 1)                           AS d_share,
       SUM(net)                                                        AS net
FROM   cu
GROUP  BY ROLLUP(cu.tier)
ORDER  BY GROUPING(cu.tier), DECODE(cu.tier, 'Bronze', 1, 'Silver', 2, 'Gold', 3, 'Platinum', 4, 5);



-- ###################################################################
-- SECTION 4 - DIRECTION OF CROSSING  (LIFETIME, ALL YEARS)
-- OLAP: DRILL-ACROSS at the customer's lifetime grain - which side
-- came first, who ever crossed to the other, how fast, and what each
-- side of the relationship is worth. CROSSED <= 12M % is computed only
-- on customers whose 12th month lies inside the data horizon.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. WHICH SIDE FIRST, AND WHO CROSSES?  (LIFETIME, ALL BRANCHES, ALL YEARS)' SKIP 1 -
       CENTER 'DRILL-ACROSS: FIRST COMPLETED ACTIVITY -> EVER USED THE OTHER SIDE' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN grp        HEADING 'FIRST SIDE'            FORMAT A14
COLUMN customers  HEADING 'CUSTOMERS'             FORMAT 99,990
COLUMN cust_pct   HEADING 'CUST|%'                FORMAT 990.0
COLUMN ever_pct   HEADING 'EVER|CROSSED %'        FORMAT 990.0
COLUMN x12_pct    HEADING 'CROSSED|<=12M %'       FORMAT 990.0
COLUMN mtc        HEADING 'AVG MTHS|TO CROSS'     FORMAT 990.0
COLUMN first_rm   HEADING 'RM/CUST|FIRST SIDE'    FORMAT 99,990
COLUMN other_rm   HEADING 'RM/CUST|OTHER SIDE'    FORMAT 99,990
COLUMN life_rm    HEADING 'LIFETIME|RM/CUST'      FORMAT 99,990
COLUMN sort_key   NOPRINT

BREAK ON REPORT

WITH act AS (
    -- customer x day x side over the whole history
    SELECT c.cus_ID, d.cal_date, 'P' AS side,
           SUM(f.order_total_amt - f.order_tax_amt) AS net
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY c.cus_ID, d.cal_date
    UNION ALL
    SELECT c.cus_ID, d.cal_date, 'S',
           SUM(f.serv_total_amt - f.serv_tax_amt)
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
    GROUP  BY c.cus_ID, d.cal_date
),
hz AS (SELECT TRUNC(MAX(cal_date), 'MM') AS horizon FROM act),
cu AS (
    -- ONE ROW PER CUSTOMER: first date on each side, net on each side
    SELECT cus_ID,
           MIN(CASE WHEN side = 'P' THEN cal_date END)   AS fp,
           MIN(CASE WHEN side = 'S' THEN cal_date END)   AS fs,
           SUM(CASE WHEN side = 'P' THEN net ELSE 0 END) AS net_p,
           SUM(CASE WHEN side = 'S' THEN net ELSE 0 END) AS net_s
    FROM   act
    GROUP  BY cus_ID
),
cx AS (
    SELECT c.*,
           CASE WHEN c.fs IS NULL OR c.fp < c.fs THEN 'PRODUCT FIRST'
                WHEN c.fp IS NULL OR c.fs < c.fp THEN 'SERVICE FIRST'
                ELSE 'BOTH SAME DAY' END                              AS grp,
           CASE WHEN c.fp IS NOT NULL AND c.fs IS NOT NULL THEN 1 ELSE 0 END AS crossed,
           MONTHS_BETWEEN(TRUNC(GREATEST(NVL(c.fp, c.fs), NVL(c.fs, c.fp)), 'MM'),
                          TRUNC(LEAST(NVL(c.fp, c.fs), NVL(c.fs, c.fp)), 'MM')) AS ck,
           CASE WHEN ADD_MONTHS(TRUNC(LEAST(NVL(c.fp, c.fs), NVL(c.fs, c.fp)), 'MM'), 12)
                     <= h.horizon THEN 1 END                          AS s12,
           CASE WHEN c.fs IS NULL OR c.fp < c.fs THEN c.net_p
                WHEN c.fp IS NULL OR c.fs < c.fp THEN c.net_s
                ELSE c.net_p + c.net_s END                            AS first_net,
           CASE WHEN c.fs IS NULL OR c.fp < c.fs THEN c.net_s
                WHEN c.fp IS NULL OR c.fs < c.fp THEN c.net_p
                ELSE 0 END                                            AS other_net
    FROM   cu c CROSS JOIN hz h
),
rows_ AS (
    SELECT grp, DECODE(grp, 'PRODUCT FIRST', 1, 'SERVICE FIRST', 2, 3) AS sort_key,
           COUNT(*) AS customers, SUM(crossed) AS crossed,
           SUM(s12) AS obs12,
           SUM(CASE WHEN crossed = 1 AND ck <= 12 THEN s12 END)        AS x12,
           SUM(CASE WHEN crossed = 1 THEN ck END)                      AS ck_sum,
           SUM(first_net) AS first_net, SUM(other_net) AS other_net,
           SUM(net_p + net_s) AS life_net
    FROM   cx GROUP BY grp
    UNION ALL
    SELECT 'ALL CUSTOMERS', 9, COUNT(*), SUM(crossed), SUM(s12),
           SUM(CASE WHEN crossed = 1 AND ck <= 12 THEN s12 END),
           SUM(CASE WHEN crossed = 1 THEN ck END),
           SUM(first_net), SUM(other_net), SUM(net_p + net_s)
    FROM   cx
)
SELECT grp, customers,
       ROUND(customers / NULLIF(SUM(CASE WHEN sort_key < 9 THEN customers END) OVER (), 0) * 100, 1) AS cust_pct,
       ROUND(crossed / NULLIF(customers, 0) * 100, 1)                  AS ever_pct,
       ROUND(x12 / NULLIF(obs12, 0) * 100, 1)                          AS x12_pct,
       ROUND(ck_sum / NULLIF(crossed, 0), 1)                           AS mtc,
       ROUND(first_net / NULLIF(customers, 0), 0)                      AS first_rm,
       ROUND(other_net / NULLIF(customers, 0), 0)                      AS other_rm,
       ROUND(life_net / NULLIF(customers, 0), 0)                       AS life_rm,
       sort_key
FROM   rows_
ORDER  BY sort_key;



-- ###################################################################
-- SECTION 5 - THE GATEWAY CATEGORY  (LIFETIME, ALL YEARS)
-- OLAP: DICE first side x first category. Product-first customers are
-- cut by the category that led their FIRST order (biggest line by
-- net); service-first customers by the category of their FIRST visit's
-- biggest service line. Ranked inside each side by the censored
-- 12-month crossing rate. BOTH-SAME-DAY customers are left out.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. THE GATEWAY: FIRST CATEGORY vs CROSSING TO THE OTHER SIDE' SKIP 1 -
       CENTER 'DICE FIRST SIDE x FIRST CATEGORY, RANKED BY CROSSED <=12M %  (LIFETIME, ALL BRANCHES)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN side_lbl   HEADING 'FIRST|SIDE'            FORMAT A8
COLUMN cat        HEADING 'FIRST CATEGORY'        FORMAT A15
COLUMN customers  HEADING 'CUSTOMERS'             FORMAT 99,990
COLUMN share_pct  HEADING 'SHARE OF|SIDE %'       FORMAT 990.0
COLUMN first_rm   HEADING 'FIRST|BASKET RM'       FORMAT 9,990.00
COLUMN ever_pct   HEADING 'EVER|CROSSED %'        FORMAT 990.0
COLUMN x12_pct    HEADING 'CROSSED|<=12M %'       FORMAT 990.0
COLUMN mtc        HEADING 'AVG MTHS|TO CROSS'     FORMAT 990.0
COLUMN cross_rm   HEADING 'OTHER-SIDE|RM/CROSSER' FORMAT 99,990
COLUMN side_ord   NOPRINT

BREAK ON side_lbl

WITH po AS (
    -- ONE ROW PER COMPLETED ORDER: date, net, leading category
    SELECT c.cus_ID, f.order_ID,
           MIN(d.cal_date)                          AS cal_date,
           SUM(f.order_total_amt - f.order_tax_amt) AS net,
           MAX(p.product_category)
               KEEP (DENSE_RANK FIRST ORDER BY f.order_total_amt - f.order_tax_amt DESC,
                                              p.product_ID)  AS lead_cat
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   product_dim  p ON p.product_key  = f.product_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY c.cus_ID, f.order_ID
),
sv AS (
    -- ONE ROW PER COMPLETED VISIT: date, net, leading service category
    SELECT c.cus_ID, f.res_ID,
           MIN(d.cal_date)                          AS cal_date,
           SUM(f.serv_total_amt - f.serv_tax_amt)   AS net,
           MAX(s.serv_category)
               KEEP (DENSE_RANK FIRST ORDER BY f.serv_total_amt - f.serv_tax_amt DESC,
                                              s.serv_ID)     AS lead_cat
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   service_dim  s ON s.service_key  = f.service_key
    WHERE  f.res_status = 'Completed'
    GROUP  BY c.cus_ID, f.res_ID
),
cu AS (
    -- ONE ROW PER CUSTOMER: first date and net on each side
    SELECT cus_ID,
           MIN(CASE WHEN side = 'P' THEN cal_date END)   AS fp,
           MIN(CASE WHEN side = 'S' THEN cal_date END)   AS fs,
           SUM(CASE WHEN side = 'P' THEN net ELSE 0 END) AS net_p,
           SUM(CASE WHEN side = 'S' THEN net ELSE 0 END) AS net_s
    FROM  (SELECT cus_ID, cal_date, 'P' AS side, net FROM po
           UNION ALL
           SELECT cus_ID, cal_date, 'S', net FROM sv)
    GROUP  BY cus_ID
),
hz AS (SELECT GREATEST((SELECT TRUNC(MAX(cal_date), 'MM') FROM po),
                       (SELECT TRUNC(MAX(cal_date), 'MM') FROM sv)) AS horizon FROM dual),
pf AS (
    -- product-first customers with the first order's category
    SELECT cus_ID,
           MAX(lead_cat) KEEP (DENSE_RANK FIRST ORDER BY cal_date, order_ID) AS cat,
           MIN(net)      KEEP (DENSE_RANK FIRST ORDER BY cal_date, order_ID) AS first_net
    FROM   po
    GROUP  BY cus_ID
),
sf AS (
    -- service-first customers with the first visit's category
    SELECT cus_ID,
           MAX(lead_cat) KEEP (DENSE_RANK FIRST ORDER BY cal_date, res_ID) AS cat,
           MIN(net)      KEEP (DENSE_RANK FIRST ORDER BY cal_date, res_ID) AS first_net
    FROM   sv
    GROUP  BY cus_ID
),
cx AS (
    -- one row per single-side-first customer: side, gateway, crossing
    SELECT c.cus_ID,
           CASE WHEN c.fs IS NULL OR c.fp < c.fs THEN 'PRODUCT' ELSE 'SERVICE' END AS side_lbl,
           CASE WHEN c.fs IS NULL OR c.fp < c.fs THEN p.cat ELSE s.cat END         AS cat,
           CASE WHEN c.fs IS NULL OR c.fp < c.fs THEN p.first_net ELSE s.first_net END AS first_net,
           CASE WHEN c.fp IS NOT NULL AND c.fs IS NOT NULL THEN 1 ELSE 0 END       AS crossed,
           MONTHS_BETWEEN(TRUNC(GREATEST(NVL(c.fp, c.fs), NVL(c.fs, c.fp)), 'MM'),
                          TRUNC(LEAST(NVL(c.fp, c.fs), NVL(c.fs, c.fp)), 'MM'))    AS ck,
           CASE WHEN ADD_MONTHS(TRUNC(LEAST(NVL(c.fp, c.fs), NVL(c.fs, c.fp)), 'MM'), 12)
                     <= h.horizon THEN 1 END                                       AS s12,
           CASE WHEN c.fs IS NULL OR c.fp < c.fs THEN c.net_s ELSE c.net_p END     AS other_net
    FROM   cu c
    CROSS  JOIN hz h
    LEFT   JOIN pf p ON p.cus_ID = c.cus_ID
    LEFT   JOIN sf s ON s.cus_ID = c.cus_ID
    WHERE  c.fp IS NULL OR c.fs IS NULL OR c.fp <> c.fs
)
SELECT side_lbl, cat,
       COUNT(*)                                                        AS customers,
       ROUND(COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (PARTITION BY side_lbl), 0) * 100, 1) AS share_pct,
       ROUND(AVG(first_net), 2)                                        AS first_rm,
       ROUND(SUM(crossed) / NULLIF(COUNT(*), 0) * 100, 1)              AS ever_pct,
       ROUND(SUM(CASE WHEN crossed = 1 AND ck <= 12 THEN s12 END)
             / NULLIF(SUM(s12), 0) * 100, 1)                           AS x12_pct,
       ROUND(SUM(CASE WHEN crossed = 1 THEN ck END)
             / NULLIF(SUM(crossed), 0), 1)                             AS mtc,
       ROUND(SUM(CASE WHEN crossed = 1 THEN other_net END)
             / NULLIF(SUM(crossed), 0), 0)                             AS cross_rm,
       DECODE(side_lbl, 'PRODUCT', 1, 2)                               AS side_ord
FROM   cx
GROUP  BY side_lbl, cat
ORDER  BY side_ord, x12_pct DESC NULLS LAST, customers DESC;



-- ###################################################################
-- SECTION 6 - THE CROSS-SELL CURVE  (LIFETIME, ALL YEARS)
-- OLAP: DRILL-DOWN to the month grain - the cumulative % of customers
-- who have used the other side by month +k after their first activity
-- (k = 0 counts a same-month crossing), product-first and service-
-- first side by side, up to month +36. Every rate is computed only on
-- the customers whose month k lies inside the data horizon, so the
-- curve is never dragged down by customers won recently; rows with
-- nobody observable are dropped.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 6. THE CROSS-SELL CURVE: % CROSSED BY MONTH +K' SKIP 1 -
       CENTER 'CUMULATIVE, CENSOR-AWARE; PRODUCT-FIRST vs SERVICE-FIRST  (LIFETIME, ALL BRANCHES)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN k          HEADING 'MONTH|+K'              FORMAT 90
COLUMN pf_n       HEADING 'PROD-FIRST|OBSERVABLE' FORMAT 99,990
COLUMN pf_pct     HEADING 'PROD-FIRST|CROSSED %'  FORMAT 990.0
COLUMN sf_n       HEADING 'SERV-FIRST|OBSERVABLE' FORMAT 99,990
COLUMN sf_pct     HEADING 'SERV-FIRST|CROSSED %'  FORMAT 990.0
COLUMN gap_pts    HEADING 'GAP|PTS'               FORMAT 990.0

BREAK ON REPORT

WITH act AS (
    SELECT c.cus_ID, d.cal_date, 'P' AS side
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY c.cus_ID, d.cal_date
    UNION ALL
    SELECT c.cus_ID, d.cal_date, 'S'
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
    GROUP  BY c.cus_ID, d.cal_date
),
hz AS (SELECT TRUNC(MAX(cal_date), 'MM') AS horizon FROM act),
cu AS (
    -- one row per single-side-first customer: side, first month, and
    -- the month offset of the crossing (NULL = never crossed yet)
    SELECT cus_ID,
           CASE WHEN fs IS NULL OR fp < fs THEN 'P' ELSE 'S' END AS side,
           TRUNC(LEAST(NVL(fp, fs), NVL(fs, fp)), 'MM')          AS fm,
           CASE WHEN fp IS NOT NULL AND fs IS NOT NULL THEN
                MONTHS_BETWEEN(TRUNC(GREATEST(fp, fs), 'MM'),
                               TRUNC(LEAST(fp, fs), 'MM')) END   AS ck
    FROM  (SELECT cus_ID,
                  MIN(CASE WHEN side = 'P' THEN cal_date END) AS fp,
                  MIN(CASE WHEN side = 'S' THEN cal_date END) AS fs
           FROM   act
           GROUP  BY cus_ID)
    WHERE  fp IS NULL OR fs IS NULL OR fp <> fs
),
ks AS (SELECT LEVEL - 1 AS k FROM dual CONNECT BY LEVEL <= 37)
SELECT ks.k,
       SUM(CASE WHEN cu.side = 'P' AND ADD_MONTHS(cu.fm, ks.k) <= h.horizon THEN 1 END) AS pf_n,
       ROUND(SUM(CASE WHEN cu.side = 'P' AND ADD_MONTHS(cu.fm, ks.k) <= h.horizon
                       AND cu.ck <= ks.k THEN 1 END)
             / NULLIF(SUM(CASE WHEN cu.side = 'P'
                                AND ADD_MONTHS(cu.fm, ks.k) <= h.horizon THEN 1 END), 0) * 100, 1) AS pf_pct,
       SUM(CASE WHEN cu.side = 'S' AND ADD_MONTHS(cu.fm, ks.k) <= h.horizon THEN 1 END) AS sf_n,
       ROUND(SUM(CASE WHEN cu.side = 'S' AND ADD_MONTHS(cu.fm, ks.k) <= h.horizon
                       AND cu.ck <= ks.k THEN 1 END)
             / NULLIF(SUM(CASE WHEN cu.side = 'S'
                                AND ADD_MONTHS(cu.fm, ks.k) <= h.horizon THEN 1 END), 0) * 100, 1) AS sf_pct,
       ROUND(SUM(CASE WHEN cu.side = 'S' AND ADD_MONTHS(cu.fm, ks.k) <= h.horizon
                       AND cu.ck <= ks.k THEN 1 END)
             / NULLIF(SUM(CASE WHEN cu.side = 'S'
                                AND ADD_MONTHS(cu.fm, ks.k) <= h.horizon THEN 1 END), 0) * 100
           - SUM(CASE WHEN cu.side = 'P' AND ADD_MONTHS(cu.fm, ks.k) <= h.horizon
                       AND cu.ck <= ks.k THEN 1 END)
             / NULLIF(SUM(CASE WHEN cu.side = 'P'
                                AND ADD_MONTHS(cu.fm, ks.k) <= h.horizon THEN 1 END), 0) * 100, 1) AS gap_pts
FROM   ks
CROSS  JOIN hz h
CROSS  JOIN cu
GROUP  BY ks.k
HAVING SUM(CASE WHEN ADD_MONTHS(cu.fm, ks.k) <= h.horizon THEN 1 END) > 0
ORDER  BY ks.k;

PROMPT
PROMPT +==========================================================+
PROMPT |        END OF PRODUCT-SERVICE CROSS-SELL REPORT          |
PROMPT +==========================================================+
PROMPT

-- ===================================================================
-- tidy up so the next script starts clean
-- ===================================================================
SPOOL OFF
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE p_from
UNDEFINE p_to
UNDEFINE p_year
UNDEFINE p_branch
UNDEFINE f_from
UNDEFINE f_to
UNDEFINE f_year
UNDEFINE f_br_id
UNDEFINE f_branch
UNDEFINE run_dt
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
