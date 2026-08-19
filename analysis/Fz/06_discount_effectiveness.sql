-- ===================================================================
-- 06_discount_effectiveness.sql
-- SALES ANALYSIS - IS THE DISCOUNT WORKING?  ONE BRANCH, ONE YEAR,
--                  ITS CUSTOMERS
--   all branches  ->  pick a BRANCH  ->  its years  ->  pick a YEAR
--   ->  the branch-year's customers by loyalty tier  ->  by the
--   discount they actually received  ->  promo days vs ordinary days
--   ->  did the discounted customers come back next year?
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Fz\06_discount_effectiveness.sql
--
-- PARAMETERS (prompted ONE AT A TIME, each after the table it refers
-- to has printed)
--   branch   after section 1   default Petaling Jaya (a name that
--                              matches nothing -> the biggest branch)
--   year     after section 2   default 2025 (a year with no orders ->
--                              the branch's latest year)
--   The spool is paused around both prompts.
--
-- WHAT IT ANSWERS  (for one branch and one year)
--   1. How much of the branch's product business runs on discount, and
--      is a discounted order bigger or smaller than a list-price one?
--   2. Which customer tiers get the discount, and what does each RM of
--      discount bring back in net sales?
--   3. Do customers who received MORE discount buy more often and spend
--      more - the effectiveness curve?
--   4. Do the promo days (3.3, 9.9, 10.10, 11.11, 12.12) lift orders
--      and sales per day, or only give away margin?
--   5. Did the customers who were discounted this year come back next
--      year more than those who paid list?
--
-- THE CUBE
--   fact      order_fact rolled up to ONE ROW PER COMPLETED ORDER
--             (order_ID); services are not orders and are not counted
--   dims      branch_dim (br_ID / br_city / br_state), date_dim
--             (cal_year, cal_date), customer_dim (cus_ID, loyalty tier
--             on the order date)
--   measures  Orders; Discounted orders = SUM(order_discount_amt) > 0
--             (a loyalty tier above Bronze, a mega-sale day 3.3 / 9.9 /
--             10.10 / 11.11 / 12.12, or a random 5 % promo - Bronze
--             customers pay list except on promo days)
--             Net (RM) = order_total_amt - order_tax_amt (paid, no tax)
--             Discount (RM) = order_discount_amt; Discount rate % =
--             discount / (net + discount) x 100
--             Avg order = net / orders (discounted vs at list)
--             Orders per customer, Net RM per customer
--             NET RM PER RM DISCOUNT = net sales / discount given (how
--             many ringgit of paid sales sit behind each ringgit of
--             discount - the crude "return" on the discount)
--             Promo day = a date whose day = its month number, in
--             Mar / Sep / Oct / Nov / Dec (3.3 ... 12.12)
--             Returned next year = the customer placed a completed
--             order or visit ANYWHERE in year + 1
--
-- REPORT SECTIONS  (each one is ONE OLAP operation)
--   1  ALL BRANCHES, ALL YEARS      ROLL-UP    orders, discounted %, discount,
--                                              rate, avg order, customers,
--                                              orders / net per customer, net
--                                              per RM discount
--         -> prompt: branch
--   2  THE BRANCH BY YEAR           DRILL-DOWN same measures, years down
--         -> prompt: year
--   3  THE BRANCH-YEAR BY TIER      DICE       who gets the discount and what
--                                              it brings back
--   4  BY DISCOUNT RECEIVED         DICE       customers banded by the discount
--                                              rate they actually got in the
--                                              year: 0 / <3 / 3-7 / 7-12 / 12+
--                                              % - orders and net per customer
--                                              along the bands
--   5  PROMO DAYS vs OTHER DAYS     DICE       orders and net per trading day,
--                                              avg order, discount rate, lift
--   6  CAME BACK NEXT YEAR?         DRILL-     customers with / without a
--                                   ACROSS     discounted order this year: %
--                                              active in year + 1 (anywhere),
--                                              % that were active in year - 1
--
-- WHAT TO LOOK FOR  (Petaling Jaya > 2024, revision-3 data)
--   - Section 1: every branch runs 63-67 % of its orders on discount at
--     a 4.3-4.8 % rate; the discounted order is a little SMALLER than
--     the list-price order everywhere (RM 263-282 vs 280-296) - the
--     discount rewards loyalty, it does not build baskets; RM 20-22 of
--     net sales sit behind every RM 1 of discount.
--   - Section 2 (PJ): flat 65-68 % / 4.4-4.9 % in every year - the
--     discount is a rule, not a campaign; the base grew 1,309 -> 3,134
--     customers while orders per customer fell 3.3 -> 2.2 (many new,
--     lighter customers).
--   - Section 3 (PJ 2024): the tier ladder - Bronze pays list on 86 %
--     of orders (rate 1.1 %, RM 93 of net per RM of discount), Silver
--     4.0 %, Gold 8.0 %, Platinum 12.9 % (RM 6.8 back per RM given).
--     Up the ladder customers order more often (1.84 -> 3.46 a year)
--     and spend more (RM 527 -> 931), but the discount per customer
--     climbs faster (RM 6 -> 138).
--   - Section 4 (the curve): 36 % of customers received NO discount
--     (1.65 orders, RM 468); 3-7 % band 2.24 orders / RM 621; 7-12 %
--     2.61 / RM 722; 12 %+ 3.06 / RM 823 - spend rises with the
--     discount received, but net per RM of discount falls 26 -> 12 -> 7:
--     the top band costs RM 124 a head to lift spend by RM 355 over
--     the undiscounted customer. The "under 3 %" band (Bronze promo-day
--     shoppers, 4 % of customers) is the heaviest of all - 3.65 orders,
--     RM 1,055 - promo days catch the good customers.
--   - Section 5 (promo days): 5 days, 28.8 orders a day vs 17.4 (LIFT
--     1.66 x), net RM 8,207 a day vs 4,844 (1.69 x), at an 18 % rate:
--     RM 1,801 of discount buys RM 3,363 of extra net sales per promo
--     day - the promo discount is the one that clearly pays.
--   - Section 6: 91.0 % of the discounted customers were active again
--     next year vs 80.7 % of those who paid list, and spent RM 1,322 vs
--     834 - but they were also likelier to have been active the year
--     before (82 % vs 75 %): tier discount goes to customers who were
--     already loyal, so part of the gap is selection, not effect.
--   - Try: Ipoh > 2023 (young base: fewer discounted, promo lift larger)
--     or the default 2025 - year + 1 columns go blank when the data has
--     no next year.
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

-- ---- values reused in every title ---------------------------------
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL discount_effectiveness_output.txt


-- ###################################################################
-- SECTION 1 - ALL BRANCHES, ALL YEARS
-- OLAP: ROLL-UP - one row per branch over 2018-2025: how much of its
-- product business is discounted, what the discount costs, what a
-- discounted vs a list-price order is worth, and per customer.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. DISCOUNT AT EVERY BRANCH, 2018 - 2025' SKIP 1 -
       CENTER 'ONE ROW PER BRANCH (ROLL-UP) - PICK ONE TO OPEN UP' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city    HEADING 'BRANCH'              FORMAT A14
COLUMN br_state   HEADING 'STATE'               FORMAT A19
COLUMN orders     HEADING 'ORDERS'              FORMAT 999,990
COLUMN disc_share HEADING 'DISCOUNTED|ORDERS %'  FORMAT 990.0
COLUMN disc       HEADING 'DISCOUNT|GIVEN (RM)'  FORMAT 9,999,990
COLUMN disc_rate  HEADING 'DISCOUNT|RATE %'      FORMAT 90.00
COLUMN avg_disc   HEADING 'AVG ORDER|DISCOUNTED' FORMAT 9,990.00
COLUMN avg_full   HEADING 'AVG ORDER|AT LIST'    FORMAT 9,990.00
COLUMN customers  HEADING 'CUSTOMERS'            FORMAT 99,990
COLUMN ord_cust   HEADING 'ORDERS PER|CUSTOMER'  FORMAT 90.00
COLUMN net_cust   HEADING 'NET RM|PER CUST'      FORMAT 9,990.00
COLUMN net_per_disc HEADING 'NET RM PER|RM DISCOUNT' FORMAT 9,990.0
COLUMN br_ID      NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF orders disc ON REPORT

WITH orders AS (
    -- ONE ROW PER COMPLETED ORDER: branch, year, date, customer and the
    -- customer's tier on the order date, whether ANY line was
    -- discounted, what was paid (net, no tax) and the discount given
    SELECT f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date,
           MAX(c.cus_ID)              AS cus_ID,
           MAX(c.cus_loyalty_tier)    AS tier,
           CASE WHEN SUM(f.order_discount_amt) > 0 THEN 1 ELSE 0 END AS discounted,
           CASE WHEN EXTRACT(MONTH FROM d.cal_date) = EXTRACT(DAY FROM d.cal_date)
                 AND EXTRACT(MONTH FROM d.cal_date) IN (3, 9, 10, 11, 12) THEN 1 ELSE 0 END AS promo_day,
           SUM(f.order_total_amt - f.order_tax_amt) AS net,
           SUM(f.order_discount_amt)                AS disc
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date
)
SELECT br_city, br_state,
       COUNT(*)                                                       AS orders,
       ROUND(SUM(discounted) / COUNT(*) * 100, 1)                     AS disc_share,
       SUM(disc)                                                      AS disc,
       ROUND(SUM(disc) / NULLIF(SUM(net) + SUM(disc), 0) * 100, 2)    AS disc_rate,
       ROUND(SUM(CASE WHEN discounted = 1 THEN net END) / NULLIF(SUM(discounted), 0), 2)            AS avg_disc,
       ROUND(SUM(CASE WHEN discounted = 0 THEN net END) / NULLIF(COUNT(*) - SUM(discounted), 0), 2) AS avg_full,
       COUNT(DISTINCT cus_ID)                                         AS customers,
       ROUND(COUNT(*) / COUNT(DISTINCT cus_ID), 2)                    AS ord_cust,
       ROUND(SUM(net) / COUNT(DISTINCT cus_ID), 2)                    AS net_cust,
       ROUND(SUM(net) / NULLIF(SUM(disc), 0), 1)                      AS net_per_disc,
       br_ID
FROM   orders
GROUP  BY br_ID, br_city, br_state
ORDER  BY orders DESC;

-- ---- prompt 1: which branch? -----------------------------------------
SPOOL OFF
ACCEPT p_branch CHAR DEFAULT 'Petaling Jaya' PROMPT 'Branch to open up (default Petaling Jaya): '
SET TERMOUT OFF
COLUMN f_br_id   NEW_VALUE f_br_id   NOPRINT
COLUMN f_branch  NEW_VALUE f_branch  NOPRINT
SELECT TO_CHAR(MAX(br_ID) KEEP (DENSE_RANK FIRST ORDER BY miss, n DESC)) AS f_br_id,
       MAX(br_city)       KEEP (DENSE_RANK FIRST ORDER BY miss, n DESC)  AS f_branch
FROM (
    SELECT b.br_ID, b.br_city, COUNT(DISTINCT f.order_ID) AS n,
           CASE WHEN UPPER(b.br_city) LIKE '%' || UPPER(TRIM('&p_branch')) || '%' THEN 0 ELSE 1 END AS miss
    FROM   order_fact f JOIN branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY b.br_ID, b.br_city
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL discount_effectiveness_output.txt APPEND


-- ###################################################################
-- SECTION 2 - THE BRANCH BY YEAR
-- OLAP: DRILL-DOWN branch -> year, the same measures, years down.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. DISCOUNT AT &f_branch BY YEAR' SKIP 1 -
       CENTER 'DRILL-DOWN BRANCH -> YEAR - PICK ONE YEAR TO OPEN UP' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year   HEADING 'YEAR'                FORMAT 9999
COLUMN orders     HEADING 'ORDERS'              FORMAT 999,990
COLUMN disc_share HEADING 'DISCOUNTED|ORDERS %'  FORMAT 990.0
COLUMN disc       HEADING 'DISCOUNT|GIVEN (RM)'  FORMAT 9,999,990
COLUMN disc_rate  HEADING 'DISCOUNT|RATE %'      FORMAT 90.00
COLUMN avg_disc   HEADING 'AVG ORDER|DISCOUNTED' FORMAT 9,990.00
COLUMN avg_full   HEADING 'AVG ORDER|AT LIST'    FORMAT 9,990.00
COLUMN customers  HEADING 'CUSTOMERS'            FORMAT 99,990
COLUMN ord_cust   HEADING 'ORDERS PER|CUSTOMER'  FORMAT 90.00
COLUMN net_cust   HEADING 'NET RM|PER CUST'      FORMAT 9,990.00
COLUMN net_per_disc HEADING 'NET RM PER|RM DISCOUNT' FORMAT 9,990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF orders disc ON REPORT

WITH orders AS (
    -- ONE ROW PER COMPLETED ORDER: branch, year, date, customer and the
    -- customer's tier on the order date, whether ANY line was
    -- discounted, what was paid (net, no tax) and the discount given
    SELECT f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date,
           MAX(c.cus_ID)              AS cus_ID,
           MAX(c.cus_loyalty_tier)    AS tier,
           CASE WHEN SUM(f.order_discount_amt) > 0 THEN 1 ELSE 0 END AS discounted,
           CASE WHEN EXTRACT(MONTH FROM d.cal_date) = EXTRACT(DAY FROM d.cal_date)
                 AND EXTRACT(MONTH FROM d.cal_date) IN (3, 9, 10, 11, 12) THEN 1 ELSE 0 END AS promo_day,
           SUM(f.order_total_amt - f.order_tax_amt) AS net,
           SUM(f.order_discount_amt)                AS disc
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    GROUP  BY f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date
)
SELECT cal_year,
       COUNT(*)                                                       AS orders,
       ROUND(SUM(discounted) / COUNT(*) * 100, 1)                     AS disc_share,
       SUM(disc)                                                      AS disc,
       ROUND(SUM(disc) / NULLIF(SUM(net) + SUM(disc), 0) * 100, 2)    AS disc_rate,
       ROUND(SUM(CASE WHEN discounted = 1 THEN net END) / NULLIF(SUM(discounted), 0), 2)            AS avg_disc,
       ROUND(SUM(CASE WHEN discounted = 0 THEN net END) / NULLIF(COUNT(*) - SUM(discounted), 0), 2) AS avg_full,
       COUNT(DISTINCT cus_ID)                                         AS customers,
       ROUND(COUNT(*) / COUNT(DISTINCT cus_ID), 2)                    AS ord_cust,
       ROUND(SUM(net) / COUNT(DISTINCT cus_ID), 2)                    AS net_cust,
       ROUND(SUM(net) / NULLIF(SUM(disc), 0), 1)                      AS net_per_disc
FROM   orders
GROUP  BY cal_year
ORDER  BY cal_year;

-- ---- prompt 2: which year? -------------------------------------------
SPOOL OFF
ACCEPT p_year NUMBER DEFAULT 2025 PROMPT 'Year to open up (default 2025): '
SET TERMOUT OFF
COLUMN f_year NEW_VALUE f_year NOPRINT
SELECT TO_CHAR(NVL(MAX(CASE WHEN d.cal_year = &p_year THEN d.cal_year END), MAX(d.cal_year))) AS f_year
FROM   order_fact f JOIN date_dim d ON d.date_key = f.date_key JOIN branch_dim b ON b.branch_key = f.branch_key
WHERE  b.br_ID = &f_br_id;
CLEAR COLUMNS
SET TERMOUT ON
SPOOL discount_effectiveness_output.txt APPEND


-- ###################################################################
-- SECTION 3 - THE BRANCH-YEAR BY LOYALTY TIER
-- OLAP: DICE branch x year x tier: who gets the discount, what it
-- costs, and what each tier brings back per ringgit of discount.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. &f_branch &f_year: DISCOUNT BY LOYALTY TIER' SKIP 1 -
       CENTER 'DICE BRANCH x YEAR x TIER - WHO GETS IT AND WHAT IT BRINGS BACK' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN tier       HEADING 'TIER'                FORMAT A10
COLUMN orders     HEADING 'ORDERS'              FORMAT 999,990
COLUMN disc_share HEADING 'DISCOUNTED|ORDERS %'  FORMAT 990.0
COLUMN disc       HEADING 'DISCOUNT|GIVEN (RM)'  FORMAT 9,999,990
COLUMN disc_rate  HEADING 'DISCOUNT|RATE %'      FORMAT 90.00
COLUMN avg_disc   HEADING 'AVG ORDER|DISCOUNTED' FORMAT 9,990.00
COLUMN avg_full   HEADING 'AVG ORDER|AT LIST'    FORMAT 9,990.00
COLUMN customers  HEADING 'CUSTOMERS'            FORMAT 99,990
COLUMN ord_cust   HEADING 'ORDERS PER|CUSTOMER'  FORMAT 90.00
COLUMN net_cust   HEADING 'NET RM|PER CUST'      FORMAT 9,990.00
COLUMN net_per_disc HEADING 'NET RM PER|RM DISCOUNT' FORMAT 9,990.0
COLUMN net        HEADING 'NET|SALES (RM)'      FORMAT 9,999,990
COLUMN disc_cust  HEADING 'DISCOUNT|PER CUST'   FORMAT 990.00
COLUMN sort_key   NOPRINT

BREAK ON REPORT

WITH orders AS (
    -- ONE ROW PER COMPLETED ORDER: branch, year, date, customer and the
    -- customer's tier on the order date, whether ANY line was
    -- discounted, what was paid (net, no tax) and the discount given
    SELECT f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date,
           MAX(c.cus_ID)              AS cus_ID,
           MAX(c.cus_loyalty_tier)    AS tier,
           CASE WHEN SUM(f.order_discount_amt) > 0 THEN 1 ELSE 0 END AS discounted,
           CASE WHEN EXTRACT(MONTH FROM d.cal_date) = EXTRACT(DAY FROM d.cal_date)
                 AND EXTRACT(MONTH FROM d.cal_date) IN (3, 9, 10, 11, 12) THEN 1 ELSE 0 END AS promo_day,
           SUM(f.order_total_amt - f.order_tax_amt) AS net,
           SUM(f.order_discount_amt)                AS disc
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    GROUP  BY f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date
),
rows_ AS (
    SELECT tier, DECODE(tier, 'Platinum', 1, 'Gold', 2, 'Silver', 3, 'Bronze', 4, 5) AS sort_key,
       COUNT(*)                                                       AS orders,
       ROUND(SUM(discounted) / COUNT(*) * 100, 1)                     AS disc_share,
       SUM(disc)                                                      AS disc,
       ROUND(SUM(disc) / NULLIF(SUM(net) + SUM(disc), 0) * 100, 2)    AS disc_rate,
       ROUND(SUM(CASE WHEN discounted = 1 THEN net END) / NULLIF(SUM(discounted), 0), 2)            AS avg_disc,
       ROUND(SUM(CASE WHEN discounted = 0 THEN net END) / NULLIF(COUNT(*) - SUM(discounted), 0), 2) AS avg_full,
       COUNT(DISTINCT cus_ID)                                         AS customers,
       ROUND(COUNT(*) / COUNT(DISTINCT cus_ID), 2)                    AS ord_cust,
       ROUND(SUM(net) / COUNT(DISTINCT cus_ID), 2)                    AS net_cust,
       ROUND(SUM(net) / NULLIF(SUM(disc), 0), 1)                      AS net_per_disc,
           SUM(net) AS net,
           ROUND(SUM(disc) / COUNT(DISTINCT cus_ID), 2) AS disc_cust
    FROM   orders
    GROUP  BY tier
    UNION ALL
    SELECT 'ALL TIERS', 9,
       COUNT(*)                                                       AS orders,
       ROUND(SUM(discounted) / COUNT(*) * 100, 1)                     AS disc_share,
       SUM(disc)                                                      AS disc,
       ROUND(SUM(disc) / NULLIF(SUM(net) + SUM(disc), 0) * 100, 2)    AS disc_rate,
       ROUND(SUM(CASE WHEN discounted = 1 THEN net END) / NULLIF(SUM(discounted), 0), 2)            AS avg_disc,
       ROUND(SUM(CASE WHEN discounted = 0 THEN net END) / NULLIF(COUNT(*) - SUM(discounted), 0), 2) AS avg_full,
       COUNT(DISTINCT cus_ID)                                         AS customers,
       ROUND(COUNT(*) / COUNT(DISTINCT cus_ID), 2)                    AS ord_cust,
       ROUND(SUM(net) / COUNT(DISTINCT cus_ID), 2)                    AS net_cust,
       ROUND(SUM(net) / NULLIF(SUM(disc), 0), 1)                      AS net_per_disc,
           SUM(net),
           ROUND(SUM(disc) / COUNT(DISTINCT cus_ID), 2)
    FROM   orders
)
SELECT tier, orders, disc_share, disc, disc_rate, avg_disc, avg_full, customers, ord_cust,
       net_cust, disc_cust, net, net_per_disc, sort_key
FROM   rows_
ORDER  BY 14;


-- ###################################################################
-- SECTION 4 - BY THE DISCOUNT EACH CUSTOMER ACTUALLY RECEIVED
-- OLAP: DICE - the branch-year's customers banded by the discount
-- rate they got over the year (their discount / their gross): 0 %,
-- under 3 %, 3-7 %, 7-12 %, 12 % and over (roughly: promo-only
-- Bronze, Silver, Gold, Platinum, plus promo days on top). If the
-- discount works, orders per customer and net per customer should
-- climb along the bands faster than the discount per customer does.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. &f_branch &f_year: CUSTOMERS BY THE DISCOUNT THEY RECEIVED' SKIP 1 -
       CENTER 'DICE - THE EFFECTIVENESS CURVE: DO THE MORE-DISCOUNTED CUSTOMERS BUY MORE?' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN band       HEADING 'DISCOUNT|RECEIVED'   FORMAT A11
COLUMN customers  HEADING 'CUSTOMERS'           FORMAT 99,990
COLUMN cust_pct   HEADING 'CUST|%'              FORMAT 990.0
COLUMN orders     HEADING 'ORDERS'              FORMAT 99,990
COLUMN ord_cust   HEADING 'ORDERS PER|CUSTOMER' FORMAT 90.00
COLUMN net        HEADING 'NET|SALES (RM)'      FORMAT 9,999,990
COLUMN net_share  HEADING 'NET|SHARE %'         FORMAT 990.0
COLUMN net_cust   HEADING 'NET RM|PER CUST'     FORMAT 9,990.00
COLUMN avg_order  HEADING 'AVG|ORDER'           FORMAT 9,990.00
COLUMN disc       HEADING 'DISCOUNT|(RM)'       FORMAT 999,990
COLUMN disc_cust  HEADING 'DISCOUNT|PER CUST'   FORMAT 990.00
COLUMN disc_rate  HEADING 'ACTUAL|RATE %'       FORMAT 90.00
COLUMN net_per_disc HEADING 'NET RM PER|RM DISCOUNT' FORMAT 9,990.0
COLUMN sort_key   NOPRINT

WITH orders AS (
    -- ONE ROW PER COMPLETED ORDER: branch, year, date, customer and the
    -- customer's tier on the order date, whether ANY line was
    -- discounted, what was paid (net, no tax) and the discount given
    SELECT f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date,
           MAX(c.cus_ID)              AS cus_ID,
           MAX(c.cus_loyalty_tier)    AS tier,
           CASE WHEN SUM(f.order_discount_amt) > 0 THEN 1 ELSE 0 END AS discounted,
           CASE WHEN EXTRACT(MONTH FROM d.cal_date) = EXTRACT(DAY FROM d.cal_date)
                 AND EXTRACT(MONTH FROM d.cal_date) IN (3, 9, 10, 11, 12) THEN 1 ELSE 0 END AS promo_day,
           SUM(f.order_total_amt - f.order_tax_amt) AS net,
           SUM(f.order_discount_amt)                AS disc
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    GROUP  BY f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date
),
cust AS (
    SELECT cus_ID, COUNT(*) AS orders, SUM(net) AS net, SUM(disc) AS disc,
           SUM(disc) / NULLIF(SUM(net) + SUM(disc), 0) * 100 AS rate
    FROM   orders
    GROUP  BY cus_ID
),
banded AS (
    SELECT c.*,
           CASE WHEN rate = 0  THEN '0 %'
                WHEN rate < 3  THEN 'under 3 %'
                WHEN rate < 7  THEN '3 - 7 %'
                WHEN rate < 12 THEN '7 - 12 %'
                ELSE                '12 % +' END AS band,
           CASE WHEN rate = 0 THEN 1 WHEN rate < 3 THEN 2 WHEN rate < 7 THEN 3 WHEN rate < 12 THEN 4 ELSE 5 END AS sort_key
    FROM   cust c
)
SELECT band,
       COUNT(*)                                                    AS customers,
       ROUND(RATIO_TO_REPORT(COUNT(*)) OVER () * 100, 1)           AS cust_pct,
       SUM(orders)                                                 AS orders,
       ROUND(SUM(orders) / COUNT(*), 2)                            AS ord_cust,
       SUM(net)                                                    AS net,
       ROUND(RATIO_TO_REPORT(SUM(net)) OVER () * 100, 1)           AS net_share,
       ROUND(SUM(net) / COUNT(*), 2)                               AS net_cust,
       ROUND(SUM(net) / SUM(orders), 2)                            AS avg_order,
       SUM(disc)                                                   AS disc,
       ROUND(SUM(disc) / COUNT(*), 2)                              AS disc_cust,
       ROUND(SUM(disc) / NULLIF(SUM(net) + SUM(disc), 0) * 100, 2) AS disc_rate,
       ROUND(SUM(net) / NULLIF(SUM(disc), 0), 1)                   AS net_per_disc,
       sort_key
FROM   banded
GROUP  BY band, sort_key
ORDER  BY sort_key;


-- ###################################################################
-- SECTION 5 - PROMO DAYS vs ORDINARY DAYS
-- OLAP: DICE - the branch-year's trading days split into the five
-- mega-sale days (3.3, 9.9, 10.10, 11.11, 12.12) and the rest:
-- orders and net per day, average order, discount rate, and the LIFT
-- (promo-day figure / ordinary-day figure).
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. &f_branch &f_year: PROMO DAYS vs ORDINARY DAYS' SKIP 1 -
       CENTER 'DICE - WHAT THE 3.3 / 9.9 / 10.10 / 11.11 / 12.12 DISCOUNT BUYS PER DAY' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN day_type   HEADING 'DAY TYPE'            FORMAT A14
COLUMN days       HEADING 'TRADING|DAYS'        FORMAT 990
COLUMN orders     HEADING 'ORDERS'              FORMAT 99,990
COLUMN ord_day    HEADING 'ORDERS|PER DAY'      FORMAT 9,990.0
COLUMN cust_day   HEADING 'CUSTOMERS|PER DAY'   FORMAT 9,990.0
COLUMN avg_order  HEADING 'AVG|ORDER (RM)'      FORMAT 9,990.00
COLUMN disc_share HEADING 'DISCOUNTED|ORDERS %' FORMAT 990.0
COLUMN disc_rate  HEADING 'DISCOUNT|RATE %'     FORMAT 90.00
COLUMN net_day    HEADING 'NET RM|PER DAY'      FORMAT 999,990
COLUMN disc_day   HEADING 'DISCOUNT RM|PER DAY' FORMAT 99,990
COLUMN lift_ord   HEADING 'ORDERS|LIFT x'       FORMAT 90.00
COLUMN lift_net   HEADING 'NET|LIFT x'          FORMAT 90.00
COLUMN sort_key   NOPRINT

WITH orders AS (
    -- ONE ROW PER COMPLETED ORDER: branch, year, date, customer and the
    -- customer's tier on the order date, whether ANY line was
    -- discounted, what was paid (net, no tax) and the discount given
    SELECT f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date,
           MAX(c.cus_ID)              AS cus_ID,
           MAX(c.cus_loyalty_tier)    AS tier,
           CASE WHEN SUM(f.order_discount_amt) > 0 THEN 1 ELSE 0 END AS discounted,
           CASE WHEN EXTRACT(MONTH FROM d.cal_date) = EXTRACT(DAY FROM d.cal_date)
                 AND EXTRACT(MONTH FROM d.cal_date) IN (3, 9, 10, 11, 12) THEN 1 ELSE 0 END AS promo_day,
           SUM(f.order_total_amt - f.order_tax_amt) AS net,
           SUM(f.order_discount_amt)                AS disc
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    GROUP  BY f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date
),
d AS (
    SELECT promo_day,
           COUNT(DISTINCT cal_date) AS days, COUNT(*) AS orders,
           COUNT(DISTINCT cal_date || '-' || cus_ID) AS cust_days,
           SUM(discounted) AS n_disc, SUM(net) AS net, SUM(disc) AS disc
    FROM   orders
    GROUP  BY promo_day
),
o AS (SELECT * FROM d WHERE promo_day = 0)
SELECT CASE WHEN d.promo_day = 1 THEN 'PROMO DAYS' ELSE 'ORDINARY DAYS' END AS day_type,
       d.days, d.orders,
       ROUND(d.orders / d.days, 1)                                    AS ord_day,
       ROUND(d.cust_days / d.days, 1)                                 AS cust_day,
       ROUND(d.net / d.orders, 2)                                     AS avg_order,
       ROUND(d.n_disc / d.orders * 100, 1)                            AS disc_share,
       ROUND(d.disc / NULLIF(d.net + d.disc, 0) * 100, 2)             AS disc_rate,
       ROUND(d.net / d.days)                                          AS net_day,
       ROUND(d.disc / d.days)                                         AS disc_day,
       ROUND((d.orders / d.days) / NULLIF(o.orders / o.days, 0), 2)   AS lift_ord,
       ROUND((d.net / d.days) / NULLIF(o.net / o.days, 0), 2)         AS lift_net,
       1 - d.promo_day AS sort_key
FROM   d CROSS JOIN o
ORDER  BY 13;


-- ###################################################################
-- SECTION 6 - DID THEY COME BACK?
-- OLAP: DRILL-ACROSS - the branch-year's customers split into those
-- who received at least one discounted order this year and those who
-- paid list on every order, then followed into year + 1 (any branch,
-- orders or visits) and back into year - 1. If the discount buys
-- loyalty, the discounted group should return more.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 6. &f_branch &f_year: DID THE DISCOUNTED CUSTOMERS COME BACK?' SKIP 1 -
       CENTER 'THIS YEAR''S CUSTOMERS FOLLOWED INTO YEAR + 1 (AND BACK INTO YEAR - 1), ANY BRANCH' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN grp        HEADING 'CUSTOMER GROUP'      FORMAT A22
COLUMN customers  HEADING 'CUSTOMERS'           FORMAT 99,990
COLUMN cust_pct   HEADING 'CUST|%'              FORMAT 990.0
COLUMN ord_cust   HEADING 'ORDERS PER|CUSTOMER' FORMAT 90.00
COLUMN net_cust   HEADING 'NET RM|PER CUST'     FORMAT 9,990.00
COLUMN disc_cust  HEADING 'DISCOUNT|PER CUST'   FORMAT 990.00
COLUMN was_prev   HEADING 'ACTIVE IN|YEAR-1 %'  FORMAT 990.0
COLUMN ret_next   HEADING 'ACTIVE IN|YEAR+1 %'  FORMAT 990.0
COLUMN next_net   HEADING 'NEXT-YEAR NET|PER RETURNER' FORMAT 9,990.00
COLUMN sort_key   NOPRINT

WITH orders AS (
    -- ONE ROW PER COMPLETED ORDER: branch, year, date, customer and the
    -- customer's tier on the order date, whether ANY line was
    -- discounted, what was paid (net, no tax) and the discount given
    SELECT f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date,
           MAX(c.cus_ID)              AS cus_ID,
           MAX(c.cus_loyalty_tier)    AS tier,
           CASE WHEN SUM(f.order_discount_amt) > 0 THEN 1 ELSE 0 END AS discounted,
           CASE WHEN EXTRACT(MONTH FROM d.cal_date) = EXTRACT(DAY FROM d.cal_date)
                 AND EXTRACT(MONTH FROM d.cal_date) IN (3, 9, 10, 11, 12) THEN 1 ELSE 0 END AS promo_day,
           SUM(f.order_total_amt - f.order_tax_amt) AS net,
           SUM(f.order_discount_amt)                AS disc
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    GROUP  BY f.order_ID, b.br_ID, b.br_city, b.br_state, d.cal_year, d.cal_date
),
cust AS (
    SELECT cus_ID, COUNT(*) AS orders, SUM(net) AS net, SUM(disc) AS disc,
           MAX(discounted) AS got_disc
    FROM   orders
    GROUP  BY cus_ID
),
activity AS (
    -- every customer-year with a completed order or visit anywhere
    SELECT c.cus_ID, d.cal_year, SUM(f.order_total_amt - f.order_tax_amt) AS net
    FROM   order_fact f JOIN date_dim d ON d.date_key = f.date_key JOIN customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed' AND d.cal_year IN (&f_year - 1, &f_year + 1)
    GROUP  BY c.cus_ID, d.cal_year
    UNION ALL
    SELECT c.cus_ID, d.cal_year, SUM(f.serv_total_amt - f.serv_tax_amt)
    FROM   reservation_fact f JOIN date_dim d ON d.date_key = f.date_key JOIN customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed' AND d.cal_year IN (&f_year - 1, &f_year + 1)
    GROUP  BY c.cus_ID, d.cal_year
),
prev AS (SELECT DISTINCT cus_ID FROM activity WHERE cal_year = &f_year - 1),
nxt  AS (SELECT cus_ID, SUM(net) AS net FROM activity WHERE cal_year = &f_year + 1 GROUP BY cus_ID),
has_next AS (SELECT COUNT(*) AS n FROM date_dim WHERE cal_year = &f_year + 1),
j AS (
    SELECT c.*, CASE WHEN p.cus_ID IS NULL THEN 0 ELSE 1 END AS was_prev,
           CASE WHEN n.cus_ID IS NULL THEN 0 ELSE 1 END AS ret_next, n.net AS next_net
    FROM   cust c LEFT JOIN prev p ON p.cus_ID = c.cus_ID LEFT JOIN nxt n ON n.cus_ID = c.cus_ID
),
rows_ AS (
    SELECT CASE WHEN got_disc = 1 THEN 'HAD A DISCOUNTED ORDER' ELSE 'PAID LIST ALL YEAR' END AS grp,
           2 - got_disc AS sort_key,
           COUNT(*) AS customers, SUM(orders) AS orders, SUM(net) AS net, SUM(disc) AS disc,
           SUM(was_prev) AS was_prev, SUM(ret_next) AS ret_next, SUM(next_net) AS next_net
    FROM   j GROUP BY got_disc
    UNION ALL
    SELECT 'ALL CUSTOMERS', 9, COUNT(*), SUM(orders), SUM(net), SUM(disc), SUM(was_prev), SUM(ret_next), SUM(next_net)
    FROM   j
)
SELECT r.grp, r.customers,
       ROUND(r.customers / NULLIF(SUM(CASE WHEN r.sort_key < 9 THEN r.customers END) OVER (), 0) * 100, 1) AS cust_pct,
       ROUND(r.orders / r.customers, 2)                            AS ord_cust,
       ROUND(r.net / r.customers, 2)                               AS net_cust,
       ROUND(r.disc / r.customers, 2)                              AS disc_cust,
       ROUND(r.was_prev / r.customers * 100, 1)                    AS was_prev,
       CASE WHEN h.n > 0 THEN ROUND(r.ret_next / r.customers * 100, 1) END AS ret_next,
       CASE WHEN h.n > 0 THEN ROUND(r.next_net / NULLIF(r.ret_next, 0), 2) END AS next_net,
       r.sort_key
FROM   rows_ r CROSS JOIN has_next h
ORDER  BY r.sort_key;

PROMPT
PROMPT +==========================================================+
PROMPT |         END OF DISCOUNT EFFECTIVENESS REPORT             |
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
UNDEFINE p_branch
UNDEFINE p_year
UNDEFINE f_br_id
UNDEFINE f_branch
UNDEFINE f_year
UNDEFINE run_dt
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
