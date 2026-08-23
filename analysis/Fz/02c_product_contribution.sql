-- ===================================================================
-- 02c_product_contribution.sql
-- GLOW BEAUTY - PRODUCT PROFIT: WHERE IT IS EARNED AND WHAT TO DO
--
-- THE DRILL PATH  (each section is one OLAP step and opens the next)
--   1. STATE     every state, total and average per year, ranked on
--                average sales per year
--   2. BRANCH    the branches inside the state you pick, ranked on
--                average gross profit per year
--   3. YEAR      that branch year by year
--   4. CATEGORY  the categories of the branch-year you pick, ranked,
--                with the four quarters pivoted across
--   5. PRODUCT   the products inside the category you pick, quarters
--                across as well
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\02c_product_contribution.sql
--
-- PARAMETERS (prompted in drill order; every one carries a DEFAULT)
--   start year / end year   the analysis period (data runs 2019-2025)
--   state                   opens section 2    (default Selangor)
--   branch                  opens sections 3-5 (default Petaling Jaya)
--   year                    opens sections 4-5 (default the end year)
--   category                opens section 6    (default Serum)
--
-- This report covers PRODUCT sales only (order_fact). Service revenue
-- has no product dimension and no cost of goods, so it is out of scope
-- here - see 01_branch_profitability.sql for the whole-branch picture.
--
-- ===================================================================
-- HOW COST IS CALCULATED  (read this before quoting a margin)
-- ===================================================================
-- purchase_fact holds stock BOUGHT, not stock SOLD - 2,347,033 units
-- were bought against 2,065,740 sold, so summing purchase_total_cost
-- against revenue overstates cost by ~14 % and swings with restocking
-- timing. This report prices the units actually sold instead:
--
--   unit_cost(product, branch, year)
--       = SUM(purchase_total_cost) / SUM(purchase_qty)   from purchase_fact
--   COGS = SUM(units sold x unit_cost)   matched product + branch + year,
--          falling back to the chain's product-year cost when a branch
--          sold a SKU in a year it did not restock it
--   Gross profit = order_net_amt - COGS
--   Revenue      = order_net_amt: already net of discount, and excludes
--                  the 6 % SST, which belongs to the government
--
-- Why that grain:
--   per YEAR   - a product's unit cost moves up to 31 % between years
--                (product 4: RM 16.11 -> RM 21.13), so one period-wide
--                average would price 2019 sales at 2025 costs
--   per BRANCH - Ipoh pays RM 31.67 a unit (59.2 % of shelf) against
--                RM 20.39 (38.0 %) everywhere else; a chain average
--                would smear its dear supplier over every product
--
-- ===================================================================
-- WHY THE RANKING IS ON PROFIT IN RINGGIT, NOT ON MARGIN %
-- ===================================================================
-- Gross margin % is FLAT across the whole range: all 56 products fall
-- between 58.03 % and 59.26 %, a spread of 1.22 points with a standard
-- deviation of 0.21. Every product is bought at the same share of its
-- shelf price, so no product is inherently richer than another and a
-- margin ranking would be sorting noise. Gross profit in RINGGIT is
-- where products differ - 13.6x between smallest and largest - and it
-- is volume that drives it. The GP % column is printed anyway, so the
-- flatness is visible rather than hidden - a product low down the
-- ranking is a low-VOLUME line, never a low-margin one.
--
-- OLAP TECHNIQUES USED
--   CTE (WITH)         every section
--   CASE WHEN          the cost fallback
--   RANK               sections 1, 2, 4, 5
--   PIVOT              sections 4, 5 - quarters across the page
--   COMPUTE AVG        the average row under each table
-- ===================================================================

-- reset anything a previous script left behind in this session
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 132
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

PROMPT
ACCEPT p_from CHAR DEFAULT 2019 PROMPT 'Start year (default 2019): '
ACCEPT p_to   CHAR DEFAULT 2025 PROMPT 'End year   (default 2025): '
PROMPT


-- ###################################################################
-- SECTION 1 - STATE: TOTAL AND AVERAGE PER YEAR
-- Every money column is shown twice: the period total, and that total
-- divided by the years the state actually traded. The BR column is
-- there because states hold very different numbers of shops - Selangor
-- has seven - so a total is not comparable between them on its own.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. PRODUCT SALES AND PROFIT BY STATE' SKIP 1 -
       CENTER 'TOTAL AND AVERAGE PER YEAR, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk       HEADING 'RANK'               FORMAT 990
COLUMN br_state  HEADING 'STATE'              FORMAT A17
COLUMN brs       HEADING 'BR'                 FORMAT 90
COLUMN yrs       HEADING 'YRS'                FORMAT 90
COLUMN sales     HEADING 'TOTAL SALES|(RM)'   FORMAT 99,999,990
COLUMN sales_yr  HEADING 'AVG SALES|PER YEAR' FORMAT 9,999,990
COLUMN cogs      HEADING 'TOTAL COGS|(RM)'    FORMAT 99,999,990
COLUMN cogs_yr   HEADING 'AVG COGS|PER YEAR'  FORMAT 9,999,990
COLUMN gp        HEADING 'TOTAL GROSS|PROFIT (RM)' FORMAT S99,999,990
COLUMN gp_yr     HEADING 'AVG GP|PER YEAR'    FORMAT S9,999,990
COLUMN gpm       HEADING 'GP|%'               FORMAT 990.9

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF sales sales_yr cogs cogs_yr gp gp_yr ON REPORT

WITH cby AS (
    SELECT p.product_ID, b.br_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, b.br_ID, d.cal_year
),
cy AS (
    SELECT p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, d.cal_year
),
line AS (
    SELECT b.br_state, b.br_ID, d.cal_year, p.product_ID,
           SUM(f.order_qty) AS units, SUM(f.order_net_amt) AS rev
    FROM   order_fact  f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    GROUP  BY b.br_state, b.br_ID, d.cal_year, p.product_ID
),
costed AS (
    SELECT l.br_state, l.br_ID, l.cal_year, l.rev,
           l.units * NVL(cby.ucost, cy.ucost) AS cogs
    FROM   line l
    LEFT   JOIN cby ON cby.product_ID = l.product_ID
                   AND cby.br_ID      = l.br_ID
                   AND cby.cal_year   = l.cal_year
    LEFT   JOIN cy  ON cy.product_ID  = l.product_ID
                   AND cy.cal_year    = l.cal_year
)
SELECT RANK() OVER (ORDER BY SUM(rev) / COUNT(DISTINCT cal_year) DESC) AS rnk,
       -- the full label is 33 characters and would wrap the row in two
       CASE WHEN br_state = 'Federal Territory of Kuala Lumpur'
            THEN 'FT Kuala Lumpur' ELSE br_state END AS br_state,
       COUNT(DISTINCT br_ID)                     AS brs,
       COUNT(DISTINCT cal_year)                  AS yrs,
       SUM(rev)                                  AS sales,
       SUM(rev)  / COUNT(DISTINCT cal_year)      AS sales_yr,
       SUM(cogs)                                 AS cogs,
       SUM(cogs) / COUNT(DISTINCT cal_year)      AS cogs_yr,
       SUM(rev) - SUM(cogs)                      AS gp,
       (SUM(rev) - SUM(cogs)) / COUNT(DISTINCT cal_year) AS gp_yr,
       (SUM(rev) - SUM(cogs)) / NULLIF(SUM(rev), 0) * 100 AS gpm
FROM   costed
GROUP  BY br_state
ORDER  BY rnk;


-- ###################################################################
-- SECTION 2 - BRANCH: INSIDE THE STATE YOU PICKED
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_state CHAR DEFAULT 'Selangor' PROMPT 'State to open up (default Selangor): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. BRANCHES IN &p_state' SKIP 1 -
       CENTER 'PRODUCT SALES AND PROFIT, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk      HEADING 'RANK'               FORMAT 990
COLUMN br_city  HEADING 'BRANCH'             FORMAT A18
COLUMN yrs      HEADING 'YRS'                FORMAT 90
COLUMN sales    HEADING 'TOTAL SALES|(RM)'   FORMAT 99,999,990
COLUMN sales_yr HEADING 'AVG SALES|PER YEAR' FORMAT 9,999,990
COLUMN cogs     HEADING 'TOTAL COGS|(RM)'    FORMAT 9,999,990
COLUMN cogs_yr  HEADING 'AVG COGS|PER YEAR'  FORMAT 9,999,990
COLUMN gp       HEADING 'TOTAL GROSS|PROFIT (RM)' FORMAT S9,999,990
COLUMN gp_yr    HEADING 'AVG GP|PER YEAR'    FORMAT S9,999,990
COLUMN gpm      HEADING 'GP|%'               FORMAT 990.9

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF sales sales_yr cogs cogs_yr gp gp_yr ON REPORT

WITH cby AS (
    SELECT p.product_ID, b.br_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, b.br_ID, d.cal_year
),
cy AS (
    SELECT p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, d.cal_year
),
line AS (
    SELECT b.br_city, b.br_ID, d.cal_year, p.product_ID,
           SUM(f.order_qty) AS units, SUM(f.order_net_amt) AS rev
    FROM   order_fact  f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    WHERE  f.order_status = 'Completed'
    AND    UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&p_state')) || '%'
    AND    d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    GROUP  BY b.br_city, b.br_ID, d.cal_year, p.product_ID
),
costed AS (
    SELECT l.br_city, l.cal_year, l.units, l.rev,
           l.units * NVL(cby.ucost, cy.ucost) AS cogs
    FROM   line l
    LEFT   JOIN cby ON cby.product_ID = l.product_ID
                   AND cby.br_ID      = l.br_ID
                   AND cby.cal_year   = l.cal_year
    LEFT   JOIN cy  ON cy.product_ID  = l.product_ID
                   AND cy.cal_year    = l.cal_year
)
SELECT RANK() OVER (ORDER BY (SUM(rev) - SUM(cogs))
                              / COUNT(DISTINCT cal_year) DESC) AS rnk,
       br_city,
       COUNT(DISTINCT cal_year)                  AS yrs,
       SUM(rev)                                  AS sales,
       SUM(rev)  / COUNT(DISTINCT cal_year)      AS sales_yr,
       SUM(cogs)                                 AS cogs,
       SUM(cogs) / COUNT(DISTINCT cal_year)      AS cogs_yr,
       SUM(rev) - SUM(cogs)                      AS gp,
       (SUM(rev) - SUM(cogs)) / COUNT(DISTINCT cal_year) AS gp_yr,
       (SUM(rev) - SUM(cogs)) / NULLIF(SUM(rev), 0) * 100 AS gpm
FROM   costed
GROUP  BY br_city
ORDER  BY rnk;


-- ###################################################################
-- SECTION 3 - YEAR: THE BRANCH YOU PICKED, YEAR BY YEAR
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_branch CHAR DEFAULT 'Petaling Jaya' PROMPT 'Branch to open up (default Petaling Jaya): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. &p_branch YEAR BY YEAR' SKIP 1 -
       CENTER 'PRODUCT SALES AND PROFIT, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year HEADING 'YEAR'               FORMAT 9999
COLUMN units    HEADING 'UNITS|SOLD'         FORMAT 999,990
COLUMN aprice   HEADING 'AVG PRICE|GOT (RM)' FORMAT 990.99
COLUMN sales    HEADING 'ORDER SALES|(RM)'   FORMAT 9,999,990
COLUMN cogs     HEADING 'COGS|(RM)'          FORMAT 9,999,990
COLUMN gp       HEADING 'GROSS|PROFIT (RM)'  FORMAT S9,999,990
COLUMN gpm      HEADING 'GP|%'               FORMAT 990.9

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG/YEAR' OF units sales cogs gp ON REPORT

WITH cby AS (
    SELECT p.product_ID, b.br_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, b.br_ID, d.cal_year
),
cy AS (
    SELECT p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, d.cal_year
),
line AS (
    SELECT b.br_ID, d.cal_year, p.product_ID,
           SUM(f.order_qty) AS units, SUM(f.order_net_amt) AS rev
    FROM   order_fact  f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    WHERE  f.order_status = 'Completed'
    AND    UPPER(b.br_city) = UPPER(TRIM('&p_branch'))
    AND    d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    GROUP  BY b.br_ID, d.cal_year, p.product_ID
),
costed AS (
    SELECT l.cal_year, l.units, l.rev,
           l.units * NVL(cby.ucost, cy.ucost) AS cogs
    FROM   line l
    LEFT   JOIN cby ON cby.product_ID = l.product_ID
                   AND cby.br_ID      = l.br_ID
                   AND cby.cal_year   = l.cal_year
    LEFT   JOIN cy  ON cy.product_ID  = l.product_ID
                   AND cy.cal_year    = l.cal_year
)
SELECT cal_year,
       SUM(units)                            AS units,
       SUM(rev) / NULLIF(SUM(units), 0)      AS aprice,
       SUM(rev)                              AS sales,
       SUM(cogs)                             AS cogs,
       SUM(rev) - SUM(cogs)                  AS gp,
       (SUM(rev) - SUM(cogs)) / NULLIF(SUM(rev), 0) * 100 AS gpm
FROM   costed
GROUP  BY cal_year
ORDER  BY cal_year;


-- ###################################################################
-- SECTION 4 - CATEGORY: RANKED, WITH THE QUARTERS ACROSS
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_year CHAR DEFAULT '&p_to' PROMPT 'Year to open up (default the end year): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. CATEGORIES AT &p_branch IN &p_year' SKIP 1 -
       CENTER 'GROSS PROFIT (RM) BY QUARTER, RANKED ON THE YEAR' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk      HEADING 'RANK'              FORMAT 990
COLUMN cat      HEADING 'CATEGORY'          FORMAT A20
COLUMN skus     HEADING 'SKUS'              FORMAT 990
COLUMN q1       HEADING 'Q1 GP|(RM)'        FORMAT 999,990
COLUMN q2       HEADING 'Q2 GP|(RM)'        FORMAT 999,990
COLUMN q3       HEADING 'Q3 GP|(RM)'        FORMAT 999,990
COLUMN q4       HEADING 'Q4 GP|(RM)'        FORMAT 999,990
COLUMN gp       HEADING 'YEAR GROSS|PROFIT (RM)' FORMAT S9,999,990
COLUMN gpm      HEADING 'GP|%'              FORMAT 990.9

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF q1 q2 q3 q4 gp ON REPORT

WITH cby AS (
    SELECT p.product_ID, b.br_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, b.br_ID, d.cal_year
),
cy AS (
    SELECT p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, d.cal_year
),
line AS (
    SELECT p.product_category, p.product_ID, b.br_ID, d.cal_year, d.cal_quarter,
           SUM(f.order_qty) AS units, SUM(f.order_net_amt) AS rev
    FROM   order_fact  f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    WHERE  f.order_status = 'Completed'
    AND    UPPER(b.br_city) = UPPER(TRIM('&p_branch'))
    AND    d.cal_year = TO_NUMBER('&p_year')
    GROUP  BY p.product_category, p.product_ID, b.br_ID, d.cal_year, d.cal_quarter
),
costed AS (
    SELECT l.product_category, l.product_ID, l.cal_quarter, l.units, l.rev,
           l.units * NVL(cby.ucost, cy.ucost) AS cogs
    FROM   line l
    LEFT   JOIN cby ON cby.product_ID = l.product_ID
                   AND cby.br_ID      = l.br_ID
                   AND cby.cal_year   = l.cal_year
    LEFT   JOIN cy  ON cy.product_ID  = l.product_ID
                   AND cy.cal_year    = l.cal_year
),
piv AS (
    -- the four quarters become columns
    SELECT * FROM (SELECT product_category AS cat, cal_quarter,
                          rev - cogs AS gp
                   FROM   costed)
    PIVOT (SUM(gp) FOR cal_quarter IN (1 AS q1, 2 AS q2, 3 AS q3, 4 AS q4))
),
bycat AS (
    -- the year total that the ranking is built on
    SELECT product_category AS cat,
           COUNT(DISTINCT product_ID) AS skus,
           SUM(rev)   AS sales,
           SUM(rev) - SUM(cogs) AS gp
    FROM   costed
    GROUP  BY product_category
)
SELECT RANK() OVER (ORDER BY b.gp DESC) AS rnk,
       b.cat, b.skus,
       NVL(p.q1, 0) AS q1, NVL(p.q2, 0) AS q2,
       NVL(p.q3, 0) AS q3, NVL(p.q4, 0) AS q4,
       b.gp,
       b.gp / NULLIF(b.sales, 0) * 100 AS gpm
FROM   bycat b
JOIN   piv   p ON p.cat = b.cat
ORDER  BY rnk;


-- ###################################################################
-- SECTION 5 - PRODUCT: INSIDE THE CATEGORY YOU PICKED
-- The end of the drill: every product on this shelf, ranked on the
-- gross profit it earned over the year, with the quarters beside it.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_cat CHAR DEFAULT 'Serum' PROMPT 'Category to open up (default Serum): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. &p_cat PRODUCTS AT &p_branch IN &p_year' SKIP 1 -
       CENTER 'GROSS PROFIT (RM) BY QUARTER, RANKED ON THE YEAR' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk      HEADING 'RANK'              FORMAT 990
COLUMN pname    HEADING 'PRODUCT'           FORMAT A43
COLUMN q1       HEADING 'Q1 GP|(RM)'        FORMAT 99,990
COLUMN q2       HEADING 'Q2 GP|(RM)'        FORMAT 99,990
COLUMN q3       HEADING 'Q3 GP|(RM)'        FORMAT 99,990
COLUMN q4       HEADING 'Q4 GP|(RM)'        FORMAT 99,990
COLUMN gp       HEADING 'YEAR GROSS|PROFIT (RM)' FORMAT S999,990
COLUMN gpm      HEADING 'GP|%'              FORMAT 990.9

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF q1 q2 q3 q4 gp ON REPORT

WITH cby AS (
    SELECT p.product_ID, b.br_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, b.br_ID, d.cal_year
),
cy AS (
    SELECT p.product_ID, d.cal_year,
           SUM(f.purchase_total_cost) / SUM(f.purchase_qty) AS ucost
    FROM   purchase_fact f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    GROUP  BY p.product_ID, d.cal_year
),
line AS (
    SELECT p.product_ID, p.product_name, b.br_ID, d.cal_year, d.cal_quarter,
           SUM(f.order_qty) AS units, SUM(f.order_net_amt) AS rev
    FROM   order_fact  f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    WHERE  f.order_status = 'Completed'
    AND    UPPER(b.br_city)          = UPPER(TRIM('&p_branch'))
    AND    UPPER(p.product_category) LIKE '%' || UPPER(TRIM('&p_cat')) || '%'
    AND    d.cal_year = TO_NUMBER('&p_year')
    GROUP  BY p.product_ID, p.product_name, b.br_ID, d.cal_year, d.cal_quarter
),
costed AS (
    SELECT l.product_ID, l.product_name, l.cal_quarter, l.units, l.rev,
           l.units * NVL(cby.ucost, cy.ucost) AS cogs
    FROM   line l
    LEFT   JOIN cby ON cby.product_ID = l.product_ID
                   AND cby.br_ID      = l.br_ID
                   AND cby.cal_year   = l.cal_year
    LEFT   JOIN cy  ON cy.product_ID  = l.product_ID
                   AND cy.cal_year    = l.cal_year
),
piv AS (
    -- the four quarters become columns
    SELECT * FROM (SELECT product_ID, cal_quarter, rev - cogs AS gp
                   FROM   costed)
    PIVOT (SUM(gp) FOR cal_quarter IN (1 AS q1, 2 AS q2, 3 AS q3, 4 AS q4))
),
byprod AS (
    -- the year total that the ranking is built on
    SELECT product_ID,
           MAX(product_name) AS pname,
           SUM(rev)   AS sales,
           SUM(rev) - SUM(cogs) AS gp
    FROM   costed
    GROUP  BY product_ID
),
ranked AS (
    SELECT b.pname, b.sales, b.gp,
           NVL(p.q1, 0) AS q1, NVL(p.q2, 0) AS q2,
           NVL(p.q3, 0) AS q3, NVL(p.q4, 0) AS q4,
           b.gp / NULLIF(b.sales, 0) * 100 AS gpm,
           RANK() OVER (ORDER BY b.gp DESC) AS rnk
    FROM   byprod b
    JOIN   piv    p ON p.product_ID = b.product_ID
)
SELECT rnk, pname, q1, q2, q3, q4, gp, gpm
FROM   ranked
ORDER  BY rnk;

PROMPT
PROMPT +==========================================================+
PROMPT |        END OF PRODUCT CONTRIBUTION REPORT                |
PROMPT +==========================================================+
PROMPT

-- ===================================================================
-- tidy up so the next script starts clean
-- ===================================================================
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE p_from
UNDEFINE p_to
UNDEFINE p_state
UNDEFINE p_branch
UNDEFINE p_year
UNDEFINE p_cat
SET FEEDBACK ON
SET VERIFY ON
