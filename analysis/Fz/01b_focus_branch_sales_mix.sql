-- ===================================================================
-- 01b_focus_branch_sales_mix.sql
-- SALES ANALYSIS - THE FOCUS BRANCH: WHAT IT SELLS AND WHO BUYS
--   companion to 01_fy2024_branch_paradox.sql (same prompts, same
--   focus branch): the product / service mix and the customer mix of
--   ONE branch against the average branch of the company
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Fz\01b_focus_branch_sales_mix.sql
--
-- PARAMETERS (prompted)
--   focus year   the financial year every cut zooms into (default 2024)
--   branch       the branch city to drill into (default Ipoh - if the
--                name matches nothing, the branch with the LOWEST net
--                profit in the focus year is taken)
--
-- WHAT IT ANSWERS
--   1. Does the branch sell a DIFFERENT mix than the company, or just
--      LESS of everything?  (product categories, service categories,
--      top-10 products, each next to the average branch and the
--      company mix)
--   2. Who provides its sales - which loyalty tiers, and how many of
--      its customers are locals vs visitors from other cities?
--
-- THE CUBE
--   facts     order_fact, reservation_fact
--   dims      date_dim.cal_year, branch_dim.br_ID / br_city / br_state,
--             product_dim.product_category / product_name,
--             service_dim.serv_category,
--             customer_dim.cus_ID / cus_loyalty_tier / cus_city / cus_state
--   measures  Sales (RM) = order_total_amt - order_tax_amt and
--             serv_total_amt - serv_tax_amt (Completed only, no tax);
--             Units = SUM(order_qty); Visits = service lines;
--             Buyers / Customers = COUNT(DISTINCT cus_ID) - never
--             customer_key, customer_dim is SCD2. Product / service
--             rows group on category and name, never on the surrogate
--             key (SCD2 price versions roll up together).
--   average branch = company total / branches trading in the year
--
-- REPORT SECTIONS  (each one is ONE OLAP operation)
--   1  PRODUCT SALES BY CATEGORY      DICE   year x branch x category, vs
--                                            the average branch, buyers
--   2  SERVICE SALES BY CATEGORY      DICE   same on the reservation cube
--   3  TOP 10 PRODUCTS                DRILL  category -> product, with the
--                                     -DOWN  company-wide rank
--   4  CUSTOMERS BY LOYALTY TIER      DICE   who provides the sales
--   5  CUSTOMERS BY HOME CITY         DICE   local vs visitors
--
-- WHAT TO LOOK FOR  (FY2024, Ipoh, revision-5 data = sales_data5)
--   - Section 1: the SAME mix as the company - every category's share
--     is within a point of the company mix (Serum 19.5 %, Face Cream
--     14 %, Face Mask 13 %, Sunscreen 11 %, Facial Cleanser 9 % ...) -
--     but 44-51 % LESS of every category than the average branch
--     (RM 617 k vs 1.19 M), sold to about half as many buyers (409 Serum
--     buyers vs 727, 488 Cleanser buyers vs 905 ...). Realised prices
--     are normal - Ipoh does not discount its way into trouble.
--   - Section 2: services 22-30 % below the average branch in every
--     category (RM 159 k vs 218 k); Anti Aging 34 % of its service sales,
--     like everywhere else.
--   - Section 3: its top-10 products are the company's top-10 (rank
--     here vs company 1/1, 2/4, 3/6, 4/2 ...) - a normal shelf, no
--     price versions in 2024 (the 2024 rise was on 2024-01-01).
--   - Section 4: Silver + Bronze regulars provide 73 % of its sales;
--     tier mix close to the company's (Bronze 46 % vs 53 %).
--   - Section 5: 634 LOCAL (Perak) customers give 52 % of the sales at
--     RM 642 each; 1,061 visitors from 16 other cities give the other
--     48 % (RM 350 each) - online orders since 2022 are fulfilled by any
--     branch, so every branch has a long tail of visitors. Ipoh sells a
--     normal mix at normal prices to fewer people; what makes it the
--     loss-maker is what it PAYS for the stock (01 section 5).
--   - Run it with branch = Kuantan or Seremban for an opening-year mix
--     (42-46 % new customers, 14 % local), or with year 2025 to see the
--     HIM Essentials men's line appear in section 3.
-- ===================================================================

-- reset anything a previous script left behind in this session
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 165
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

-- SQL*Plus caps an ACCEPT prompt at 99 characters - keep it short.
ACCEPT focus_year  NUMBER DEFAULT 2024       PROMPT 'Focus year (default 2024): '
ACCEPT focus_branch CHAR  DEFAULT 'Ipoh'     PROMPT 'Branch city to drill into (default Ipoh): '

-- ---- values reused in every title ---------------------------------
-- TERMOUT OFF hides these helper queries (only works when the file is
-- run with @, which is how this report is meant to be run). TO_CHAR
-- keeps the numbers from being captured with leading spaces.
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN focus_y NEW_VALUE focus_y NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;

-- ---- the branch every section drills into ---------------------------
-- focus_*  = the branch whose city matches the prompt (default Ipoh,
--            the loss-making one). If nothing matches, the script falls
--            back to the branch with the LOWEST net profit in the focus
--            year, so the drill always lands on the branch that most
--            needs explaining.
-- best_*   = the branch with the highest earning % in the focus year -
--            the yardstick sections 6 and 7 compare against.
COLUMN focus_id     NEW_VALUE focus_id     NOPRINT
COLUMN focus_city   NEW_VALUE focus_city   NOPRINT
COLUMN focus_br_state NEW_VALUE focus_br_state NOPRINT
COLUMN best_id      NEW_VALUE best_id      NOPRINT
COLUMN best_city    NEW_VALUE best_city    NOPRINT

WITH pnl AS (
    SELECT br_ID, br_city, br_state,
           SUM(rev) AS rev, SUM(cost) AS cost
    FROM (
        SELECT b.br_ID, b.br_city, b.br_state,
               SUM(f.order_total_amt - f.order_tax_amt) AS rev, 0 AS cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               SUM(f.serv_total_amt - f.serv_tax_amt), 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               0, SUM(f.purchase_total_cost)
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               0, SUM(f.base_amount + f.bonus_amount)
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               0, SUM(f.payment_amount)
        FROM   branch_utils_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
    )
    GROUP BY br_ID, br_city, br_state
),
cand AS (
    SELECT br_ID, br_city, br_state, rev - cost AS net,
           (rev - cost) / NULLIF(rev, 0) AS margin,
           CASE WHEN UPPER(br_city) LIKE '%' || UPPER(TRIM('&focus_branch')) || '%'
                THEN 0 ELSE 1 END AS miss
    FROM   pnl
)
SELECT TO_CHAR(MAX(br_ID) KEEP (DENSE_RANK FIRST ORDER BY miss, net))       AS focus_id,
       MAX(br_city)       KEEP (DENSE_RANK FIRST ORDER BY miss, net)        AS focus_city,
       MAX(br_state)      KEEP (DENSE_RANK FIRST ORDER BY miss, net)        AS focus_br_state,
       TO_CHAR(MAX(br_ID) KEEP (DENSE_RANK FIRST ORDER BY margin DESC NULLS LAST)) AS best_id,
       MAX(br_city)       KEEP (DENSE_RANK FIRST ORDER BY margin DESC NULLS LAST)  AS best_city
FROM   cand;

CLEAR COLUMNS
SET TERMOUT ON

SPOOL focus_branch_sales_mix_output.txt


-- ###################################################################
-- SECTION 1 - THE FOCUS BRANCH: PRODUCT SALES BY CATEGORY
-- OLAP: DRILL-DOWN state -> ONE branch, then DICE year x branch x
-- product category (fourth dimension product_dim). Every category the
-- company sells is listed, with what the focus branch sold in it, its
-- share of the branch's product sales, the realised price, and the
-- same category at the AVERAGE branch (company / branches trading) -
-- VS AVG % < 0 means the branch under-sells that category. COMPANY
-- MIX % is the category's share company-wide: compare it with the
-- branch's SHARE % to see whether the branch sells a different mix or
-- simply less of everything.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. FY&focus_y &focus_city: PRODUCT SALES BY CATEGORY' SKIP 1 -
       CENTER 'THE FOCUS BRANCH vs THE AVERAGE BRANCH, CATEGORY BY CATEGORY (DICE)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk           HEADING 'RANK'                 FORMAT 99
COLUMN product_category HEADING 'CATEGORY'          FORMAT A19
COLUMN lines         HEADING 'ORDER|LINES'          FORMAT 99,990
COLUMN units         HEADING 'UNITS'                FORMAT 999,990
COLUMN sales         HEADING 'SALES (RM)'           FORMAT 9,999,990.00
COLUMN share_pct     HEADING 'SHARE|%'              FORMAT 990.0
COLUMN avg_price     HEADING 'REALISED|PRICE (RM)'  FORMAT 9,990.00
COLUMN avg_branch    HEADING 'AVG BRANCH|SALES (RM)' FORMAT 9,999,990.00
COLUMN vs_avg_pct    HEADING 'VS AVG|%'             FORMAT S990.0
COLUMN comp_share    HEADING 'COMPANY|MIX %'        FORMAT 990.0
COLUMN products      HEADING 'PRODUCTS|SOLD'        FORMAT 990
COLUMN buyers        HEADING 'BUYERS'               FORMAT 9,990
COLUMN avg_buyers    HEADING 'AVG BR|BUYERS'        FORMAT 9,990
COLUMN sales_buyer   HEADING 'SALES PER|BUYER (RM)' FORMAT 9,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF lines units sales avg_branch ON REPORT

WITH prod AS (
    -- one row per branch x category for the focus year. Group on the
    -- category NAME, not product_key: product_dim is SCD2 (price
    -- versions), and the versions must roll up together
    SELECT b.br_ID, p.product_category,
           COUNT(*)                                  AS lines,
           SUM(f.order_qty)                          AS units,
           SUM(f.order_total_amt - f.order_tax_amt)  AS sales,
           COUNT(DISTINCT p.product_ID)              AS products,
           COUNT(DISTINCT c.cus_ID)                  AS buyers
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   product_dim  p ON p.product_key  = f.product_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year = &focus_year
    GROUP  BY b.br_ID, p.product_category
),
n AS (
    SELECT COUNT(DISTINCT br_ID) AS n_br FROM prod
),
comp AS (
    SELECT product_category, SUM(sales) AS sales, SUM(buyers) AS buyers
    FROM   prod
    GROUP  BY product_category
),
focus AS (
    SELECT * FROM prod WHERE br_ID = &focus_id
)
SELECT RANK() OVER (ORDER BY NVL(f.sales, 0) DESC)                    AS rnk,
       c.product_category,
       f.lines, f.units, f.sales,
       ROUND(RATIO_TO_REPORT(f.sales) OVER () * 100, 1)               AS share_pct,
       ROUND(f.sales / NULLIF(f.units, 0), 2)                         AS avg_price,
       c.sales / n.n_br                                                AS avg_branch,
       ROUND((NVL(f.sales, 0) / (c.sales / n.n_br) - 1) * 100, 1)     AS vs_avg_pct,
       ROUND(RATIO_TO_REPORT(c.sales) OVER () * 100, 1)               AS comp_share,
       f.products,
       f.buyers,
       ROUND(c.buyers / n.n_br)                                        AS avg_buyers,
       ROUND(f.sales / NULLIF(f.buyers, 0), 2)                        AS sales_buyer
FROM   comp c
LEFT   JOIN focus f ON f.product_category = c.product_category
CROSS  JOIN n
ORDER  BY rnk;


-- ###################################################################
-- SECTION 2 - THE FOCUS BRANCH: SERVICE SALES BY CATEGORY
-- OLAP: same DICE on the reservation cube (year x branch x service
-- category, dimension service_dim). VISITS = service lines performed.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. FY&focus_y &focus_city: SERVICE SALES BY CATEGORY' SKIP 1 -
       CENTER 'THE FOCUS BRANCH vs THE AVERAGE BRANCH, CATEGORY BY CATEGORY (DICE)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk           HEADING 'RANK'                 FORMAT 99
COLUMN serv_category HEADING 'SERVICE CATEGORY'     FORMAT A20
COLUMN visits        HEADING 'VISITS'               FORMAT 99,990
COLUMN sales         HEADING 'SALES (RM)'           FORMAT 9,999,990.00
COLUMN share_pct     HEADING 'SHARE|%'              FORMAT 990.0
COLUMN avg_price     HEADING 'REALISED|PRICE (RM)'  FORMAT 9,990.00
COLUMN avg_branch    HEADING 'AVG BRANCH|SALES (RM)' FORMAT 9,999,990.00
COLUMN vs_avg_pct    HEADING 'VS AVG|%'             FORMAT S990.0
COLUMN comp_share    HEADING 'COMPANY|MIX %'        FORMAT 990.0
COLUMN services      HEADING 'SERVICES|SOLD'        FORMAT 990
COLUMN buyers        HEADING 'BUYERS'               FORMAT 9,990
COLUMN avg_buyers    HEADING 'AVG BR|BUYERS'        FORMAT 9,990
COLUMN sales_buyer   HEADING 'SALES PER|BUYER (RM)' FORMAT 9,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF visits sales avg_branch ON REPORT

WITH serv AS (
    SELECT b.br_ID, s.serv_category,
           COUNT(*)                                  AS visits,
           SUM(f.serv_total_amt - f.serv_tax_amt)    AS sales,
           COUNT(DISTINCT s.serv_ID)                 AS services,
           COUNT(DISTINCT c.cus_ID)                  AS buyers
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   service_dim  s ON s.service_key  = f.service_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    GROUP  BY b.br_ID, s.serv_category
),
n AS (
    SELECT COUNT(DISTINCT br_ID) AS n_br FROM serv
),
comp AS (
    SELECT serv_category, SUM(sales) AS sales, SUM(buyers) AS buyers
    FROM   serv
    GROUP  BY serv_category
),
focus AS (
    SELECT * FROM serv WHERE br_ID = &focus_id
)
SELECT RANK() OVER (ORDER BY NVL(f.sales, 0) DESC)                    AS rnk,
       c.serv_category,
       f.visits, f.sales,
       ROUND(RATIO_TO_REPORT(f.sales) OVER () * 100, 1)               AS share_pct,
       ROUND(f.sales / NULLIF(f.visits, 0), 2)                        AS avg_price,
       c.sales / n.n_br                                                AS avg_branch,
       ROUND((NVL(f.sales, 0) / (c.sales / n.n_br) - 1) * 100, 1)     AS vs_avg_pct,
       ROUND(RATIO_TO_REPORT(c.sales) OVER () * 100, 1)               AS comp_share,
       f.services,
       f.buyers,
       ROUND(c.buyers / n.n_br)                                        AS avg_buyers,
       ROUND(f.sales / NULLIF(f.buyers, 0), 2)                        AS sales_buyer
FROM   comp c
LEFT   JOIN focus f ON f.serv_category = c.serv_category
CROSS  JOIN n
ORDER  BY rnk;


-- ###################################################################
-- SECTION 3 - THE FOCUS BRANCH: TOP 10 PRODUCTS
-- OLAP: DRILL-DOWN category -> product for the focus branch. Its own
-- rank sits next to the product's rank company-wide, so a product
-- that is #2 here but #9 everywhere else (or the reverse) stands out.
-- PRICE VERSIONS > 1 = the product had a price rise (SCD2 rows).
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. FY&focus_y &focus_city: TOP 10 PRODUCTS' SKIP 1 -
       CENTER 'DRILL-DOWN CATEGORY -> PRODUCT, WITH THE COMPANY-WIDE RANK' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk           HEADING 'RANK|HERE'            FORMAT 99
COLUMN comp_rnk      HEADING 'RANK|COMPANY'         FORMAT 99
COLUMN product_name  HEADING 'PRODUCT'              FORMAT A31
COLUMN product_category HEADING 'CATEGORY'          FORMAT A19
COLUMN units         HEADING 'UNITS'                FORMAT 99,990
COLUMN sales         HEADING 'SALES (RM)'           FORMAT 999,990.00
COLUMN share_pct     HEADING 'SHARE|%'              FORMAT 990.0
COLUMN avg_price     HEADING 'REALISED|PRICE (RM)'  FORMAT 9,990.00
COLUMN versions      HEADING 'PRICE|VERSIONS'       FORMAT 90

WITH prod AS (
    SELECT b.br_ID, p.product_ID, p.product_name, p.product_category,
           SUM(f.order_qty)                          AS units,
           SUM(f.order_total_amt - f.order_tax_amt)  AS sales,
           COUNT(DISTINCT p.product_key)             AS versions
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year = &focus_year
    GROUP  BY b.br_ID, p.product_ID, p.product_name, p.product_category
),
comp AS (
    SELECT product_ID, RANK() OVER (ORDER BY SUM(sales) DESC) AS comp_rnk
    FROM   prod
    GROUP  BY product_ID
),
focus AS (
    SELECT p.*,
           RANK() OVER (ORDER BY p.sales DESC)                 AS rnk,
           ROUND(RATIO_TO_REPORT(p.sales) OVER () * 100, 1)   AS share_pct
    FROM   prod p
    WHERE  p.br_ID = &focus_id
)
SELECT f.rnk, c.comp_rnk, f.product_name, f.product_category, f.units, f.sales, f.share_pct,
       ROUND(f.sales / NULLIF(f.units, 0), 2) AS avg_price, f.versions
FROM   focus f
JOIN   comp  c ON c.product_ID = f.product_ID
WHERE  f.rnk <= 10
ORDER  BY f.rnk;


-- ###################################################################
-- SECTION 4 - THE FOCUS BRANCH: CUSTOMERS BY LOYALTY TIER
-- OLAP: DICE year x branch x loyalty tier (customer_dim). Who
-- provides the sales - a few Gold/Platinum regulars or many Bronze
-- walk-ins? COMPANY % = the tier's share of customers company-wide,
-- for comparison with the branch's CUST % column.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. FY&focus_y &focus_city: CUSTOMERS BY LOYALTY TIER' SKIP 1 -
       CENTER 'WHO PROVIDES THE SALES (DICE: YEAR x BRANCH x TIER)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cus_loyalty_tier HEADING 'TIER'              FORMAT A10
COLUMN customers     HEADING 'CUSTOMERS'            FORMAT 99,990
COLUMN cust_pct      HEADING 'CUST|%'               FORMAT 990.0
COLUMN comp_pct      HEADING 'COMPANY|CUST %'       FORMAT 990.0
COLUMN txns          HEADING 'ORDERS +|VISITS'      FORMAT 99,990
COLUMN sales         HEADING 'SALES (RM)'           FORMAT 9,999,990.00
COLUMN sales_pct     HEADING 'SALES|%'              FORMAT 990.0
COLUMN sales_cus     HEADING 'SALES PER|CUSTOMER'   FORMAT 99,990.00
COLUMN txn_cus       HEADING 'TXNS PER|CUSTOMER'    FORMAT 90.00
COLUMN tier_order    NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF customers txns sales ON REPORT

WITH txn AS (
    SELECT b.br_ID, c.cus_ID, c.cus_loyalty_tier, f.order_ID AS txn_id, 'O' AS kind,
           f.order_total_amt - f.order_tax_amt AS amt
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year = &focus_year
    UNION ALL
    SELECT b.br_ID, c.cus_ID, c.cus_loyalty_tier, f.res_ID, 'R',
           f.serv_total_amt - f.serv_tax_amt
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
),
comp AS (
    -- a customer counts once per tier company-wide (the tier is the
    -- version in force on the transaction date, so a promoted customer
    -- can appear in two tiers - that is what SCD2 is for)
    SELECT cus_loyalty_tier,
           ROUND(RATIO_TO_REPORT(COUNT(DISTINCT cus_ID)) OVER () * 100, 1) AS comp_pct
    FROM   txn GROUP BY cus_loyalty_tier
),
focus AS (
    SELECT cus_loyalty_tier,
           COUNT(DISTINCT cus_ID)                     AS customers,
           COUNT(DISTINCT kind || '-' || txn_id)      AS txns,
           SUM(amt)                                   AS sales
    FROM   txn WHERE br_ID = &focus_id
    GROUP  BY cus_loyalty_tier
)
SELECT f.cus_loyalty_tier, f.customers,
       ROUND(RATIO_TO_REPORT(f.customers) OVER () * 100, 1)   AS cust_pct,
       c.comp_pct,
       f.txns, f.sales,
       ROUND(RATIO_TO_REPORT(f.sales) OVER () * 100, 1)       AS sales_pct,
       ROUND(f.sales / NULLIF(f.customers, 0), 2)             AS sales_cus,
       ROUND(f.txns  / NULLIF(f.customers, 0), 2)             AS txn_cus,
       CASE f.cus_loyalty_tier WHEN 'Platinum' THEN 1 WHEN 'Gold' THEN 2
                               WHEN 'Silver'   THEN 3 WHEN 'Bronze' THEN 4 ELSE 5 END AS tier_order
FROM   focus f
JOIN   comp  c ON c.cus_loyalty_tier = f.cus_loyalty_tier
ORDER  BY tier_order;


-- ###################################################################
-- SECTION 5 - THE FOCUS BRANCH: WHERE ITS CUSTOMERS COME FROM
-- OLAP: DICE year x branch x customer home city/state (customer_dim
-- geography). LOCAL = the customer's home state is the branch's state
-- (&focus_br_state); the rest are visitors from other states.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. FY&focus_y &focus_city: CUSTOMERS BY HOME CITY' SKIP 1 -
       CENTER 'LOCAL (&focus_br_state) vs VISITORS' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN home          HEADING 'HOME'                 FORMAT A8
COLUMN cus_city      HEADING 'CUSTOMER CITY'        FORMAT A16
COLUMN cus_state     HEADING 'STATE'                FORMAT A19
COLUMN customers     HEADING 'CUSTOMERS'            FORMAT 99,990
COLUMN cust_pct      HEADING 'CUST|%'               FORMAT 990.0
COLUMN txns          HEADING 'ORDERS +|VISITS'      FORMAT 99,990
COLUMN sales         HEADING 'SALES (RM)'           FORMAT 9,999,990.00
COLUMN sales_pct     HEADING 'SALES|%'              FORMAT 990.0
COLUMN sales_cus     HEADING 'SALES PER|CUSTOMER'   FORMAT 99,990.00

BREAK ON home SKIP 1
COMPUTE SUM LABEL 'SUB' OF customers txns sales ON home

WITH txn AS (
    SELECT c.cus_ID, c.cus_city, c.cus_state, f.order_ID AS txn_id, 'O' AS kind,
           f.order_total_amt - f.order_tax_amt AS amt
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year = &focus_year
    AND    b.br_ID = &focus_id
    UNION ALL
    SELECT c.cus_ID, c.cus_city, c.cus_state, f.res_ID, 'R',
           f.serv_total_amt - f.serv_tax_amt
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    AND    b.br_ID = &focus_id
),
by_city AS (
    SELECT CASE WHEN UPPER(cus_state) = UPPER('&focus_br_state') THEN 'LOCAL' ELSE 'VISITOR' END AS home,
           cus_city, cus_state,
           COUNT(DISTINCT cus_ID)                 AS customers,
           COUNT(DISTINCT kind || '-' || txn_id)  AS txns,
           SUM(amt)                               AS sales
    FROM   txn
    GROUP  BY CASE WHEN UPPER(cus_state) = UPPER('&focus_br_state') THEN 'LOCAL' ELSE 'VISITOR' END,
              cus_city, cus_state
)
SELECT home, cus_city, cus_state, customers,
       ROUND(RATIO_TO_REPORT(customers) OVER () * 100, 1) AS cust_pct,
       txns, sales,
       ROUND(RATIO_TO_REPORT(sales) OVER () * 100, 1)     AS sales_pct,
       ROUND(sales / NULLIF(customers, 0), 2)             AS sales_cus
FROM   by_city
ORDER  BY home, customers DESC;


PROMPT
PROMPT +==========================================================+
PROMPT |        END OF FOCUS BRANCH SALES + CUSTOMER MIX REPORT   |
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
UNDEFINE focus_year
UNDEFINE focus_y
UNDEFINE focus_branch
UNDEFINE focus_id
UNDEFINE focus_city
UNDEFINE focus_br_state
UNDEFINE best_id
UNDEFINE best_city
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
