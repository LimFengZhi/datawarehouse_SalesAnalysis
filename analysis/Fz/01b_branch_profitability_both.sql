-- ===================================================================
-- 01b_branch_profitability_both.sql
-- GLOW BEAUTY - BRANCH PROFITABILITY: THE WHOLE CHAIN, BEST TO WORST
--   every branch on one ranked list, then any branch opened up year
--   by year
--
--   1. ALL BRANCHES RANKED  rank 1 (best) down to the last (worst),
--                           so the strong end and the weak end are
--                           read off the SAME list
--   2. DRILL-DOWN           pick any branch, see it year by year
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\01b_branch_profitability_both.sql
--
-- PARAMETERS (prompted; every one carries a DEFAULT, so Enter through)
--   start year / end year   the analysis period (data runs 2019-2025)
--   branch                  the branch section 2 opens up, matched on
--                           any part of br_name (default Ipoh finds
--                           'Glow Beauty Ipoh'). Case-insensitive.
--   There is NO "how many" prompt - section 1 always lists every
--   branch, so nothing is hidden behind a TOP n cut-off.
--
-- HOW THE CODE IS BUILT
--   The five-fact drill-across is written as a WITH clause (subquery
--   factoring) inside each section:
--     pnl_year    one row per branch per YEAR (the raw grain)
--     pnl_branch  one row per BRANCH, averaged over its trading years
--   Section 1 ranks pnl_branch; section 2 reads the year grain for one
--   branch. No views are created, so an aborted run leaves nothing
--   behind in the schema and the script needs no clean-up DDL.
--
-- MEASURES  (the five facts, drilled across on date_dim + branch_dim)
--   Order revenue    order_fact.order_net_amt
--   Service revenue  reservation_fact.serv_net_amt
--                    The *_net_amt columns are the stored revenue
--                    measures: total less the 6 % SST, which belongs
--                    to the government. 'Completed' rows only.
--   Purchase cost    purchase_fact.purchase_total_cost
--   Staff cost       salary_payment_fact.base_amt + bonus_amt
--   Utility cost     branch_utils_fact.payment_amt
--   Total cost       purchase + staff + utilities, the three cost
--                    lines added up (section 1 shows the average
--                    year, section 2 the year itself)
--   Purch % revenue  purchase cost / revenue x 100 - how much of
--                    every ringgit of revenue goes on buying stock
--   Net profit       revenue - purchase - staff - utilities
--   Margin %         net profit / revenue x 100
--   Branches are grouped on the NATURAL key br_ID (branch_dim is
--   SCD2, so one branch may own several surrogate rows) and are
--   labelled by br_name ('Glow Beauty <city>').
--
-- OLAP TECHNIQUES USED
--   WITH               the shared drill-across, named once per query
--   INLINE VIEW        the per-branch averaging feeding the ranking
--   CASE WHEN          turns the tagged union into columns
--   RANK               the chain-wide position, 1 = most profitable
--   COMPUTE AVG        the chain average under the list
--
-- NOTE  Ranking is on the AVERAGE YEAR, not the period total, so a
--       branch that opened part-way through (Seremban, Kuantan,
--       Subang Jaya and Bukit Jalil all opened 2024-01-01) is not
--       punished for trading fewer years. The YRS column says how
--       many years each average covers.
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
SET SQLBLANKLINES ON

PROMPT
ACCEPT p_from CHAR DEFAULT 2019 PROMPT 'Start year (default 2019): '
ACCEPT p_to   CHAR DEFAULT 2025 PROMPT 'End year   (default 2025): '
PROMPT


-- ###################################################################
-- SECTION 1 - EVERY BRANCH, RANKED ON AVG NET PROFIT PER YEAR
-- One list, best to worst. Rank 1 is the branch to learn from and the
-- last row is the branch to fix - no TOP n prompt, nothing hidden.
-- ###################################################################
COLUMN profit_rank  HEADING 'RANK'                FORMAT 990
COLUMN br_name      HEADING 'BRANCH'              FORMAT A26
COLUMN yrs          HEADING 'YRS'                 FORMAT 90
COLUMN avg_revenue  HEADING 'AVG REVENUE|PER YEAR' FORMAT 9,999,990
COLUMN avg_purchase HEADING 'AVG PURCH|PER YEAR'  FORMAT 9,999,990
COLUMN purch_pct    HEADING 'PURCH|% REVENUE'     FORMAT 990.9
COLUMN avg_staff    HEADING 'AVG STAFF|PER YEAR'  FORMAT 9,999,990
COLUMN avg_utility  HEADING 'AVG UTIL|PER YEAR'   FORMAT 999,990
COLUMN avg_cost     HEADING 'AVG TOTAL|COST/YEAR' FORMAT 9,999,990
COLUMN avg_profit   HEADING 'AVG PROFIT|PER YEAR' FORMAT S9,999,990
COLUMN margin_pct   HEADING 'MARGIN|%'            FORMAT A8

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF avg_revenue avg_purchase purch_pct avg_staff avg_utility avg_cost avg_profit ON REPORT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. ALL BRANCHES RANKED' SKIP 1 -
       CENTER 'BY AVG NET PROFIT PER YEAR, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

WITH pnl_year AS (
    SELECT b.br_ID   AS br_id,
           b.br_name AS br_name,
           d.cal_year,
           SUM(CASE WHEN x.measure = 'PROD_REV' THEN x.amt ELSE 0 END) AS order_rev,
           SUM(CASE WHEN x.measure = 'SERV_REV' THEN x.amt ELSE 0 END) AS service_rev,
           SUM(CASE WHEN x.measure = 'PURCHASE' THEN x.amt ELSE 0 END) AS purchase,
           SUM(CASE WHEN x.measure = 'STAFF'    THEN x.amt ELSE 0 END) AS staff,
           SUM(CASE WHEN x.measure = 'UTILITY'  THEN x.amt ELSE 0 END) AS utility
    FROM   (SELECT f.date_key, f.branch_key, 'PROD_REV' AS measure,
                   f.order_net_amt AS amt
            FROM   order_fact f
            WHERE  f.order_status = 'Completed'
            UNION ALL
            SELECT f.date_key, f.branch_key, 'SERV_REV', f.serv_net_amt
            FROM   reservation_fact f
            WHERE  f.res_status = 'Completed'
            UNION ALL
            SELECT f.date_key, f.branch_key, 'PURCHASE', f.purchase_total_cost
            FROM   purchase_fact f
            UNION ALL
            SELECT f.date_key, f.branch_key, 'STAFF', f.base_amt + f.bonus_amt
            FROM   salary_payment_fact f
            UNION ALL
            SELECT f.date_key, f.branch_key, 'UTILITY', f.payment_amt
            FROM   branch_utils_fact f) x
    JOIN   date_dim   d ON d.date_key   = x.date_key
    JOIN   branch_dim b ON b.branch_key = x.branch_key
    WHERE  d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    GROUP  BY b.br_ID, b.br_name, d.cal_year
),
pnl_branch AS (
    SELECT br_id,
           br_name,
           COUNT(*)                          AS yrs,
           AVG(order_rev + service_rev)      AS avg_revenue,
           AVG(purchase)                     AS avg_purchase,
           AVG(staff)                        AS avg_staff,
           AVG(utility)                      AS avg_utility,
           AVG(order_rev + service_rev
               - purchase - staff - utility) AS avg_profit
    FROM   pnl_year
    GROUP  BY br_id, br_name
)
SELECT RANK() OVER (ORDER BY avg_profit DESC) AS profit_rank,
       br_name,
       yrs,
       avg_revenue,
       avg_purchase,
       ROUND(avg_purchase / NULLIF(avg_revenue, 0) * 100, 1) AS purch_pct,
       avg_staff,
       avg_utility,
       avg_purchase + avg_staff + avg_utility AS avg_cost,
       avg_profit,
       TO_CHAR(ROUND(avg_profit / NULLIF(avg_revenue, 0) * 100, 1),
               'S990.9') || '%' AS margin_pct
FROM   pnl_branch
ORDER  BY avg_profit DESC;


-- ###################################################################
-- SECTION 2 - DRILL-DOWN: ONE BRANCH, YEAR BY YEAR
-- The same drill-across, stopped at the YEAR grain, so the numbers can
-- never disagree with the list above.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_branch CHAR DEFAULT 'Ipoh' PROMPT 'Branch to open up (default Ipoh): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. &p_branch YEAR BY YEAR' SKIP 1 -
       CENTER 'REVENUE, COST AND MARGIN, &p_from - &p_to  (DRILL-DOWN)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN period      HEADING 'YEAR'               FORMAT A9
COLUMN order_rev   HEADING 'ORDER|REVENUE (RM)'   FORMAT 9,999,990
COLUMN service_rev HEADING 'SERVICE|REVENUE (RM)' FORMAT 9,999,990
COLUMN revenue     HEADING 'TOTAL|REVENUE (RM)'   FORMAT 99,999,990
COLUMN purchase    HEADING 'PURCHASE|COST (RM)' FORMAT 9,999,990
COLUMN purch_pct   HEADING 'PURCH|% REVENUE'     FORMAT 990.9
COLUMN staff       HEADING 'STAFF|COST (RM)'    FORMAT 9,999,990
COLUMN utility     HEADING 'UTILITY|COST (RM)'  FORMAT 999,990
COLUMN total_cost  HEADING 'TOTAL|COST (RM)'    FORMAT 99,999,990
COLUMN profit      HEADING 'NET|PROFIT (RM)'    FORMAT S9,999,990
COLUMN margin_pct  HEADING 'MARGIN|%'           FORMAT A8

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG/YEAR' OF order_rev service_rev revenue purchase purch_pct staff utility total_cost profit ON REPORT

WITH pnl_year AS (
    SELECT b.br_ID   AS br_id,
           b.br_name AS br_name,
           d.cal_year,
           SUM(CASE WHEN x.measure = 'PROD_REV' THEN x.amt ELSE 0 END) AS order_rev,
           SUM(CASE WHEN x.measure = 'SERV_REV' THEN x.amt ELSE 0 END) AS service_rev,
           SUM(CASE WHEN x.measure = 'PURCHASE' THEN x.amt ELSE 0 END) AS purchase,
           SUM(CASE WHEN x.measure = 'STAFF'    THEN x.amt ELSE 0 END) AS staff,
           SUM(CASE WHEN x.measure = 'UTILITY'  THEN x.amt ELSE 0 END) AS utility
    FROM   (SELECT f.date_key, f.branch_key, 'PROD_REV' AS measure,
                   f.order_net_amt AS amt
            FROM   order_fact f
            WHERE  f.order_status = 'Completed'
            UNION ALL
            SELECT f.date_key, f.branch_key, 'SERV_REV', f.serv_net_amt
            FROM   reservation_fact f
            WHERE  f.res_status = 'Completed'
            UNION ALL
            SELECT f.date_key, f.branch_key, 'PURCHASE', f.purchase_total_cost
            FROM   purchase_fact f
            UNION ALL
            SELECT f.date_key, f.branch_key, 'STAFF', f.base_amt + f.bonus_amt
            FROM   salary_payment_fact f
            UNION ALL
            SELECT f.date_key, f.branch_key, 'UTILITY', f.payment_amt
            FROM   branch_utils_fact f) x
    JOIN   date_dim   d ON d.date_key   = x.date_key
    JOIN   branch_dim b ON b.branch_key = x.branch_key
    WHERE  d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    GROUP  BY b.br_ID, b.br_name, d.cal_year
)
SELECT TO_CHAR(cal_year) AS period,
       SUM(order_rev)               AS order_rev,
       SUM(service_rev)             AS service_rev,
       SUM(order_rev + service_rev) AS revenue,
       SUM(purchase)                AS purchase,
       ROUND(SUM(purchase)
             / NULLIF(SUM(order_rev + service_rev), 0) * 100, 1) AS purch_pct,
       SUM(staff)                   AS staff,
       SUM(utility)                 AS utility,
       SUM(purchase + staff + utility) AS total_cost,
       SUM(order_rev + service_rev - purchase - staff - utility) AS profit,
       TO_CHAR(ROUND(SUM(order_rev + service_rev - purchase - staff - utility)
                     / NULLIF(SUM(order_rev + service_rev), 0) * 100, 1),
               'S990.9') || '%' AS margin_pct
FROM   pnl_year
WHERE  UPPER(br_name) LIKE '%' || UPPER(TRIM('&p_branch')) || '%'
GROUP  BY cal_year
ORDER  BY cal_year;

PROMPT
PROMPT Report Completed
PROMPT

-- ===================================================================
-- tidy up: nothing to drop - this script creates no database objects
-- ===================================================================
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE p_from
UNDEFINE p_to
UNDEFINE p_branch
SET FEEDBACK ON
SET VERIFY ON
SET SQLBLANKLINES OFF
