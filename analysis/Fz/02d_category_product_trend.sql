-- ===================================================================
-- 02d_category_product_trend.sql
-- GLOW BEAUTY - CATEGORY BY YEAR, THEN THE PRODUCTS INSIDE ONE
--
-- THE DRILL PATH
--   1. YEAR x CATEGORY  every year, with its categories ranked inside
--                       it: revenue, cost, gross profit, margin and
--                       share of that year's profit
--   2. PRODUCT          pick a year and a category, and see its
--                       products ranked, with the four quarters
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\02d_category_product_trend.sql
--
-- PARAMETERS (prompted; every one carries a DEFAULT)
--   start year / end year   the period section 1 covers (data 2019-2025)
--   state                   scopes the WHOLE report. ALL (the default)
--                           means every state; otherwise any part of a
--                           state name, case-insensitive
--   branch                  scopes it further. ALL (the default) means
--                           every branch in whatever the state prompt
--                           left; otherwise the exact branch city
--   year                    the year section 2 opens up (default the
--                           end year)
--   category                the category section 2 opens up, matched on
--                           any part of the name (default Serum)
--
-- Scope defaults to all 17 branches; the state and branch prompts
-- narrow it. This report covers PRODUCT sales only
-- (order_fact) - service revenue has no product dimension and no cost
-- of goods, so it is out of scope. See 01_branch_profitability.sql for
-- the whole-branch picture and 02c for the state/branch drill.
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
-- THE TWO PERCENTAGE COLUMNS ARE NOT THE SAME THING
-- ===================================================================
--   GP %          gross profit / revenue - the MARGIN. It barely moves:
--                 all 56 products sit between 58.03 % and 59.26 %,
--                 because every product is bought at the same share of
--                 its shelf price. Printed so the flatness is visible.
--   SHARE OF YR   that category's gross profit as a share of the whole
--                 year's. This is the column that separates categories,
--                 and it is what the rank is built on.
-- A category low down the ranking is a low-VOLUME line, never a
-- low-margin one.
--
-- OLAP TECHNIQUES USED
--   CTE (WITH)          both sections
--   CASE WHEN           the cost fallback
--   RANK ... PARTITION  section 1 - ranks the categories WITHIN each
--                       year, so every year restarts at 1
--   Ratio to report     section 1 - share of the year's gross profit
--   PIVOT               section 2 - the quarters across the page
--   BREAK / COMPUTE     the year grouping and the average row
-- ===================================================================

-- reset anything a previous script left behind in this session
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 200
SET LINESIZE 132
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

PROMPT
ACCEPT p_from   CHAR DEFAULT 2019 PROMPT 'Start year (default 2019): '
ACCEPT p_to     CHAR DEFAULT 2025 PROMPT 'End year   (default 2025): '
ACCEPT p_state  CHAR DEFAULT ALL  PROMPT 'State  - name or ALL (default ALL): '
ACCEPT p_branch CHAR DEFAULT ALL  PROMPT 'Branch - city or ALL (default ALL): '
PROMPT

-- one readable label for the titles, so the reader always knows what
-- the numbers cover
SET TERMOUT OFF
COLUMN scope NEW_VALUE scope NOPRINT
SELECT CASE WHEN UPPER(TRIM('&p_branch')) <> 'ALL' THEN UPPER(TRIM('&p_branch'))
            WHEN UPPER(TRIM('&p_state'))  <> 'ALL'
              THEN UPPER(TRIM('&p_state')) || ' (ALL BRANCHES)'
            ELSE 'ALL BRANCHES' END AS scope
FROM   dual;
SET TERMOUT ON


-- ###################################################################
-- SECTION 1 - YEAR x CATEGORY
-- One block per year, categories ranked inside it. RANK is PARTITIONED
-- BY year so the numbering restarts every year and the movement of a
-- category up or down the order is readable straight down the page.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. CATEGORY PERFORMANCE BY YEAR' SKIP 1 -
       CENTER 'RANKED WITHIN EACH YEAR, &scope, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year HEADING 'YEAR'              FORMAT 9999
COLUMN rnk      HEADING 'RANK'              FORMAT 990
COLUMN cat      HEADING 'CATEGORY'          FORMAT A20
COLUMN rev      HEADING 'REVENUE|(RM)'      FORMAT 9,999,990
COLUMN cogs     HEADING 'COST|(RM)'         FORMAT 9,999,990
COLUMN gp       HEADING 'GROSS|PROFIT (RM)' FORMAT S9,999,990
COLUMN gpm      HEADING 'GP|%'              FORMAT 990.9
COLUMN share_yr HEADING 'SHARE OF|YR GP'    FORMAT A8

-- a blank line between years, and the year printed once per block
BREAK ON cal_year SKIP 1

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
    SELECT p.product_category, p.product_ID, b.br_ID, d.cal_year,
           SUM(f.order_qty) AS units, SUM(f.order_net_amt) AS rev
    FROM   order_fact  f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    -- ALL on either prompt switches that filter off entirely
    AND    (UPPER(TRIM('&p_state'))  = 'ALL'
            OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&p_state')) || '%')
    AND    (UPPER(TRIM('&p_branch')) = 'ALL'
            OR UPPER(b.br_city)  = UPPER(TRIM('&p_branch')))
    GROUP  BY p.product_category, p.product_ID, b.br_ID, d.cal_year
),
costed AS (
    SELECT l.product_category, l.cal_year, l.rev,
           l.units * NVL(cby.ucost, cy.ucost) AS cogs
    FROM   line l
    LEFT   JOIN cby ON cby.product_ID = l.product_ID
                   AND cby.br_ID      = l.br_ID
                   AND cby.cal_year   = l.cal_year
    LEFT   JOIN cy  ON cy.product_ID  = l.product_ID
                   AND cy.cal_year    = l.cal_year
),
catyear AS (
    SELECT cal_year,
           product_category     AS cat,
           SUM(rev)             AS rev,
           SUM(cogs)            AS cogs,
           SUM(rev) - SUM(cogs) AS gp
    FROM   costed
    GROUP  BY cal_year, product_category
)
SELECT cal_year,
       RANK() OVER (PARTITION BY cal_year ORDER BY gp DESC) AS rnk,
       cat, rev, cogs, gp,
       gp / NULLIF(rev, 0) * 100 AS gpm,
       TO_CHAR(ROUND(gp / SUM(gp) OVER (PARTITION BY cal_year) * 100, 1),
               '990.9') || '%' AS share_yr
FROM   catyear
ORDER  BY cal_year, rnk;


-- ###################################################################
-- SECTION 2 - PRODUCT: INSIDE ONE CATEGORY IN ONE YEAR
-- Every product on that shelf in that year, ranked by gross profit,
-- with the four quarters pivoted across so the seasonal shape sits
-- beside the total.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_year CHAR DEFAULT '&p_to'  PROMPT 'Year to open up (default the end year): '
ACCEPT p_cat  CHAR DEFAULT 'Serum'  PROMPT 'Category to open up (default Serum): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. &p_cat PRODUCTS IN &p_year' SKIP 1 -
       CENTER '&scope - RANKED BY GROSS PROFIT, QUARTERS ACROSS' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk     HEADING 'RANK'              FORMAT 990
COLUMN pname   HEADING 'PRODUCT'           FORMAT A43
COLUMN units   HEADING 'UNITS|SOLD'        FORMAT 99,990
COLUMN rev     HEADING 'REVENUE|(RM)'      FORMAT 9,999,990
COLUMN cogs    HEADING 'COST|(RM)'         FORMAT 999,990
COLUMN gp      HEADING 'GROSS|PROFIT (RM)' FORMAT S999,990
COLUMN gpm     HEADING 'GP|%'              FORMAT 990.9
COLUMN q1      HEADING 'Q1 GP|(RM)'        FORMAT 999,990
COLUMN q2      HEADING 'Q2 GP|(RM)'        FORMAT 999,990
COLUMN q3      HEADING 'Q3 GP|(RM)'        FORMAT 999,990
COLUMN q4      HEADING 'Q4 GP|(RM)'        FORMAT 999,990

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF units rev cogs gp q1 q2 q3 q4 ON REPORT

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
    AND    UPPER(p.product_category) LIKE '%' || UPPER(TRIM('&p_cat')) || '%'
    AND    d.cal_year = TO_NUMBER('&p_year')
    -- the same scope as section 1
    AND    (UPPER(TRIM('&p_state'))  = 'ALL'
            OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&p_state')) || '%')
    AND    (UPPER(TRIM('&p_branch')) = 'ALL'
            OR UPPER(b.br_city)  = UPPER(TRIM('&p_branch')))
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
    SELECT product_ID,
           MAX(product_name)    AS pname,
           SUM(units)           AS units,
           SUM(rev)             AS rev,
           SUM(cogs)            AS cogs,
           SUM(rev) - SUM(cogs) AS gp
    FROM   costed
    GROUP  BY product_ID
)
SELECT RANK() OVER (ORDER BY b.gp DESC) AS rnk,
       b.pname,
       b.units,
       b.rev,
       b.cogs,
       b.gp,
       b.gp / NULLIF(b.rev, 0) * 100 AS gpm,
       NVL(p.q1, 0) AS q1, NVL(p.q2, 0) AS q2,
       NVL(p.q3, 0) AS q3, NVL(p.q4, 0) AS q4
FROM   byprod b
JOIN   piv    p ON p.product_ID = b.product_ID
ORDER  BY rnk;

PROMPT
PROMPT +==========================================================+
PROMPT |     END OF CATEGORY AND PRODUCT TREND REPORT             |
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
UNDEFINE scope
UNDEFINE p_year
UNDEFINE p_cat
SET FEEDBACK ON
SET VERIFY ON
