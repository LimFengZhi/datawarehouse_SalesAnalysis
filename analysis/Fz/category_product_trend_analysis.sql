-- ===================================================================
-- 02b_category_product_trend.sql
-- GLOW BEAUTY - CATEGORY PERFORMANCE AND TREND
--   which product categories earn the profit, year by year, and
--   which products carry the category you open up - in EVERY year
--
-- THE DRILL PATH
--   0a. STATE MENU     after the years: every state on its average
--                       BRANCH-YEAR (avg revenue / COGS / GP per
--                       branch per year) - pick a state with fair,
--                       comparable numbers in view
--   0b. BRANCH MENU    the branches inside that answer, each on its
--                       AVERAGE YEAR with its trading years shown -
--                       then pick one (or Enter for all of them)
--   1. YEAR x CATEGORY  every year, with its TOP n categories ranked
--                       inside it: revenue, cost, gross profit,
--                       margin, the four quarters' gross profit
--                       across, and share of that year's profit
--   2. TOP PRODUCTS     pick a category and a year (default the end
--                       year): the top n products of that shelf in
--                       that year, quarters pivoted across, each
--                       with its share of the category's GP, closed
--                       by an AVG row
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\02b_category_product_trend.sql
--
-- PARAMETERS (prompted; every one carries a DEFAULT)
--   start year / end year   the period section 1 covers (data 2019-2025)
--   state                   scopes the WHOLE report - pick it off menu
--                           0a. ALL (the default, just press Enter)
--                           means every state; otherwise any part of a
--                           state name, case-insensitive
--   branch                  pick it off menu 0b, which already shows
--                           only the branches the state answer left.
--                           Matched on any part of br_name ('Ipoh'
--                           finds 'Glow Beauty Ipoh'). ALL (Enter)
--                           keeps all of them
--   top how many            categories section 1 shows per year,
--                           ranked on gross profit (default 3; type
--                           a big number to see every category)
--   category                the category section 2 opens up, matched on
--                           any part of the name (default Serum)
--   year                    the year section 2 opens up (default the
--                           end year)
--   top products            products section 2 shows for that year,
--                           ranked on gross profit (default 5; type a
--                           big number to see the whole shelf)
--
-- Scope defaults to all 17 branches; the state and branch prompts
-- narrow it. This report covers PRODUCT sales only
-- (order_fact) - service revenue has no product dimension and no cost
-- of goods, so it is out of scope. See 01_branch_profitability.sql
-- for the whole-branch picture, services and payroll included.
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
--   VIEW                costed_sales_v - the costed sales lines all
--                       four queries share (created at the top,
--                       dropped at the end, like 01b's helper view)
--   CTE (WITH)          every section
--   CASE WHEN           the cost fallback
--   ROLLUP + GROUPING   both menus - the ANSWER: ALL row comes from
--                       the same GROUP BY as the real rows
--   RANK ... PARTITION  section 1 - ranks the categories WITHIN each
--                       year, so every year restarts at 1
--   Ratio to report     section 1 - share of the year's gross profit;
--                       section 2 - a product's share of its category
--                       within the chosen year
--   CASE quarters       section 1 - the quarters across the page
--   PIVOT               section 2 - the quarters across the page
--   BREAK / COMPUTE     section 2 - the AVG row under the ranked list
--   BREAK / COMPUTE     the year grouping and the average row
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
ACCEPT p_from   CHAR DEFAULT 2023 PROMPT 'Start year (default 2023): '
ACCEPT p_to     CHAR DEFAULT 2025 PROMPT 'End year   (default 2025): '
PROMPT

-- ###################################################################
-- SECTION 0 - THE SHARED COSTED SALES LINES, AS A TEMPORARY VIEW
-- The unit-cost lookup (per product per branch per year, chain
-- fallback) and the costed order lines used to be repeated inside
-- all four queries below. They are now written ONCE here, at the
-- finest grain any section needs (product x branch x year x quarter),
-- created at the top and DROPPED at the bottom - the same
-- create-and-drop pattern as 01b. Prompts are NOT baked in: every
-- section filters the view itself, so the view text is identical on
-- every run. Abort part-way and costed_sales_v is left behind -
-- harmless; the next complete run replaces and drops it.
-- ###################################################################
CREATE OR REPLACE VIEW costed_sales_v AS
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
    SELECT p.product_ID, p.product_name, p.product_category,
           b.br_ID, b.br_name, b.br_state,
           d.cal_year, d.cal_quarter,
           SUM(f.order_qty) AS units, SUM(f.order_net_amt) AS rev
    FROM   order_fact  f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   date_dim    d ON d.date_key    = f.date_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY p.product_ID, p.product_name, p.product_category,
              b.br_ID, b.br_name, b.br_state, d.cal_year, d.cal_quarter
)
SELECT l.product_ID, l.product_name, l.product_category,
       l.br_ID, l.br_name, l.br_state,
       l.cal_year, l.cal_quarter,
       l.units, l.rev,
       l.units * NVL(cby.ucost, cy.ucost) AS cogs
FROM   line l
LEFT   JOIN cby ON cby.product_ID = l.product_ID
               AND cby.br_ID      = l.br_ID
               AND cby.cal_year   = l.cal_year
LEFT   JOIN cy  ON cy.product_ID  = l.product_ID
               AND cy.cal_year    = l.cal_year;


-- ###################################################################
-- SECTION 0a - THE STATE MENU
-- One row per state with the AVERAGE BRANCH-YEAR beside the total:
-- revenue, COGS and gross profit divided by the branch-years the
-- state actually traded (Subang Jaya and Bukit Jalil only count for
-- the years since they opened in 2024). That makes states with
-- different shop counts AND different opening dates comparable -
-- dividing by the branch count alone would punish a state whose
-- branches are young. Sorted on avg revenue per branch per year.
-- The ANSWER: ALL row is what pressing Enter at the prompt means.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 0a. PICK A STATE' SKIP 1 -
       CENTER 'PRODUCT REVENUE BY STATE, AVERAGE BRANCH-YEAR, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN st        HEADING 'STATE'                    FORMAT A17
COLUMN brs       HEADING 'BR'                       FORMAT 90
COLUMN sales     HEADING 'TOTAL PRODUCT|REVENUE (RM)' FORMAT 999,999,990
COLUMN avg_rev   HEADING 'AVG ANNUAL|REVENUE / BR'  FORMAT 9,999,990
COLUMN avg_cogs  HEADING 'AVG ANNUAL|COGS / BR'     FORMAT 9,999,990
COLUMN avg_gp    HEADING 'AVG ANNUAL|GP / BR'       FORMAT S9,999,990
COLUMN gpm       HEADING 'GP|%'                     FORMAT 990.9

SELECT CASE WHEN GROUPING(br_state) = 1 THEN 'ANSWER: ALL'
            -- the full label is 33 characters and would wrap the row
            WHEN br_state = 'Federal Territory of Kuala Lumpur'
            THEN 'FT Kuala Lumpur' ELSE br_state END        AS st,
       COUNT(DISTINCT br_ID)                                AS brs,
       SUM(rev)                                             AS sales,
       SUM(rev)  / COUNT(DISTINCT br_ID || '/' || TO_CHAR(cal_year))
                                                            AS avg_rev,
       SUM(cogs) / COUNT(DISTINCT br_ID || '/' || TO_CHAR(cal_year))
                                                            AS avg_cogs,
       (SUM(rev) - SUM(cogs))
                 / COUNT(DISTINCT br_ID || '/' || TO_CHAR(cal_year))
                                                            AS avg_gp,
       (SUM(rev) - SUM(cogs)) / NULLIF(SUM(rev), 0) * 100   AS gpm
FROM   costed_sales_v
WHERE  cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
GROUP  BY ROLLUP(br_state)
ORDER  BY GROUPING(br_state), avg_rev DESC;

PROMPT
ACCEPT p_state CHAR DEFAULT ALL PROMPT 'State  - name or ALL (default ALL): '
PROMPT

-- ###################################################################
-- SECTION 0b - THE BRANCH MENU, INSIDE THAT ANSWER
-- Only the branches the state prompt left in play (all 17 if the
-- answer was ALL), each on its AVERAGE YEAR - revenue, COGS and
-- gross profit divided by the years it actually traded (YRS), so a
-- 2024 opening is not punished for being young. Sorted on avg
-- revenue per year. The ** total row is what pressing Enter means;
-- its averages divide by BRANCH-YEARS, so it lines up with 0a.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 0b. PICK A BRANCH IN: &p_state' SKIP 1 -
       CENTER 'PRODUCT REVENUE BY BRANCH, AVERAGE YEAR, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br       HEADING 'BRANCH'                FORMAT A26
COLUMN yrs      HEADING 'YRS'                   FORMAT 90
COLUMN sales    HEADING 'TOTAL|REVENUE (RM)'    FORMAT 999,999,990
COLUMN avg_rev  HEADING 'AVG REVENUE|PER YEAR'  FORMAT 9,999,990
COLUMN avg_cogs HEADING 'AVG COGS|PER YEAR'     FORMAT 9,999,990
COLUMN avg_gp   HEADING 'AVG GP|PER YEAR'       FORMAT S9,999,990
COLUMN gpm      HEADING 'GP|%'                  FORMAT 990.9

SELECT CASE WHEN GROUPING(br_name) = 1 THEN '** ANSWER: ALL'
            ELSE br_name END                                AS br,
       COUNT(DISTINCT cal_year)                             AS yrs,
       SUM(rev)                                             AS sales,
       -- per branch row the denominator is its trading years; on the
       -- ** row it is BRANCH-YEARS, the same average-branch-year as 0a
       SUM(rev)  / COUNT(DISTINCT br_ID || '/' || TO_CHAR(cal_year))
                                                            AS avg_rev,
       SUM(cogs) / COUNT(DISTINCT br_ID || '/' || TO_CHAR(cal_year))
                                                            AS avg_cogs,
       (SUM(rev) - SUM(cogs))
                 / COUNT(DISTINCT br_ID || '/' || TO_CHAR(cal_year))
                                                            AS avg_gp,
       (SUM(rev) - SUM(cogs)) / NULLIF(SUM(rev), 0) * 100   AS gpm
FROM   costed_sales_v
WHERE  cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
-- the state answer scopes this list; ALL switches the filter off
AND    (UPPER(TRIM('&p_state')) = 'ALL'
        OR UPPER(br_state) LIKE '%' || UPPER(TRIM('&p_state')) || '%')
GROUP  BY ROLLUP(br_name)
ORDER  BY GROUPING(br_name), avg_rev DESC;

CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_branch CHAR DEFAULT ALL PROMPT 'Branch - name or ALL (default ALL): '
ACCEPT p_topn   CHAR DEFAULT 3   PROMPT 'Top categories per year (default 3): '
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
-- SECTION 1 - YEAR x CATEGORY, QUARTERS ACROSS
-- One block per year, its TOP n categories ranked inside it. RANK is
-- PARTITIONED BY year so the numbering restarts every year and the
-- movement of a category up or down the order is readable straight
-- down the page. The four quarters' gross profit sits beside the
-- year total so the seasonal shape is visible per category. SHARE OF
-- YR GP is still measured against the WHOLE year's gross profit
-- (worked out before the top-n cut), so the top rows say how much of
-- the year they carry, not 100 % between them.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. CATEGORY PERFORMANCE BY YEAR' SKIP 1 -
       CENTER 'TOP &p_topn CATEGORIES WITHIN EACH YEAR, &scope, &p_from - &p_to' SKIP 1 -
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
COLUMN q1       HEADING 'Q1 GP|(RM)'        FORMAT 9,999,990
COLUMN q2       HEADING 'Q2 GP|(RM)'        FORMAT 9,999,990
COLUMN q3       HEADING 'Q3 GP|(RM)'        FORMAT 9,999,990
COLUMN q4       HEADING 'Q4 GP|(RM)'        FORMAT 9,999,990
COLUMN share_yr HEADING 'SHARE OF|YR GP'    FORMAT A8

-- a blank line between years, the year printed once per block, and
-- an AVG row closing EVERY year block (ON cal_year - the average of
-- the categories LISTED in that year). The row of * above each AVG
-- is SQL*Plus marking the break column; it cannot be removed without
-- losing the AVG label.
BREAK ON cal_year SKIP 1
COMPUTE AVG LABEL 'AVG' OF rev cogs gp q1 q2 q3 q4 ON cal_year

WITH catyear AS (
    SELECT cal_year,
           product_category     AS cat,
           SUM(rev)             AS rev,
           SUM(cogs)            AS cogs,
           SUM(rev) - SUM(cogs) AS gp,
           SUM(CASE WHEN cal_quarter = 1 THEN rev - cogs ELSE 0 END) AS q1,
           SUM(CASE WHEN cal_quarter = 2 THEN rev - cogs ELSE 0 END) AS q2,
           SUM(CASE WHEN cal_quarter = 3 THEN rev - cogs ELSE 0 END) AS q3,
           SUM(CASE WHEN cal_quarter = 4 THEN rev - cogs ELSE 0 END) AS q4
    FROM   costed_sales_v
    WHERE  cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    -- ALL on either prompt switches that filter off entirely
    AND    (UPPER(TRIM('&p_state'))  = 'ALL'
            OR UPPER(br_state) LIKE '%' || UPPER(TRIM('&p_state')) || '%')
    AND    (UPPER(TRIM('&p_branch')) = 'ALL'
            OR UPPER(br_name) LIKE '%' || UPPER(TRIM('&p_branch')) || '%')
    GROUP  BY cal_year, product_category
),
ranked AS (
    -- rank and year total BEFORE the top-n cut, so SHARE OF YR GP
    -- stays a share of the whole year
    SELECT cal_year, cat, rev, cogs, gp, q1, q2, q3, q4,
           RANK() OVER (PARTITION BY cal_year ORDER BY gp DESC) AS rnk,
           SUM(gp) OVER (PARTITION BY cal_year)                 AS yr_gp
    FROM   catyear
)
SELECT cal_year,
       rnk,
       cat, rev, cogs, gp,
       gp / NULLIF(rev, 0) * 100 AS gpm,
       q1, q2, q3, q4,
       TO_CHAR(ROUND(gp / NULLIF(yr_gp, 0) * 100, 1),
               '990.9') || '%' AS share_yr
FROM   ranked
WHERE  rnk <= TO_NUMBER('&p_topn')
ORDER  BY cal_year, rnk;


-- ###################################################################
-- SECTION 2 - TOP PRODUCTS: INSIDE ONE CATEGORY IN ONE YEAR
-- Pick the category off section 1's list and a year (default the end
-- year): the shelf opens into individual products - the top n by
-- gross profit in that year, quarters pivoted across, each with its
-- share of the category's GP that year (worked out before the top-n
-- cut). The AVG row averages the rows SHOWN.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_cat   CHAR DEFAULT 'Serum' PROMPT 'Category to open up: '
ACCEPT p_year  CHAR DEFAULT '&p_to' PROMPT 'Year to open up: '
ACCEPT p_prodn CHAR DEFAULT 3      PROMPT 'Top products to show: '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. TOP &p_prodn &p_cat PRODUCTS IN &p_year' SKIP 1 -
       CENTER '&scope - RANKED BY GROSS PROFIT, QUARTERS ACROSS' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk       HEADING 'RANK'              FORMAT 990
COLUMN pname     HEADING 'PRODUCT'           FORMAT A43
COLUMN units     HEADING 'UNITS|SOLD'        FORMAT 999,990
COLUMN rev       HEADING 'REVENUE|(RM)'      FORMAT 9,999,990
COLUMN gp        HEADING 'GROSS|PROFIT (RM)' FORMAT S9,999,990
COLUMN q1        HEADING 'Q1 GP|(RM)'        FORMAT 999,990
COLUMN q2        HEADING 'Q2 GP|(RM)'        FORMAT 999,990
COLUMN q3        HEADING 'Q3 GP|(RM)'        FORMAT 999,990
COLUMN q4        HEADING 'Q4 GP|(RM)'        FORMAT 999,990
-- share_cat, not share: SHARE is an Oracle reserved word (LOCK TABLE
-- ... IN SHARE MODE) and ORA-00923s as a column alias
COLUMN share_cat HEADING 'SHARE OF|CAT GP'   FORMAT A8

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF units rev gp q1 q2 q3 q4 ON REPORT

WITH shelf AS (
    -- the same scope, cut to the ONE year asked for
    SELECT product_ID, product_name, cal_quarter, units, rev, cogs
    FROM   costed_sales_v
    WHERE  UPPER(product_category) LIKE '%' || UPPER(TRIM('&p_cat')) || '%'
    AND    cal_year = TO_NUMBER('&p_year')
    AND    (UPPER(TRIM('&p_state'))  = 'ALL'
            OR UPPER(br_state) LIKE '%' || UPPER(TRIM('&p_state')) || '%')
    AND    (UPPER(TRIM('&p_branch')) = 'ALL'
            OR UPPER(br_name) LIKE '%' || UPPER(TRIM('&p_branch')) || '%')
),
byprod AS (
    SELECT product_ID,
           MAX(product_name)    AS pname,
           SUM(units)           AS units,
           SUM(rev)             AS rev,
           SUM(rev) - SUM(cogs) AS gp
    FROM   shelf
    GROUP  BY product_ID
),
piv AS (
    -- the four quarters become columns
    SELECT * FROM (SELECT product_ID, cal_quarter, rev - cogs AS gp
                   FROM   shelf)
    PIVOT (SUM(gp) FOR cal_quarter IN (1 AS q1, 2 AS q2, 3 AS q3, 4 AS q4))
),
ranked AS (
    -- rank the WHOLE shelf and take the category total BEFORE the
    -- top-n cut, so SHARE OF CAT GP stays a share of everything
    SELECT RANK() OVER (ORDER BY b.gp DESC) AS rnk,
           b.pname, b.units, b.rev, b.gp,
           NVL(p.q1, 0) AS q1, NVL(p.q2, 0) AS q2,
           NVL(p.q3, 0) AS q3, NVL(p.q4, 0) AS q4,
           SUM(b.gp) OVER ()                AS cat_gp
    FROM   byprod b
    JOIN   piv    p ON p.product_ID = b.product_ID
)
SELECT rnk,
       pname,
       units,
       rev,
       gp,
       q1, q2, q3, q4,
       TO_CHAR(ROUND(gp / NULLIF(cat_gp, 0) * 100, 1),
               '990.9') || '%' AS share_cat
FROM   ranked
WHERE  rnk <= TO_NUMBER('&p_prodn')
ORDER  BY rnk;


PROMPT
PROMPT Report Completed
PROMPT

-- ===================================================================
-- tidy up: drop the temporary view from SECTION 0, then reset the
-- session. If a run was aborted before this line the view survives -
-- the next complete run replaces and drops it.
-- ===================================================================
DROP VIEW costed_sales_v;

TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE p_from
UNDEFINE p_to
UNDEFINE p_state
UNDEFINE p_branch
UNDEFINE p_topn
UNDEFINE scope
UNDEFINE p_cat
UNDEFINE p_year
UNDEFINE p_prodn
SET FEEDBACK ON
SET VERIFY ON
