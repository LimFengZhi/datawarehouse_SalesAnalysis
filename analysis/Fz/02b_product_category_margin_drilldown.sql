-- ===================================================================
-- 02b_product_category_margin_drilldown.sql
-- SALES ANALYSIS - PRODUCT GROSS PROFIT (SALES - PURCHASE COST),
--                  DRILLED DOWN STEP BY STEP
--   the same walk as 02_product_category_drilldown.sql - states x years
--   -> STATE -> branches -> BRANCH -> years x quarters -> YEAR ->
--   categories ranked -> CATEGORY -> products - but every level now
--   carries the COST OF THE UNITS SOLD next to the sales, so the
--   measure that is ranked and pivoted is GROSS PROFIT and its MARGIN %.
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Fz\02b_product_category_margin_drilldown.sql
--
-- PARAMETERS (the year range at the start; the rest ONE AT A TIME,
-- each after the table it refers to has printed)
--   start year, end year   at the start   defaults 2019 and 2025
--   state      after section 1   default Selangor
--   branch     after section 2   default Petaling Jaya
--   year       after section 3   default = end year
--   category   after section 4   default Serum
--   A name that matches nothing falls back to the biggest member of
--   that level (top-selling state / branch / category). The spool is
--   paused around every prompt, so the output file holds only tables.
--
-- WHAT IT ANSWERS
--   1. How much of the product revenue is left after the cost of the
--      goods sold - state by state, branch by branch, year by year?
--   2. Which quarters, categories and products carry the best and the
--      worst margins, and does a category that sells a lot also EARN
--      a lot?
--   3. What is the mark-up: realised selling price against unit cost?
--
-- THE CUBE  (a DRILL-ACROSS of two facts on the conformed dimensions)
--   facts     order_fact     product lines sold   (Completed only)
--             purchase_fact  stock bought from suppliers
--   dims      date_dim.cal_year / cal_quarter
--             branch_dim.br_state / br_ID / br_city
--             product_dim.product_category / product_name
--   measures  Sales (RM)     = order_total_amt - order_tax_amt
--             Unit cost      = the price actually paid to suppliers for
--                              that product at that branch in that year:
--                              purchase_total_cost / purchase_qty from
--                              purchase_fact (falls back to the company-
--                              wide unit cost of the product-year if the
--                              branch bought none that year)
--             COGS (RM)      = units sold x unit cost   ("what I sold,
--                              costed at what I paid for it")
--             Gross profit   = sales - COGS
--             Margin %       = gross profit / sales x 100
--             Realised price = sales / units sold  (after discounts)
--             Markup         = sales / COGS  (= realised price / unit cost)
--             Buy/sold       = units bought / units sold  (information:
--                              > 1 = the branch built stock that period)
--
-- READ THIS BEFORE QUOTING A MARGIN
--   The product table carries no cost, so the unit cost is derived from
--   the purchase lines (weighted average per branch, product and year).
--   COGS therefore matches the units SOLD, not the stock BOUGHT - a
--   branch that stocks up (opening stock, a launch, the December
--   run-up) does not see its margin fall; the BUY/SOLD column shows
--   the stock build-up separately. Sections 1-3 print whole ringgit,
--   sections 4-5 print cents.
--
-- WHY GROUP BY CATEGORY / NAME AND NOT product_key
--   product_dim is SCD Type 2 (price versions); category and name are
--   identical across versions, so grouping on them rolls the versions
--   together. Same for branch_dim: group on br_ID / br_city.
--
-- REPORT SECTIONS  (each one is ONE OLAP operation)
--   Every title reads "n. PRODUCT GROSS PROFIT BY <level> (RM)" with the
--   scope on the line below it.
--   1  BY STATE      PIVOT       states down, gross profit per year across,
--                                then sales / purchase / GP / margin
--         -> prompt: state
--   2  BY BRANCH     DRILL-DOWN  state -> branch, same layout
--         -> prompt: branch
--   3  BY QUARTER    DRILL-DOWN  year -> quarter: sales, purchase, GP,
--                                margin, GP per quarter across, YoY %
--         -> prompt: year
--   4  BY CATEGORY   DICE        branch x year, categories RANKED by gross
--                                profit, GP per quarter across, markup
--         -> prompt: category
--   5  BY PRODUCT    DRILL-DOWN  category -> product: sales, purchase, GP,
--                                margin, GP per quarter across, units sold
--                                / bought, price vs cost
--
-- WHAT TO LOOK FOR  (defaults: 2019-2025 > Selangor > Petaling Jaya >
--   NOTE: the figures in this block were calibrated BEFORE the dataset
--   was regenerated with satellite towns and the Federal Territory
--   rename (Gombak moved to Selangor). The shapes hold; the exact
--   ringgit and percentages need a re-run to refresh.
--   2025 > Serum, revision-5 data = sales_data5)
--   - Section 1: gross margin is a flat 60 % in every state over the
--     range (supplier cost is 33-43 % of shelf price for every product,
--     less the loyalty / promo discounts on the selling side) - EXCEPT
--     Perak at 42 %: Ipoh buys everything from its Ipoh-only supplier at
--     46-54 % of shelf price (2019-23) and 62-72 % from 2024, so its
--     gross profit collapses from RM 400 k (2023) to 185 k (2024) on
--     only 27 % less sales. Ranking by gross profit = ranking by sales
--     everywhere else: Selangor ~44 % of company GP, Federal Territory of Kuala Lumpur
--     ~30 %. BUY/SOLD 1.13-1.17: the branches buy 13-17 % more units
--     than they sell (safety stock, opening stock, launch stock) - it
--     does not touch the margin, it only shows as stock.
--   - Section 2 (Selangor): the six branches sit within a point of
--     each other (60.0-60.3 %); PJ ~34 % of the state's GP; Subang Jaya
--     (opened 2024) already 5.6 %.
--   - Section 3 (PJ): margin ~60 % every year, 2019 included; Q4 has
--     the biggest gross profit every year (festive quarter), Q3 the
--     smallest; 2020-21 dip with sales; BUY/SOLD 1.18 in 2019 (first
--     year of history = opening stock in the warehouse) settling to 1.10.
--   - Section 4 (PJ 2025): ranking by gross profit = ranking by sales
--     (Face Mask, Serum, Face Cream, Sunscreen ...) because margin is
--     ~59-61 % and MARKUP ~2.5 x for every category - there is no
--     high-margin / low-margin category in this business, only bigger
--     and smaller ones. Realised price / unit cost is where the markup
--     shows: Serum ~RM 99 sold vs ~RM 40 cost.
--   - Section 5 (Serum): the seven serums earn ~59-62 %; differences
--     are supplier-cost noise rather than pricing; UNITS BOUGHT runs a
--     few % above UNITS SOLD; PRICE NOW vs REALISED is the loyalty /
--     promo discount.
--   - Try: Perak > Ipoh > 2024 - the dear-supplier year: margin ~30 %
--     against 60 % everywhere else, same sales mix, same prices - the
--     whole gap is on the COST side; or Negeri Sembilan > Seremban >
--     2024 for an opening year: BUY/SOLD well above 1 (opening stock)
--     while the margin stays ~60 %, which is exactly what costing the
--     units SOLD is for.
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
-- The year range frames sections 1-3 (year columns outside it are
-- hidden, totals / share / growth are computed on the range only).
ACCEPT p_from NUMBER DEFAULT 2019 PROMPT 'Start year (default 2019): '
ACCEPT p_to   NUMBER DEFAULT 2025 PROMPT 'End year   (default 2025): '

-- ---- values reused in every title ---------------------------------
-- TERMOUT OFF hides these helper queries (only works when the file is
-- run with @, which is how this report is meant to be run).
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

-- clamp the range to the data (2019-2025) and put it the right way round
COLUMN f_from NEW_VALUE f_from NOPRINT
COLUMN f_to   NEW_VALUE f_to   NOPRINT
SELECT TO_CHAR(GREATEST(2019, LEAST(&p_from, &p_to)))  AS f_from,
       TO_CHAR(LEAST(2025, GREATEST(&p_from, &p_to)))  AS f_to
FROM   dual;

-- one PRINT / NOPRINT switch per year column, so the pivots in
-- sections 1-2 only show the years inside the range
COLUMN v2019 NEW_VALUE v2019 NOPRINT
COLUMN v2020 NEW_VALUE v2020 NOPRINT
COLUMN v2021 NEW_VALUE v2021 NOPRINT
COLUMN v2022 NEW_VALUE v2022 NOPRINT
COLUMN v2023 NEW_VALUE v2023 NOPRINT
COLUMN v2024 NEW_VALUE v2024 NOPRINT
COLUMN v2025 NEW_VALUE v2025 NOPRINT
SELECT CASE WHEN 2019 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2019,
       CASE WHEN 2020 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2020,
       CASE WHEN 2021 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2021,
       CASE WHEN 2022 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2022,
       CASE WHEN 2023 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2023,
       CASE WHEN 2024 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2024,
       CASE WHEN 2025 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2025
FROM   dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL product_category_margin_output.txt


-- ###################################################################
-- SECTION 1 - PRODUCT GROSS PROFIT BY STATE (years across)
-- OLAP: PIVOT - years of the chosen range across (gross profit per
-- year), states down, whole company; then the range totals: sales,
-- COGS, gross profit, MARGIN %, share of company gross profit and the
-- buy/sold ratio (units bought / units sold, information only).
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. PRODUCT GROSS PROFIT BY STATE (RM)' SKIP 1 -
       CENTER 'ALL BRANCHES, &f_from - &f_to  (PIVOT: GROSS PROFIT PER YEAR ACROSS)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_state   HEADING 'STATE'      FORMAT A19
COLUMN branches   HEADING 'BR'         FORMAT 99
COLUMN y2019      HEADING 'GP 2019'    FORMAT 99,999,990 &v2019
COLUMN y2020      HEADING 'GP 2020'    FORMAT 99,999,990 &v2020
COLUMN y2021      HEADING 'GP 2021'    FORMAT 99,999,990 &v2021
COLUMN y2022      HEADING 'GP 2022'    FORMAT 99,999,990 &v2022
COLUMN y2023      HEADING 'GP 2023'    FORMAT 99,999,990 &v2023
COLUMN y2024      HEADING 'GP 2024'    FORMAT 99,999,990 &v2024
COLUMN y2025      HEADING 'GP 2025'    FORMAT 99,999,990 &v2025
COLUMN sales      HEADING 'SALES|&f_from-&f_to' FORMAT 999,999,990
COLUMN cogs       HEADING 'COGS'       FORMAT 99,999,990
COLUMN gp         HEADING 'GROSS|PROFIT'   FORMAT 99,999,990
COLUMN margin_pct HEADING 'MARGIN|%'   FORMAT 990.0
COLUMN share_pct  HEADING 'SHARE OF|GP %' FORMAT 990.0
COLUMN buy_sold   HEADING 'BUY/|SOLD'  FORMAT 90.00

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF y2019 y2020 y2021 y2022 y2023 y2024 y2025 sales cogs gp ON REPORT

WITH sold AS (
    -- what was sold, at product grain (Completed lines, tax excluded)
    SELECT b.br_state, b.br_ID, d.cal_year, p.product_ID,
           SUM(f.order_qty)                          AS units,
           SUM(f.order_total_amt - f.order_tax_amt)  AS amt
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY b.br_state, b.br_ID, d.cal_year, p.product_ID
),
uc AS (
    -- unit cost actually paid: branch x product x year (purchase cost /
    -- units bought), all years so every sale finds a cost
    SELECT b.br_ID, p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / NULLIF(SUM(f.purchase_qty), 0) AS unit_cost,
           SUM(f.purchase_qty)                                          AS bought
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    GROUP  BY b.br_ID, p.product_ID, d.cal_year
),
ucc AS (
    -- fallback: the company-wide unit cost of the product that year
    SELECT p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / NULLIF(SUM(f.purchase_qty), 0) AS unit_cost
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   product_dim p ON p.product_key = f.product_key
    GROUP  BY p.product_ID, d.cal_year
),
m AS (
    -- COGS = units sold x the unit cost paid for that product
    SELECT s.*, s.units * NVL(u.unit_cost, c.unit_cost) AS cogs
    FROM   sold s
    LEFT   JOIN uc  u ON u.br_ID = s.br_ID AND u.product_ID = s.product_ID AND u.cal_year = s.cal_year
    LEFT   JOIN ucc c ON c.product_ID = s.product_ID AND c.cal_year = s.cal_year
),
bought AS (
    SELECT b.br_state, SUM(f.purchase_qty) AS bought
    FROM   purchase_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY b.br_state
)
SELECT m.br_state,
       COUNT(DISTINCT m.br_ID)                                    AS branches,
       -- no ELSE, so a year the state did not trade prints blank
       SUM(CASE WHEN m.cal_year = 2019 THEN m.amt - m.cogs END)   AS y2019,
       SUM(CASE WHEN m.cal_year = 2020 THEN m.amt - m.cogs END)   AS y2020,
       SUM(CASE WHEN m.cal_year = 2021 THEN m.amt - m.cogs END)   AS y2021,
       SUM(CASE WHEN m.cal_year = 2022 THEN m.amt - m.cogs END)   AS y2022,
       SUM(CASE WHEN m.cal_year = 2023 THEN m.amt - m.cogs END)   AS y2023,
       SUM(CASE WHEN m.cal_year = 2024 THEN m.amt - m.cogs END)   AS y2024,
       SUM(CASE WHEN m.cal_year = 2025 THEN m.amt - m.cogs END)   AS y2025,
       SUM(m.amt)                                                 AS sales,
       SUM(m.cogs)                                                AS cogs,
       SUM(m.amt) - SUM(m.cogs)                                   AS gp,
       ROUND((SUM(m.amt) - SUM(m.cogs)) / NULLIF(SUM(m.amt), 0) * 100, 1)   AS margin_pct,
       ROUND(RATIO_TO_REPORT(SUM(m.amt) - SUM(m.cogs)) OVER () * 100, 1)    AS share_pct,
       ROUND(MAX(bg.bought) / NULLIF(SUM(m.units), 0), 2)         AS buy_sold
FROM   m
LEFT   JOIN bought bg ON bg.br_state = m.br_state
GROUP  BY m.br_state
ORDER  BY gp DESC;

-- ---- prompt 1: which state? (spool paused, helper hidden) ----------
SPOOL OFF
ACCEPT p_state CHAR DEFAULT 'Selangor' PROMPT 'State to open up (default Selangor): '
SET TERMOUT OFF
-- resolve to a real br_state value: name match first, else the biggest
COLUMN f_state NEW_VALUE f_state NOPRINT
SELECT MAX(br_state) KEEP (DENSE_RANK FIRST ORDER BY miss, amt DESC) AS f_state
FROM (
    SELECT b.br_state,
           SUM(f.order_total_amt - f.order_tax_amt) AS amt,
           CASE WHEN UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&p_state')) || '%' THEN 0 ELSE 1 END AS miss
    FROM   order_fact f
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY b.br_state
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL product_category_margin_output.txt APPEND



-- ###################################################################
-- SECTION 2 - PRODUCT GROSS PROFIT BY BRANCH (the chosen state)
-- OLAP: DRILL-DOWN state -> branch, same layout as section 1; SHARE
-- is the branch's share of the state's gross profit.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. PRODUCT GROSS PROFIT BY BRANCH (RM)' SKIP 1 -
       CENTER 'STATE = &f_state, &f_from - &f_to  (DRILL-DOWN STATE -> BRANCH)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city    HEADING 'BRANCH'     FORMAT A15
COLUMN y2019      HEADING 'GP 2019'    FORMAT 99,999,990 &v2019
COLUMN y2020      HEADING 'GP 2020'    FORMAT 99,999,990 &v2020
COLUMN y2021      HEADING 'GP 2021'    FORMAT 99,999,990 &v2021
COLUMN y2022      HEADING 'GP 2022'    FORMAT 99,999,990 &v2022
COLUMN y2023      HEADING 'GP 2023'    FORMAT 99,999,990 &v2023
COLUMN y2024      HEADING 'GP 2024'    FORMAT 99,999,990 &v2024
COLUMN y2025      HEADING 'GP 2025'    FORMAT 99,999,990 &v2025
COLUMN sales      HEADING 'SALES|&f_from-&f_to' FORMAT 99,999,990
COLUMN cogs       HEADING 'COGS'       FORMAT 99,999,990
COLUMN gp         HEADING 'GROSS|PROFIT'   FORMAT 99,999,990
COLUMN margin_pct HEADING 'MARGIN|%'   FORMAT 990.0
COLUMN share_pct  HEADING 'SHARE OF|STATE GP %' FORMAT 990.0
COLUMN buy_sold   HEADING 'BUY/|SOLD'  FORMAT 90.00
COLUMN br_ID      NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'STATE' OF y2019 y2020 y2021 y2022 y2023 y2024 y2025 sales cogs gp ON REPORT

WITH sold AS (
    -- what was sold, at product grain (Completed lines, tax excluded)
    SELECT b.br_ID, b.br_city, d.cal_year, p.product_ID,
           SUM(f.order_qty)                          AS units,
           SUM(f.order_total_amt - f.order_tax_amt)  AS amt
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_state = '&f_state'
    AND    d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY b.br_ID, b.br_city, d.cal_year, p.product_ID
),
uc AS (
    -- unit cost actually paid: branch x product x year (purchase cost /
    -- units bought), all years so every sale finds a cost
    SELECT b.br_ID, p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / NULLIF(SUM(f.purchase_qty), 0) AS unit_cost,
           SUM(f.purchase_qty)                                          AS bought
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    GROUP  BY b.br_ID, p.product_ID, d.cal_year
),
ucc AS (
    -- fallback: the company-wide unit cost of the product that year
    SELECT p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / NULLIF(SUM(f.purchase_qty), 0) AS unit_cost
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   product_dim p ON p.product_key = f.product_key
    GROUP  BY p.product_ID, d.cal_year
),
m AS (
    -- COGS = units sold x the unit cost paid for that product
    SELECT s.*, s.units * NVL(u.unit_cost, c.unit_cost) AS cogs
    FROM   sold s
    LEFT   JOIN uc  u ON u.br_ID = s.br_ID AND u.product_ID = s.product_ID AND u.cal_year = s.cal_year
    LEFT   JOIN ucc c ON c.product_ID = s.product_ID AND c.cal_year = s.cal_year
),
bought AS (
    SELECT b.br_ID, SUM(f.purchase_qty) AS bought
    FROM   purchase_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  b.br_state = '&f_state'
    AND    d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY b.br_ID
)
SELECT m.br_city,
       SUM(CASE WHEN m.cal_year = 2019 THEN m.amt - m.cogs END)   AS y2019,
       SUM(CASE WHEN m.cal_year = 2020 THEN m.amt - m.cogs END)   AS y2020,
       SUM(CASE WHEN m.cal_year = 2021 THEN m.amt - m.cogs END)   AS y2021,
       SUM(CASE WHEN m.cal_year = 2022 THEN m.amt - m.cogs END)   AS y2022,
       SUM(CASE WHEN m.cal_year = 2023 THEN m.amt - m.cogs END)   AS y2023,
       SUM(CASE WHEN m.cal_year = 2024 THEN m.amt - m.cogs END)   AS y2024,
       SUM(CASE WHEN m.cal_year = 2025 THEN m.amt - m.cogs END)   AS y2025,
       SUM(m.amt)                                                 AS sales,
       SUM(m.cogs)                                                AS cogs,
       SUM(m.amt) - SUM(m.cogs)                                   AS gp,
       ROUND((SUM(m.amt) - SUM(m.cogs)) / NULLIF(SUM(m.amt), 0) * 100, 1)   AS margin_pct,
       ROUND(RATIO_TO_REPORT(SUM(m.amt) - SUM(m.cogs)) OVER () * 100, 1)    AS share_pct,
       ROUND(MAX(bg.bought) / NULLIF(SUM(m.units), 0), 2)         AS buy_sold,
       m.br_ID
FROM   m
LEFT   JOIN bought bg ON bg.br_ID = m.br_ID
GROUP  BY m.br_ID, m.br_city
ORDER  BY gp DESC;

-- ---- prompt 2: which branch? ---------------------------------------
SPOOL OFF
ACCEPT p_branch CHAR DEFAULT 'Petaling Jaya' PROMPT 'Branch to open up (default Petaling Jaya): '
SET TERMOUT OFF
-- resolve inside the chosen state: name match first, else the biggest
COLUMN f_br_id   NEW_VALUE f_br_id   NOPRINT
COLUMN f_branch  NEW_VALUE f_branch  NOPRINT
SELECT TO_CHAR(MAX(br_ID) KEEP (DENSE_RANK FIRST ORDER BY miss, amt DESC)) AS f_br_id,
       MAX(br_city)       KEEP (DENSE_RANK FIRST ORDER BY miss, amt DESC)  AS f_branch
FROM (
    SELECT b.br_ID, b.br_city,
           SUM(f.order_total_amt - f.order_tax_amt) AS amt,
           CASE WHEN UPPER(b.br_city) LIKE '%' || UPPER(TRIM('&p_branch')) || '%' THEN 0 ELSE 1 END AS miss
    FROM   order_fact f
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_state = '&f_state'
    GROUP  BY b.br_ID, b.br_city
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL product_category_margin_output.txt APPEND



-- ###################################################################
-- SECTION 3 - PRODUCT GROSS PROFIT BY QUARTER (the chosen branch)
-- OLAP: DRILL-DOWN year -> quarter for one branch: the year's sales,
-- COGS, gross profit and margin, then the gross profit of each
-- quarter across, the best quarter and the year-on-year change in
-- gross profit.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. PRODUCT GROSS PROFIT BY QUARTER (RM)' SKIP 1 -
       CENTER 'BRANCH = &f_branch, &f_from - &f_to  (DRILL-DOWN YEAR -> QUARTER)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year   HEADING 'YEAR'       FORMAT 9999
-- one digit wider than a year needs: the ALL row is eight years
COLUMN sales      HEADING 'SALES'      FORMAT 99,999,990
COLUMN cogs       HEADING 'COGS'       FORMAT 99,999,990
COLUMN gp         HEADING 'GROSS|PROFIT'  FORMAT 99,999,990
COLUMN margin_pct HEADING 'MARGIN|%'   FORMAT 990.0
COLUMN q1         HEADING 'GP Q1'      FORMAT 9,999,990
COLUMN q2         HEADING 'GP Q2'      FORMAT 9,999,990
COLUMN q3         HEADING 'GP Q3'      FORMAT 9,999,990
COLUMN q4         HEADING 'GP Q4'      FORMAT 9,999,990
COLUMN best_q     HEADING 'BEST|QTR'   FORMAT A4
COLUMN yoy_pct    HEADING 'GP|YOY %'   FORMAT S9,990.0
COLUMN buy_sold   HEADING 'BUY/|SOLD'  FORMAT 90.00

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF sales cogs gp q1 q2 q3 q4 ON REPORT

WITH sold AS (
    -- what was sold, at product grain (Completed lines, tax excluded)
    SELECT b.br_ID, d.cal_year, d.cal_quarter, p.product_ID,
           SUM(f.order_qty)                          AS units,
           SUM(f.order_total_amt - f.order_tax_amt)  AS amt
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY b.br_ID, d.cal_year, d.cal_quarter, p.product_ID
),
uc AS (
    -- unit cost actually paid: branch x product x year (purchase cost /
    -- units bought), all years so every sale finds a cost
    SELECT b.br_ID, p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / NULLIF(SUM(f.purchase_qty), 0) AS unit_cost,
           SUM(f.purchase_qty)                                          AS bought
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    GROUP  BY b.br_ID, p.product_ID, d.cal_year
),
ucc AS (
    -- fallback: the company-wide unit cost of the product that year
    SELECT p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / NULLIF(SUM(f.purchase_qty), 0) AS unit_cost
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   product_dim p ON p.product_key = f.product_key
    GROUP  BY p.product_ID, d.cal_year
),
m AS (
    -- COGS = units sold x the unit cost paid for that product
    SELECT s.*, s.units * NVL(u.unit_cost, c.unit_cost) AS cogs
    FROM   sold s
    LEFT   JOIN uc  u ON u.br_ID = s.br_ID AND u.product_ID = s.product_ID AND u.cal_year = s.cal_year
    LEFT   JOIN ucc c ON c.product_ID = s.product_ID AND c.cal_year = s.cal_year
),
bought AS (
    SELECT d.cal_year, SUM(f.purchase_qty) AS bought
    FROM   purchase_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  b.br_ID = &f_br_id
    AND    d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY d.cal_year
),
yr AS (
    SELECT m.cal_year,
           SUM(m.amt) AS sales, SUM(m.cogs) AS cogs, SUM(m.amt) - SUM(m.cogs) AS gp,
           SUM(CASE WHEN m.cal_quarter = 1 THEN m.amt - m.cogs END) AS q1,
           SUM(CASE WHEN m.cal_quarter = 2 THEN m.amt - m.cogs END) AS q2,
           SUM(CASE WHEN m.cal_quarter = 3 THEN m.amt - m.cogs END) AS q3,
           SUM(CASE WHEN m.cal_quarter = 4 THEN m.amt - m.cogs END) AS q4,
           SUM(m.units) AS units
    FROM   m
    GROUP  BY m.cal_year
),
qbest AS (
    SELECT cal_year, 'Q' || MAX(cal_quarter) KEEP (DENSE_RANK FIRST ORDER BY gpq DESC) AS best_q
    FROM   (SELECT cal_year, cal_quarter, SUM(amt - cogs) AS gpq FROM m GROUP BY cal_year, cal_quarter)
    GROUP  BY cal_year
)
SELECT y.cal_year, y.sales, y.cogs, y.gp,
       ROUND(y.gp / NULLIF(y.sales, 0) * 100, 1)                              AS margin_pct,
       y.q1, y.q2, y.q3, y.q4, qb.best_q,
       ROUND((y.gp / NULLIF(LAG(y.gp) OVER (ORDER BY y.cal_year), 0) - 1) * 100, 1) AS yoy_pct,
       ROUND(bg.bought / NULLIF(y.units, 0), 2)                               AS buy_sold
FROM   yr y
LEFT   JOIN qbest  qb ON qb.cal_year = y.cal_year
LEFT   JOIN bought bg ON bg.cal_year = y.cal_year
ORDER  BY y.cal_year;

-- ---- prompt 3: which year? -----------------------------------------
SPOOL OFF
ACCEPT p_year NUMBER DEFAULT &f_to PROMPT 'Year to open up (default &f_to): '
SET TERMOUT OFF
COLUMN f_year NEW_VALUE f_year NOPRINT
SELECT TO_CHAR(GREATEST(&f_from, LEAST(&f_to, &p_year))) AS f_year FROM dual;
CLEAR COLUMNS
SET TERMOUT ON
SPOOL product_category_margin_output.txt APPEND



-- ###################################################################
-- SECTION 4 - PRODUCT GROSS PROFIT BY CATEGORY (the chosen branch-year)
-- OLAP: DICE (branch x year), categories down RANKED by gross profit,
-- gross profit per quarter across; MARGIN %, share of the year's
-- gross profit, buy/sold, and the MARKUP (realised selling price over
-- the unit cost paid). Pick a category from this list next.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. PRODUCT GROSS PROFIT BY CATEGORY (RM)' SKIP 1 -
       CENTER 'BRANCH = &f_branch, YEAR = &f_year  (DICE, CATEGORIES RANKED BY GROSS PROFIT, QUARTERS ACROSS)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk        HEADING 'RANK'       FORMAT 99
COLUMN product_category HEADING 'CATEGORY' FORMAT A19
COLUMN sales      HEADING 'SALES (RM)' FORMAT 9,999,990.00
COLUMN cogs       HEADING 'COGS (RM)'  FORMAT 9,999,990.00
COLUMN gp         HEADING 'GROSS|PROFIT (RM)' FORMAT 9,999,990.00
COLUMN margin_pct HEADING 'MARGIN|%'   FORMAT 990.0
COLUMN share_pct  HEADING 'SHARE OF|GP %' FORMAT 990.0
COLUMN q1         HEADING 'GP Q1'      FORMAT 999,990
COLUMN q2         HEADING 'GP Q2'      FORMAT 999,990
COLUMN q3         HEADING 'GP Q3'      FORMAT 999,990
COLUMN q4         HEADING 'GP Q4'      FORMAT 999,990
COLUMN buy_sold   HEADING 'BUY/|SOLD'  FORMAT 90.00
COLUMN avg_price  HEADING 'REALISED|PRICE' FORMAT 9,990.00
COLUMN unit_cost  HEADING 'UNIT|COST'  FORMAT 9,990.00
COLUMN markup     HEADING 'MARK|UP x'  FORMAT 90.00

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF sales cogs gp q1 q2 q3 q4 ON REPORT

WITH sold AS (
    -- what was sold, at product grain (Completed lines, tax excluded)
    SELECT b.br_ID, p.product_category, d.cal_year, d.cal_quarter, p.product_ID,
           SUM(f.order_qty)                          AS units,
           SUM(f.order_total_amt - f.order_tax_amt)  AS amt
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    GROUP  BY b.br_ID, p.product_category, d.cal_year, d.cal_quarter, p.product_ID
),
uc AS (
    -- unit cost actually paid: branch x product x year (purchase cost /
    -- units bought), all years so every sale finds a cost
    SELECT b.br_ID, p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / NULLIF(SUM(f.purchase_qty), 0) AS unit_cost,
           SUM(f.purchase_qty)                                          AS bought
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    GROUP  BY b.br_ID, p.product_ID, d.cal_year
),
ucc AS (
    -- fallback: the company-wide unit cost of the product that year
    SELECT p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / NULLIF(SUM(f.purchase_qty), 0) AS unit_cost
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   product_dim p ON p.product_key = f.product_key
    GROUP  BY p.product_ID, d.cal_year
),
m AS (
    -- COGS = units sold x the unit cost paid for that product
    SELECT s.*, s.units * NVL(u.unit_cost, c.unit_cost) AS cogs
    FROM   sold s
    LEFT   JOIN uc  u ON u.br_ID = s.br_ID AND u.product_ID = s.product_ID AND u.cal_year = s.cal_year
    LEFT   JOIN ucc c ON c.product_ID = s.product_ID AND c.cal_year = s.cal_year
),
bought AS (
    SELECT p.product_category, SUM(f.purchase_qty) AS bought
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    GROUP  BY p.product_category
)
SELECT RANK() OVER (ORDER BY SUM(m.amt) - SUM(m.cogs) DESC)      AS rnk,
       m.product_category,
       SUM(m.amt)                                                AS sales,
       SUM(m.cogs)                                               AS cogs,
       SUM(m.amt) - SUM(m.cogs)                                  AS gp,
       ROUND((SUM(m.amt) - SUM(m.cogs)) / NULLIF(SUM(m.amt), 0) * 100, 1)   AS margin_pct,
       ROUND(RATIO_TO_REPORT(SUM(m.amt) - SUM(m.cogs)) OVER () * 100, 1)    AS share_pct,
       SUM(CASE WHEN m.cal_quarter = 1 THEN m.amt - m.cogs END)  AS q1,
       SUM(CASE WHEN m.cal_quarter = 2 THEN m.amt - m.cogs END)  AS q2,
       SUM(CASE WHEN m.cal_quarter = 3 THEN m.amt - m.cogs END)  AS q3,
       SUM(CASE WHEN m.cal_quarter = 4 THEN m.amt - m.cogs END)  AS q4,
       ROUND(MAX(bg.bought) / NULLIF(SUM(m.units), 0), 2)        AS buy_sold,
       ROUND(SUM(m.amt)  / NULLIF(SUM(m.units), 0), 2)           AS avg_price,
       ROUND(SUM(m.cogs) / NULLIF(SUM(m.units), 0), 2)           AS unit_cost,
       ROUND(SUM(m.amt) / NULLIF(SUM(m.cogs), 0), 2)             AS markup
FROM   m
LEFT   JOIN bought bg ON bg.product_category = m.product_category
GROUP  BY m.product_category
ORDER  BY rnk;

-- ---- prompt 4: which category? -------------------------------------
SPOOL OFF
ACCEPT p_cat CHAR DEFAULT 'Serum' PROMPT 'Product category to open up (default Serum): '
SET TERMOUT OFF
-- resolve inside this branch-year: name match first, else the biggest
-- (by sales - the same rule as the other levels)
COLUMN f_cat NEW_VALUE f_cat NOPRINT
SELECT MAX(product_category) KEEP (DENSE_RANK FIRST ORDER BY miss, amt DESC) AS f_cat
FROM (
    SELECT p.product_category,
           SUM(f.order_total_amt - f.order_tax_amt) AS amt,
           CASE WHEN UPPER(p.product_category) LIKE '%' || UPPER(TRIM('&p_cat')) || '%' THEN 0 ELSE 1 END AS miss
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    GROUP  BY p.product_category
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL product_category_margin_output.txt APPEND



-- ###################################################################
-- SECTION 5 - PRODUCT GROSS PROFIT BY PRODUCT (the chosen category)
-- OLAP: DRILL-DOWN category -> product for the chosen branch and
-- year: sales, COGS, gross profit, margin, share of the category's
-- gross profit, gross profit per quarter across, units sold vs
-- bought, realised price vs unit cost (markup) and the current list
-- price.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. PRODUCT GROSS PROFIT BY PRODUCT (RM)' SKIP 1 -
       CENTER 'BRANCH = &f_branch, YEAR = &f_year, CATEGORY = &f_cat  (DRILL-DOWN CATEGORY -> PRODUCT)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk          HEADING 'RANK'      FORMAT 99
COLUMN product_name HEADING 'PRODUCT'   FORMAT A32
COLUMN sales        HEADING 'SALES (RM)' FORMAT 9,999,990.00
COLUMN cogs         HEADING 'COGS (RM)' FORMAT 9,999,990.00
COLUMN gp           HEADING 'GROSS|PROFIT (RM)' FORMAT 9,999,990.00
COLUMN margin_pct   HEADING 'MARGIN|%'  FORMAT 990.0
COLUMN share_pct    HEADING 'SHARE OF|CAT GP %' FORMAT 990.0
COLUMN q1           HEADING 'GP Q1'     FORMAT 999,990
COLUMN q2           HEADING 'GP Q2'     FORMAT 999,990
COLUMN q3           HEADING 'GP Q3'     FORMAT 999,990
COLUMN q4           HEADING 'GP Q4'     FORMAT 999,990
COLUMN units        HEADING 'UNITS|SOLD' FORMAT 99,990
COLUMN bought       HEADING 'UNITS|BOUGHT' FORMAT 99,990
COLUMN avg_price    HEADING 'REALISED|PRICE' FORMAT 9,990.00
COLUMN unit_cost    HEADING 'UNIT|COST'  FORMAT 9,990.00
COLUMN markup       HEADING 'MARK|UP x'  FORMAT 90.00
COLUMN list_price   HEADING 'PRICE NOW|(RM)' FORMAT 9,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF sales cogs gp q1 q2 q3 q4 units bought ON REPORT

WITH sold AS (
    -- what was sold, at product grain (Completed lines, tax excluded)
    SELECT b.br_ID, p.product_name, d.cal_year, d.cal_quarter, p.product_ID,
           SUM(f.order_qty)                          AS units,
           SUM(f.order_total_amt - f.order_tax_amt)  AS amt
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    AND    p.product_category = '&f_cat'
    GROUP  BY b.br_ID, p.product_name, d.cal_year, d.cal_quarter, p.product_ID
),
uc AS (
    -- unit cost actually paid: branch x product x year (purchase cost /
    -- units bought), all years so every sale finds a cost
    SELECT b.br_ID, p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / NULLIF(SUM(f.purchase_qty), 0) AS unit_cost,
           SUM(f.purchase_qty)                                          AS bought
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    GROUP  BY b.br_ID, p.product_ID, d.cal_year
),
ucc AS (
    -- fallback: the company-wide unit cost of the product that year
    SELECT p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / NULLIF(SUM(f.purchase_qty), 0) AS unit_cost
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   product_dim p ON p.product_key = f.product_key
    GROUP  BY p.product_ID, d.cal_year
),
m AS (
    -- COGS = units sold x the unit cost paid for that product
    SELECT s.*, s.units * NVL(u.unit_cost, c.unit_cost) AS cogs
    FROM   sold s
    LEFT   JOIN uc  u ON u.br_ID = s.br_ID AND u.product_ID = s.product_ID AND u.cal_year = s.cal_year
    LEFT   JOIN ucc c ON c.product_ID = s.product_ID AND c.cal_year = s.cal_year
),
bought AS (
    SELECT p.product_ID, SUM(f.purchase_qty) AS bought
    FROM   purchase_fact f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    GROUP  BY p.product_ID
),
cur_price AS (
    SELECT product_ID, product_unit_price
    FROM   product_dim WHERE is_current_flag = 'Y'
)
SELECT RANK() OVER (ORDER BY SUM(m.amt) - SUM(m.cogs) DESC)      AS rnk,
       m.product_name,
       SUM(m.amt)                                                AS sales,
       SUM(m.cogs)                                               AS cogs,
       SUM(m.amt) - SUM(m.cogs)                                  AS gp,
       ROUND((SUM(m.amt) - SUM(m.cogs)) / NULLIF(SUM(m.amt), 0) * 100, 1)   AS margin_pct,
       ROUND(RATIO_TO_REPORT(SUM(m.amt) - SUM(m.cogs)) OVER () * 100, 1)    AS share_pct,
       SUM(CASE WHEN m.cal_quarter = 1 THEN m.amt - m.cogs END)  AS q1,
       SUM(CASE WHEN m.cal_quarter = 2 THEN m.amt - m.cogs END)  AS q2,
       SUM(CASE WHEN m.cal_quarter = 3 THEN m.amt - m.cogs END)  AS q3,
       SUM(CASE WHEN m.cal_quarter = 4 THEN m.amt - m.cogs END)  AS q4,
       SUM(m.units)                                              AS units,
       MAX(bg.bought)                                            AS bought,
       ROUND(SUM(m.amt)  / NULLIF(SUM(m.units), 0), 2)           AS avg_price,
       ROUND(SUM(m.cogs) / NULLIF(SUM(m.units), 0), 2)           AS unit_cost,
       ROUND(SUM(m.amt) / NULLIF(SUM(m.cogs), 0), 2)             AS markup,
       MAX(c.product_unit_price)                                 AS list_price
FROM   m
LEFT   JOIN bought    bg ON bg.product_ID = m.product_ID
LEFT   JOIN cur_price c  ON c.product_ID  = m.product_ID
GROUP  BY m.product_ID, m.product_name
ORDER  BY rnk;

PROMPT
PROMPT +==========================================================+
PROMPT |     END OF PRODUCT GROSS PROFIT DRILL-DOWN REPORT        |
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
UNDEFINE f_from
UNDEFINE f_to
UNDEFINE v2019
UNDEFINE v2020
UNDEFINE v2021
UNDEFINE v2022
UNDEFINE v2023
UNDEFINE v2024
UNDEFINE v2025
UNDEFINE p_state
UNDEFINE p_branch
UNDEFINE p_year
UNDEFINE p_cat
UNDEFINE f_state
UNDEFINE f_br_id
UNDEFINE f_branch
UNDEFINE f_year
UNDEFINE f_cat
UNDEFINE run_dt
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
