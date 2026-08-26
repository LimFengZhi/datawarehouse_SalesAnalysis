-- ===================================================================
-- 02_branch_expense_cost_structure.sql
-- BRANCH OPERATING COST STRUCTURE AND COST EFFICIENCY
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\My\02_branch_expense_cost_structure.sql
--
-- PARAMETERS (prompted)
--   start year   first year to analyse            (default 2019)
--   end year     last year to analyse             (default 2025)
--   state        e.g. Selangor / Johor / Perak, or ALL  (default ALL)
--                Matched with LIKE on branch_dim.br_state, so a partial
--                name works: 'selangor', 'Selangor' and 'sel' all hit
--                Selangor, and 'kuala lumpur' hits the Federal
--                Territory of Kuala Lumpur. Entering a state that has
--                no branches simply returns no rows.
--   There is deliberately no BRANCH filter: the point of this report is
--   finding WHICH branch converts its cost base into revenue best, and
--   a single-branch filter would hide exactly that. The state filter is
--   different - it narrows the comparison to a peer group that shares a
--   rent market and a labour market, which makes the Section B ranking
--   fairer than comparing Kuala Lumpur against Kuantan.
--
-- PURPOSE
--   Establish, from the warehouse data alone, (1) what Glow Beauty's
--   TOTAL branch cost base is made of and how that mix moves over time,
--   and (2) which branches turn that cost base into revenue and which
--   do not, year by year.
--
--   Both sections are written to stand on their own as EVIDENCE: each
--   reports the measured figures for a single claim, so the claim can
--   be checked against the output rather than taken on trust.
--
-- THE THREE COST STREAMS
--   Rent and utilities are only part of what a branch spends, so this
--   report adds the two larger streams alongside them:
--   PAYROLL     salary_payment_fact - gross pay (base_amount +
--               bonus_amount), NOT total_amount. total_amount is
--               base + bonus - deduction, i.e. what the STAFF take home
--               after EPF; the company's actual cash outflow is the
--               gross figure, so that is what a cost report must use.
--   INVENTORY   purchase_fact.purchase_total_cost - stock bought in
--               from suppliers to resell.
--   OVERHEAD    branch_utils_fact.payment_amount - Rent, Electricity,
--               Water, Internet, Maintenance, Waste Management.
--   Total Cost = PAYROLL + INVENTORY + OVERHEAD, and every efficiency
--   figure in this report is measured against that total.
--
-- THE FINDINGS THIS EVIDENCE SUPPORTS
--   F1  The mix between the three streams is stable across the range,
--       and once the figures are put on a per-branch-per-month basis
--       the apparent jump in total cost when new branches open turns
--       out to be scale, not cost inflation. A branch's cost efficiency
--       is therefore driven by its REVENUE, not by a change in what it
--       is billed for.                                  [Section A]
--   F2  Cost efficiency varies widely between branches, and within a
--       single branch it moves year to year - a branch's rank is not a
--       fixed property. Section B also splits each branch's cost into
--       the three streams, so the reader can see WHICH stream is
--       dragging a poorly ranked branch.                [Section B]
--
-- SCOPE NOTE
--   The three stream labels are NOT stored data - they say which fact
--   table a row came from. Only branch_utils_fact carries a name of its
--   own (util_name: Rent / Electricity / Water / Internet / Maintenance
--   / Waste Management), and even that is a degenerate attribute, since
--   that fact has no dimension (dwh\create_dwh.sql). salary_payment_
--   fact and purchase_fact each record a single kind of cost, so they
--   carry no name column at all.
--   INVENTORY IS CASH-BASIS: purchase_fact records stock BOUGHT in a
--   period, not stock sold in it, so it is procurement spend rather
--   than true COGS. Over a full year the two converge closely (the
--   business restocks what sold), but a single month can be lumpy.
--   Expense data runs 2019-2025 (sales_data5\ covers those years only),
--   so a range wider than that just returns the years that exist.
--   The four branches opened on 1 Jan 2024 (Seremban, Kuantan, Subang
--   Jaya, Bukit Jalil) carry no rows before 2024 and correctly do not
--   appear in earlier years - that is not a gap in the data.
--
-- MEASURES
--   Cost (RM)          PAYROLL + INVENTORY + OVERHEAD, as defined above.
--                      No status filter on any of the three - every one
--                      of those payments is real cash out.
--   Revenue (RM)       order_fact.order_net_amt (Completed orders)
--                      + reservation_fact.serv_net_amt (Completed
--                      reservations). Both already exclude SST, which
--                      is collected for the government - see the column
--                      comments in dwh\create_dwh.sql.
--   Avg Monthly per     Total cost divided by the number of branch-months
--   Branch (RM)         it actually covers, so a branch that had not
--                       opened yet is left out rather than counted as a
--                       zero. This is what makes different years
--                       comparable once the branch count changes.
--   Rev vs Cost %      (Revenue - Cost) / Cost * 100. Positive means
--                      revenue ran ahead of what the branch spent.
--
-- DIMENSIONS USED (two)
--   branch_dim   br_ID (natural key - SCD2, so every GROUP BY uses it
--                rather than branch_key, per CLAUDE.md), br_city,
--                br_state (the filter)
--   date_dim     cal_year, cal_year_month
-- FACTS USED (five)
--   COST     salary_payment_fact, purchase_fact, branch_utils_fact
--   REVENUE  order_fact, reservation_fact
--
-- SECTIONS
--   A  COST STREAM MIX BY YEAR
--   B  COST EFFICIENCY BY BRANCH, ONE RANKING PER YEAR
--
-- NOTE ON "PAGE: 1"
--   SQL.PNO counts pages within the CURRENT SELECT's own output
--   (PAGESIZE = 60 lines). Section A is far shorter than that and stays
--   on PAGE: 1. Section B prints a full league table for every year in
--   the range, so it legitimately rolls to PAGE: 2, 3 ... and the title
--   reprints - that is SQL*Plus working as intended.
-- ===================================================================

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

ACCEPT start_year NUMBER DEFAULT 2019  PROMPT 'Enter the START year of the analysis (default 2019): '
ACCEPT end_year   NUMBER DEFAULT 2025  PROMPT 'Enter the END year of the analysis   (default 2025): '
ACCEPT state      CHAR   DEFAULT 'ALL' PROMPT 'Enter a state (e.g. Selangor) or ALL for every state (default ALL): '

-- ---- values reused in every title ---------------------------------
SET TERMOUT OFF
COLUMN run_dt NEW_VALUE run_dt NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN yr_range NEW_VALUE yr_range NOPRINT
SELECT TO_CHAR(&start_year) || ' - ' || TO_CHAR(&end_year) AS yr_range FROM dual;

-- what the titles print for the state filter: either the full stored
-- name of the single state matched, or 'ALL STATES'
COLUMN st_label NEW_VALUE st_label NOPRINT
SELECT CASE
         WHEN UPPER(TRIM('&state')) IN ('', 'ALL') THEN 'ALL STATES'
         ELSE NVL(MAX(UPPER(br_state)), 'NO MATCH: ' || UPPER(TRIM('&state')))
       END AS st_label
FROM   branch_dim
WHERE  UPPER(br_state) LIKE '%' || UPPER(TRIM('&state')) || '%';
CLEAR COLUMNS
SET TERMOUT ON

-- The state filter, repeated in both sections. Matches on the branch's
-- state with LIKE, so 'selangor', 'Selangor' and 'sel' all work, and
-- 'kuala lumpur' finds the Federal Territory of Kuala Lumpur.
--   (UPPER(TRIM('&state')) IN ('', 'ALL')
--    OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')


-- ###################################################################
-- SECTION A - COST STREAM MIX BY YEAR
-- EVIDENCE FOR: what the cost base is made of and whether that mix
-- moves. The three RM columns show the composition; AVG MONTHLY PER
-- BRANCH normalises the total so years with a different branch count
-- can still be compared - without it 2024 looks like a cost explosion
-- when it is really four extra branches. If 2020 or 2021 fall inside
-- the range, their dip is the COVID pay cuts and landlord rent
-- rebates, plus reduced restocking against reduced trade.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - A. COST STREAM MIX BY YEAR' SKIP 1 -
       CENTER 'PAYROLL VS INVENTORY VS OVERHEAD, &yr_range' SKIP 1 -
       CENTER '&st_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year       HEADING 'YEAR'                    FORMAT 9999
COLUMN branches       HEADING 'BRANCHES'              FORMAT 99
COLUMN payroll_cost   HEADING 'PAYROLL (RM)'            FORMAT 99,999,990.00
COLUMN inventory_cost HEADING 'INVENTORY (RM)'          FORMAT 99,999,990.00
COLUMN overhead_cost  HEADING 'OVERHEAD (RM)'           FORMAT 99,999,990.00
COLUMN total_cost     HEADING 'TOTAL COST (RM)'         FORMAT 999,999,990.00
COLUMN avg_per_branch HEADING 'AVG MONTHLY COST|PER BRANCH'  FORMAT 999,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF payroll_cost inventory_cost overhead_cost total_cost ON REPORT

WITH cost_lines AS (
    SELECT b.br_ID, d.cal_year, d.cal_year_month,
           'Overhead' AS cost_stream, f.payment_amount AS amt
    FROM   branch_utils_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    UNION ALL
    SELECT b.br_ID, d.cal_year, d.cal_year_month,
           'Payroll', s.base_amount + s.bonus_amount
    FROM   salary_payment_fact s
    JOIN   date_dim   d ON d.date_key   = s.date_key
    JOIN   branch_dim b ON b.branch_key = s.branch_key
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    UNION ALL
    SELECT b.br_ID, d.cal_year, d.cal_year_month,
           'Inventory', p.purchase_total_cost
    FROM   purchase_fact p
    JOIN   date_dim   d ON d.date_key   = p.date_key
    JOIN   branch_dim b ON b.branch_key = p.branch_key
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
)
SELECT cal_year,
       COUNT(DISTINCT br_ID)                                              AS branches,
       SUM(CASE WHEN cost_stream = 'Payroll'   THEN amt ELSE 0 END)       AS payroll_cost,
       SUM(CASE WHEN cost_stream = 'Inventory' THEN amt ELSE 0 END)       AS inventory_cost,
       SUM(CASE WHEN cost_stream = 'Overhead'  THEN amt ELSE 0 END)       AS overhead_cost,
       SUM(amt)                                                           AS total_cost,
       -- divide by the branch-MONTHS actually covered, not branches x 12:
       -- a branch that opened mid-year contributes only its open months.
       -- Oracle 11g has no COUNT(DISTINCT a, b), hence the concatenation.
       ROUND(SUM(amt)
             / NULLIF(COUNT(DISTINCT TO_CHAR(br_ID) || '-'
                                  || TO_CHAR(cal_year_month)), 0), 2)     AS avg_per_branch
FROM   cost_lines
GROUP  BY cal_year
ORDER  BY cal_year;


-- ###################################################################
-- SECTION B - COST EFFICIENCY BY BRANCH, ONE RANKING PER YEAR
-- EVIDENCE FOR: how far each branch's revenue runs ahead of (or behind)
-- what that branch spent, and how that standing moves over time.
--   REV VS COST % = (Revenue - Total Cost) / Total Cost * 100
--   +40.0  revenue was 40% MORE than the branch spent - it earned back
--          its cost base and 40% on top
--    0.0   revenue exactly covered cost - break even
--   -15.0  revenue was 15% SHORT of cost - the branch lost money
-- The report is grouped BY YEAR: each year is its own league table,
-- ranked best (highest surplus) first, with a TOTAL line for that year.
-- The three cost streams are printed separately so a poorly ranked
-- branch can be diagnosed - being heavy on payroll is a different
-- problem from being heavy on stock. Because the ranking restarts
-- every year, a branch that climbs or slides between years is visible
-- directly. A branch missing from an early year had not opened yet.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - B. COST EFFICIENCY BY BRANCH, RANKED PER YEAR' SKIP 1 -
       CENTER 'REVENUE VS TOTAL COST, &yr_range   (POSITIVE = REVENUE AHEAD)' SKIP 1 -
       CENTER '&st_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

-- cal_year and rnk are CHARACTER columns, width 5, so the COMPUTE
-- label 'TOTAL' (5 characters) prints in full instead of truncated.
COLUMN cal_year       HEADING 'YEAR'            FORMAT A5
COLUMN rnk            HEADING 'RANK'            FORMAT A5
COLUMN br_city        HEADING 'BRANCH'          FORMAT A14
COLUMN payroll_cost   HEADING 'PAYROLL (RM)'    FORMAT 99,999,990.00
COLUMN inventory_cost HEADING 'INVENTORY (RM)'  FORMAT 99,999,990.00
COLUMN overhead_cost  HEADING 'OVERHEAD (RM)'   FORMAT 99,999,990.00
COLUMN year_cost      HEADING 'TOTAL COST (RM)' FORMAT 99,999,990.00
COLUMN year_revenue   HEADING 'REVENUE (RM)'    FORMAT 99,999,990.00
COLUMN rev_vs_cost    HEADING 'REV VS COST %'   FORMAT S990.0

-- one league table per year: break on the year, total that year, then
-- a blank line before the next year's table
BREAK ON cal_year SKIP 1
COMPUTE SUM LABEL 'TOTAL' OF payroll_cost inventory_cost overhead_cost -
                             year_cost year_revenue ON cal_year

WITH cost_by_year AS (
    SELECT br_ID, cal_year,
           SUM(CASE WHEN cost_stream = 'Payroll'   THEN amt ELSE 0 END) AS payroll_cost,
           SUM(CASE WHEN cost_stream = 'Inventory' THEN amt ELSE 0 END) AS inventory_cost,
           SUM(CASE WHEN cost_stream = 'Overhead'  THEN amt ELSE 0 END) AS overhead_cost,
           SUM(amt)                                                     AS year_cost
    FROM  (SELECT b.br_ID, d.cal_year, 'Overhead' AS cost_stream,
                  f.payment_amount AS amt
           FROM   branch_utils_fact f
           JOIN   date_dim   d ON d.date_key   = f.date_key
           JOIN   branch_dim b ON b.branch_key = f.branch_key
           WHERE  d.cal_year BETWEEN &start_year AND &end_year
           AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
                  OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
           UNION ALL
           SELECT b.br_ID, d.cal_year, 'Payroll', s.base_amount + s.bonus_amount
           FROM   salary_payment_fact s
           JOIN   date_dim   d ON d.date_key   = s.date_key
           JOIN   branch_dim b ON b.branch_key = s.branch_key
           WHERE  d.cal_year BETWEEN &start_year AND &end_year
           AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
                  OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
           UNION ALL
           SELECT b.br_ID, d.cal_year, 'Inventory', p.purchase_total_cost
           FROM   purchase_fact p
           JOIN   date_dim   d ON d.date_key   = p.date_key
           JOIN   branch_dim b ON b.branch_key = p.branch_key
           WHERE  d.cal_year BETWEEN &start_year AND &end_year
           AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
                  OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%'))
    GROUP  BY br_ID, cal_year
),
-- revenue needs the same state filter, otherwise a filtered-out
-- branch's revenue would still be joined in
revenue_by_year AS (
    SELECT b.br_ID, d.cal_year, SUM(v.amt) AS year_revenue
    FROM  (SELECT o.branch_key AS bk, o.date_key AS dk, o.order_net_amt AS amt
           FROM   order_fact o WHERE o.order_status = 'Completed'
           UNION ALL
           SELECT r.branch_key, r.date_key, r.serv_net_amt
           FROM   reservation_fact r WHERE r.res_status = 'Completed') v
    JOIN   branch_dim b ON b.branch_key = v.bk
    JOIN   date_dim   d ON d.date_key   = v.dk
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    GROUP  BY b.br_ID, d.cal_year
),
-- the rank RESTARTS for each year (PARTITION BY cal_year) so every
-- year is its own league table. Best = biggest surplus of revenue over
-- cost, so the ORDER BY is DESC; NULLS LAST keeps a branch with no
-- revenue at the bottom instead of the top.
ranked AS (
    SELECT c.cal_year, b.br_city,
           c.payroll_cost, c.inventory_cost, c.overhead_cost, c.year_cost,
           NVL(r.year_revenue, 0) AS year_revenue,
           RANK() OVER (PARTITION BY c.cal_year
                        ORDER BY (NVL(r.year_revenue, 0) - c.year_cost)
                                 / NULLIF(c.year_cost, 0) DESC NULLS LAST) AS rank_num
    FROM   cost_by_year c
    JOIN   branch_dim b ON b.br_ID = c.br_ID AND b.is_current_flag = 'Y'
    LEFT   JOIN revenue_by_year r ON r.br_ID = c.br_ID AND r.cal_year = c.cal_year
)
SELECT TO_CHAR(cal_year)                                             AS cal_year,
       TO_CHAR(rank_num)                                             AS rnk,
       br_city,
       payroll_cost,
       inventory_cost,
       overhead_cost,
       year_cost,
       year_revenue,
       ROUND((year_revenue - year_cost) / NULLIF(year_cost, 0) * 100, 1) AS rev_vs_cost
FROM   ranked
ORDER  BY cal_year, rank_num;

PROMPT
PROMPT +==========================================================+
PROMPT |  END OF BRANCH OPERATING COST AND EFFICIENCY REPORT      |
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
UNDEFINE start_year
UNDEFINE end_year
UNDEFINE state
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
