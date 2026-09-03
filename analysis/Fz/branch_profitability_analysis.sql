-- ===================================================================
-- 01b_branch_profitability_both.sql
-- GLOW BEAUTY - BRANCH PROFITABILITY: THE WHOLE CHAIN, BEST TO WORST
--   every branch on one ranked list, then any branch opened up year
--   by year
--
--   1. BRANCHES RANKED      HIGHEST or LOWEST profit first, as many
--                           as asked for (default: all 17, best to
--                           worst). RANK stays chain-wide, so the
--                           LOWEST 5 print as ranks 13-17, not 1-5.
--   2. DRILL-DOWN           pick any branch, see it year by year
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\01b_branch_profitability_both.sql
--
-- PARAMETERS (prompted; every one carries a DEFAULT, so Enter through)
--   start year / end year   the analysis period (data runs 2019-2025)
--   HIGHEST or LOWEST       which end of the ranking section 1 shows
--                           first (default HIGHEST - best branch on
--                           top; anything not starting with H reads
--                           as LOWEST)
--   how many                branches to list: a number, or ALL. The
--                           default 17 covers the whole chain, so
--                           Enter-through shows every branch. Typing
--                           ALL, or a number >= the branch_dim branch
--                           count, retitles the list 'ALL BRANCHES'.
--   branch                  the branch section 2 opens up, matched on
--                           any part of br_name (default Ipoh finds
--                           'Glow Beauty Ipoh'). Case-insensitive.
--
-- HOW THE CODE IS BUILT
--   The five-fact drill-across is written ONCE, as a TEMPORARY helper
--   view created at the top of this script and dropped at the bottom:
--     branch_pnl_year_v   one row per branch per YEAR (the raw grain)
--   Both sections query it, so the numbers can never disagree and the
--   drill-across is not repeated inside each query (how this file
--   used to look). The script is self-contained - it needs nothing
--   pre-created and leaves nothing behind on a COMPLETE run.
--
--   CAVEAT of the create-and-drop pattern: abort the run part-way
--   (Ctrl+C, closing the window at a prompt) and branch_pnl_year_v is
--   left in the schema. That is harmless - the next full run replaces
--   and drops it, or clear it by hand:  DROP VIEW branch_pnl_year_v;
--   (The separate visualisation script's viz01b_branch_pnl_v is a
--   PERMANENT chart-feed view and is not touched by this report.)
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
--   Branches are grouped on the NATURAL key br_ID and labelled by
--   br_name ('Glow Beauty <city>'). branch_dim is no longer SCD2 -
--   one row per branch - so the grouping is now just tidy.
--
-- OLAP TECHNIQUES USED
--   VIEW               branch_pnl_year_v, the shared drill-across
--                      (created by THIS script, dropped at the end)
--   CASE WHEN          turns the tagged five-fact union into columns
--   WITH               the per-branch averaging feeding the ranking
--   RANK               the chain-wide position, 1 = most profitable
--   ROW_NUMBER         one counting from the best, one from the worst,
--                      so the same query serves HIGHEST n and LOWEST n
--   COMPUTE AVG        the average of the LISTED branches (= the chain
--                      average when all 17 are shown)
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
ACCEPT p_from  CHAR DEFAULT 2021    PROMPT 'Start year (default 2021): '
ACCEPT p_to    CHAR DEFAULT 2025    PROMPT 'End year   (default 2025): '
ACCEPT p_order CHAR DEFAULT HIGHEST PROMPT 'HIGHEST or LOWEST profit first (default HIGHEST): '
ACCEPT p_topn  CHAR DEFAULT 5      PROMPT 'How many branches to show (a number or ALL): '
PROMPT


-- ###################################################################
-- SECTION 0 - THE SHARED DRILL-ACROSS, AS A TEMPORARY HELPER VIEW
-- Created here, read by both sections, DROPPED at the bottom of this
-- script. One row per branch per YEAR, the five facts drilled across
-- as a tagged UNION ALL pivoted into columns by CASE WHEN. The year
-- prompts are NOT baked in - the queries filter, so the view text is
-- identical on every run.
-- ###################################################################
CREATE OR REPLACE VIEW branch_pnl_year_v AS
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
GROUP  BY b.br_ID, b.br_name, d.cal_year;


-- ###################################################################
-- SECTION 1 - BRANCHES RANKED ON AVG NET PROFIT PER YEAR
-- HIGHEST or LOWEST first, as many as asked for (default all 17).
-- Two ROW_NUMBERs - one counting from the best, one from the worst -
-- let the same query serve both ends; RANK stays chain-wide, so the
-- LOWEST 5 print as ranks 13-17, not 1-5, and the branch that matters
-- is always the FIRST row on the page.
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

-- -------------------------------------------------------------------
-- Build the title's scope label BEFORE the TTITLE that uses it.
-- COLUMN ... NEW_VALUE copies the query result into the substitution
-- variable p_scope. Typing ALL, or any number >= the branch count in
-- branch_dim (DISTINCT br_ID; one row per branch now), makes
-- the title read 'ALL BRANCHES'; a smaller number keeps the end and
-- the count, e.g. 'LOWEST 5 BRANCHES'. CASE tests in order, so the
-- TO_NUMBER in the second test never sees the word ALL.
-- -------------------------------------------------------------------
SET TERMOUT OFF
COLUMN scope_lbl NEW_VALUE p_scope NOPRINT
SELECT CASE
         WHEN UPPER(TRIM('&p_topn')) = 'ALL' THEN 'ALL BRANCHES'
         WHEN TO_NUMBER(TRIM('&p_topn')) >=
              (SELECT COUNT(DISTINCT br_ID) FROM branch_dim)
           THEN 'ALL BRANCHES'
         ELSE UPPER(TRIM('&p_order')) || ' ' || TRIM('&p_topn')
              || ' BRANCHES'
       END AS scope_lbl
FROM   dual;
SET TERMOUT ON

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. BRANCHES RANKED' SKIP 1 -
       CENTER '&p_scope BY AVG NET PROFIT PER YEAR, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

-- branch_pnl_year_v (SECTION 0) is one row per branch per YEAR, so
-- the AVG over the filtered years IS the report's average-year
-- measure.
WITH pnl_branch AS (
    SELECT v.br_id,
           v.br_name,
           COUNT(*)                         AS yrs,
           AVG(v.order_rev + v.service_rev) AS avg_revenue,
           AVG(v.purchase)                  AS avg_purchase,
           AVG(v.staff)                     AS avg_staff,
           AVG(v.utility)                   AS avg_utility,
           AVG(v.order_rev + v.service_rev
               - v.purchase - v.staff - v.utility) AS avg_profit
    FROM   branch_pnl_year_v v
    WHERE  v.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    GROUP  BY v.br_id, v.br_name
),
ranked AS (
    SELECT pnl_branch.*,
           RANK()       OVER (ORDER BY avg_profit DESC) AS profit_rank,
           ROW_NUMBER() OVER (ORDER BY avg_profit DESC) AS rn_from_top,
           ROW_NUMBER() OVER (ORDER BY avg_profit ASC)  AS rn_from_bottom
    FROM   pnl_branch
)
SELECT profit_rank,
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
FROM   ranked
-- ALL bypasses the cut-off; CASE short-circuits, so TO_NUMBER never
-- sees the word ALL
WHERE  CASE WHEN UPPER(TRIM('&p_order')) LIKE 'H%' THEN rn_from_top
            ELSE rn_from_bottom END
       <= CASE WHEN UPPER(TRIM('&p_topn')) = 'ALL' THEN 999999
               ELSE TO_NUMBER(TRIM('&p_topn')) END
-- sort to match the end asked for: HIGHEST counts down from the best,
-- LOWEST counts up from the worst, so the branch that matters is
-- always the first row on the page
ORDER  BY CASE WHEN UPPER(TRIM('&p_order')) LIKE 'H%' THEN rn_from_top
               ELSE rn_from_bottom END;


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

-- Same view, stopped at the YEAR grain. The GROUP BY stays: a loose
-- branch match ('Glow') can hit several branches, and this report has
-- always folded them into one line per year - the ratios are therefore
-- recomputed from the summed columns.
SELECT TO_CHAR(v.cal_year) AS period,
       SUM(v.order_rev)     AS order_rev,
       SUM(v.service_rev)   AS service_rev,
       SUM(v.order_rev + v.service_rev) AS revenue,
       SUM(v.purchase)      AS purchase,
       ROUND(SUM(v.purchase)
             / NULLIF(SUM(v.order_rev + v.service_rev), 0) * 100, 1) AS purch_pct,
       SUM(v.staff)         AS staff,
       SUM(v.utility)       AS utility,
       SUM(v.purchase + v.staff + v.utility) AS total_cost,
       SUM(v.order_rev + v.service_rev
           - v.purchase - v.staff - v.utility) AS profit,
       TO_CHAR(ROUND(SUM(v.order_rev + v.service_rev
                         - v.purchase - v.staff - v.utility)
                     / NULLIF(SUM(v.order_rev + v.service_rev), 0) * 100, 1),
               'S990.9') || '%' AS margin_pct
FROM   branch_pnl_year_v v
WHERE  UPPER(v.br_name) LIKE '%' || UPPER(TRIM('&p_branch')) || '%'
AND    v.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
GROUP  BY v.cal_year
ORDER  BY v.cal_year;

PROMPT
PROMPT Report Completed
PROMPT

-- ===================================================================
-- tidy up: drop the temporary helper view from SECTION 0. If a run
-- was aborted before reaching this line, the view survives - the next
-- complete run replaces and drops it. viz01b_branch_pnl_v (the
-- visualisation script's PERMANENT view) is deliberately not touched.
-- ===================================================================
DROP VIEW branch_pnl_year_v;
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE p_from
UNDEFINE p_to
UNDEFINE p_order
UNDEFINE p_topn
UNDEFINE p_scope
UNDEFINE p_branch
SET FEEDBACK ON
SET VERIFY ON
SET SQLBLANKLINES OFF
