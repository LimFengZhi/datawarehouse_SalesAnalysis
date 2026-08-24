-- ===================================================================
-- 01_branch_profitability.sql
-- GLOW BEAUTY - BRANCH PROFITABILITY
--   every branch ranked on average net profit per year across all
--   five facts, then one branch opened up year by year
--
--   1. BRANCH PROFIT RANKING   every branch, best to worst
--   2. DRILL-DOWN              pick a branch, see it year by year:
--                              order revenue, service revenue, each
--                              cost line, net profit and margin
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\01_branch_profitability.sql
--
-- PARAMETERS (prompted; every one carries a DEFAULT, so Enter through)
--   start year / end year   the analysis period (data runs 2019-2025)
--   TOP or LOWEST           which end of the ranking section 1 shows
--                           (default LOWEST - the branches to worry
--                           about). Anything not starting with T is
--                           read as LOWEST.
--   how many                how many branches to list (default 5)
--   branch                  the branch section 2 opens up, matched on
--                           any part of br_name (default Ipoh finds
--                           'Glow Beauty Ipoh'). Case-insensitive.
--
-- MEASURES  (the five facts, drilled across on date_dim + branch_dim)
--   Order revenue    order_fact.order_net_amt
--   Service revenue  reservation_fact.serv_net_amt
--                    The *_net_amt columns are the stored revenue
--                    measures: total less the 6 % SST, which belongs
--                    to the government and was never the company's
--                    money. Never sum *_total_amt for sales - it is
--                    tax-inclusive. 'Completed' rows only.
--   Purchase cost    purchase_fact.purchase_total_cost
--   Staff cost       salary_payment_fact.base_amt + bonus_amt
--                    (gross pay; deduction_amt is the employee's EPF
--                    share, withheld but still paid by the company)
--   Utility cost     branch_utils_fact.payment_amt
--   Total cost       purchase + staff + utilities (section 2)
--   Net profit       revenue - purchase - staff - utilities
--   Margin %         net profit / revenue x 100
--   Branches are grouped on the NATURAL key br_ID, never branch_key -
--   branch_dim is SCD2 and one branch may own several surrogate rows.
--   Branches are LABELLED by br_name ('Glow Beauty <city>').
--
-- OLAP TECHNIQUES USED
--   CTE (WITH)         both sections
--   CASE WHEN          turns the tagged union into columns, and signs
--                      the measures so net profit is a single SUM
--   RANK               section 1 - the ranking on avg profit per year
--   ROW_NUMBER         section 1 - picks AND sorts the TOP n / LOWEST n
--   COMPUTE AVG        section 1 - average of the rows shown
--   COMPUTE AVG        section 2 - the average-year row
--
-- NOTE  Section 1 ranks on the AVERAGE YEAR, not the period total, so a
--       branch that opened part-way through (Seremban, Kuantan, Subang
--       Jaya and Bukit Jalil all opened 2024-01-01) is not punished for
--       trading fewer years. On totals Kuantan came last and Subang Jaya
--       12th; per year they sit 14th and 3rd, and Ipoh - which has traded
--       all seven years - drops to last, which is the honest answer.
--       The YRS column says how many years each average covers.
--       The one bias this leaves: the seven-year branches carry 2020-21
--       (MCO) in their average and the 2024 openings do not, so the new
--       branches are flattered a little. Rank on MARGIN instead if you
--       need a figure free of both age and lockdown effects.
-- ===================================================================

-- reset anything a previous script left behind in this session
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 120
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

-- SQL*Plus caps an ACCEPT prompt at 99 characters - keep it short.
PROMPT
ACCEPT p_from   CHAR   DEFAULT 2019   PROMPT 'Start year (default 2019): '
ACCEPT p_to     CHAR   DEFAULT 2025   PROMPT 'End year   (default 2025): '
ACCEPT p_order  CHAR   DEFAULT LOWEST PROMPT 'TOP or LOWEST branches (default LOWEST): '
ACCEPT p_topn   CHAR   DEFAULT 5      PROMPT 'How many to show (default 5): '
PROMPT


-- ###################################################################
-- SECTION 1 - BRANCH PROFIT RANKING
-- Every branch over the whole period, ranked by net profit. The five
-- facts collapse into revenue and the three cost lines through one
-- CASE WHEN, and RANK puts the branches in order. Two ROW_NUMBERs -
-- one counting from the best, one from the worst - let the same query
-- serve the TOP n and the LOWEST n. RANK stays chain-wide, so the
-- LOWEST 5 print as ranks 13-17, not 1-5.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. BRANCH PROFIT RANKING' SKIP 1 -
       CENTER '&p_order &p_topn BRANCHES BY AVG NET PROFIT PER YEAR, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN profit_rank HEADING 'RANK'               FORMAT 990
COLUMN br_name     HEADING 'BRANCH'             FORMAT A26
COLUMN yrs         HEADING 'YRS'                FORMAT 90
COLUMN revenue     HEADING 'AVG SALES|PER YEAR' FORMAT 9,999,990
COLUMN purchase    HEADING 'AVG PURCH|PER YEAR' FORMAT 9,999,990
COLUMN staff       HEADING 'AVG STAFF|PER YEAR' FORMAT 9,999,990
COLUMN utility     HEADING 'AVG UTIL|PER YEAR'  FORMAT 999,990
COLUMN profit      HEADING 'AVG PROFIT|PER YEAR' FORMAT S9,999,990
COLUMN margin_pct  HEADING 'MARGIN|%'           FORMAT A8

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF revenue purchase staff utility profit ON REPORT

WITH BRANCH_YEAR AS (
    -- one row per branch PER YEAR, all five facts together
    SELECT b.br_ID,
           b.br_name,
           d.cal_year,
           SUM(CASE WHEN x.measure IN ('PROD_REV', 'SERV_REV') THEN x.amt ELSE 0 END) AS revenue,
           SUM(CASE WHEN x.measure = 'PURCHASE' THEN x.amt ELSE 0 END) AS purchase,
           SUM(CASE WHEN x.measure = 'STAFF'    THEN x.amt ELSE 0 END) AS staff,
           SUM(CASE WHEN x.measure = 'UTILITY'  THEN x.amt ELSE 0 END) AS utility,
           SUM(CASE WHEN x.measure IN ('PROD_REV', 'SERV_REV') THEN x.amt ELSE -x.amt END) AS profit
    FROM   (SELECT f.date_key, f.branch_key, 'PROD_REV' AS measure,
                   f.order_net_amt AS amt
            FROM   order_fact f
            WHERE  f.order_status = 'Completed'
            UNION ALL
            SELECT f.date_key, f.branch_key, 'SERV_REV',
                   f.serv_net_amt
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
BRANCH_PNL AS (
    -- collapse the years into ONE average year per branch. Dividing by
    -- the years a branch actually traded is what makes a 2024 opening
    -- comparable with a branch that has traded since 2019 - on period
    -- totals the new ones look worst purely for being younger.
    -- Margin is unaffected: avg profit / avg revenue = total / total.
    SELECT br_ID, br_name,
           COUNT(*)      AS yrs,
           AVG(revenue)  AS revenue,
           AVG(purchase) AS purchase,
           AVG(staff)    AS staff,
           AVG(utility)  AS utility,
           AVG(profit)   AS profit
    FROM   BRANCH_YEAR
    GROUP  BY br_ID, br_name
),
RANKED AS (
    SELECT br_name,
           yrs,
           revenue,
           purchase,
           staff,
           utility,
           profit,
           RANK()       OVER (ORDER BY profit DESC) AS profit_rank,
           ROW_NUMBER() OVER (ORDER BY profit DESC) AS rn_from_top,
           ROW_NUMBER() OVER (ORDER BY profit ASC)  AS rn_from_bottom
    FROM   BRANCH_PNL
)
SELECT profit_rank,
       br_name,
       yrs,
       revenue,
       purchase,
       staff,
       utility,
       profit,
       TO_CHAR(ROUND(profit / NULLIF(revenue, 0) * 100, 1), 'S990.9') || '%' AS margin_pct
FROM   RANKED
WHERE  CASE WHEN UPPER(TRIM('&p_order')) LIKE 'T%' THEN rn_from_top
            ELSE rn_from_bottom END <= TO_NUMBER('&p_topn')
-- sort to match the end asked for: TOP counts down from the best,
-- LOWEST counts up from the worst, so the branch that matters is
-- always the first row on the page
ORDER  BY CASE WHEN UPPER(TRIM('&p_order')) LIKE 'T%' THEN rn_from_top
               ELSE rn_from_bottom END;


-- ###################################################################
-- SECTION 2 - DRILL-DOWN: ONE BRANCH, YEAR BY YEAR
-- The branch picked above, one row per year: what it sold over the
-- counter, what it sold in the treatment room, what each cost line
-- took out and what was left, closing on the average year.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_branch CHAR DEFAULT 'Ipoh' PROMPT 'Branch to open up (default Ipoh): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. &p_branch YEAR BY YEAR' SKIP 1 -
       CENTER 'SALES, COST AND MARGIN, &p_from - &p_to  (DRILL-DOWN)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN period      HEADING 'YEAR'               FORMAT A9
COLUMN order_rev   HEADING 'ORDER|SALES (RM)'   FORMAT 9,999,990
COLUMN service_rev HEADING 'SERVICE|SALES (RM)' FORMAT 9,999,990
COLUMN revenue     HEADING 'TOTAL|SALES (RM)'   FORMAT 99,999,990
COLUMN purchase    HEADING 'PURCHASE|COST (RM)' FORMAT 9,999,990
COLUMN staff       HEADING 'STAFF|COST (RM)'    FORMAT 9,999,990
COLUMN utility     HEADING 'UTILITY|COST (RM)'  FORMAT 999,990
COLUMN total_cost  HEADING 'TOTAL|COST (RM)'    FORMAT 99,999,990
COLUMN profit      HEADING 'NET|PROFIT (RM)'    FORMAT S9,999,990
COLUMN margin_pct  HEADING 'MARGIN|%'           FORMAT A8

-- COMPUTE is what draws the ---- rule above the average row; a plain
-- UNION ALL row would print with no separator at all
BREAK ON REPORT
COMPUTE AVG LABEL 'AVG/YEAR' OF order_rev service_rev revenue purchase staff utility total_cost profit ON REPORT

WITH BRANCH_YEAR AS (
    -- the same drill-across, this time one row per YEAR for one branch
    SELECT d.cal_year,
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
            SELECT f.date_key, f.branch_key, 'SERV_REV',
                   f.serv_net_amt
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
    -- any part of the branch NAME matches, so 'Ipoh' still finds
    -- 'Glow Beauty Ipoh' and the full name works too
    WHERE  UPPER(b.br_name) LIKE '%' || UPPER(TRIM('&p_branch')) || '%'
    AND    d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    GROUP  BY d.cal_year
)
SELECT TO_CHAR(cal_year) AS period,
       order_rev,
       service_rev,
       order_rev + service_rev AS revenue,
       purchase,
       staff,
       utility,
       purchase + staff + utility AS total_cost,
       order_rev + service_rev - purchase - staff - utility AS profit,
       TO_CHAR(ROUND((order_rev + service_rev - purchase - staff - utility)
                     / NULLIF(order_rev + service_rev, 0) * 100, 1), 'S990.9') || '%' AS margin_pct
FROM   BRANCH_YEAR
ORDER  BY cal_year;

PROMPT
PROMPT +==========================================================+
PROMPT |        END OF BRANCH PROFITABILITY REPORT                |
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
UNDEFINE p_order
UNDEFINE p_topn
UNDEFINE p_branch
SET FEEDBACK ON
SET VERIFY ON
