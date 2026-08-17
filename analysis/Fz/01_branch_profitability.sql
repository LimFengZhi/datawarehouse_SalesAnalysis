-- ===================================================================
-- 01_branch_profitability.sql
-- SALES ANALYSIS - BRANCH PROFITABILITY
--   best year per branch  ->  focus year  ->  best branch  ->  why
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\laoli\Downloads\datawarehouseAnalysis\analysis\Fz\01_branch_profitability.sql
--
-- PARAMETER (prompted)
--   focus year   the year to zoom into, default 2025
--
-- WHAT IT ANSWERS
--   1. Which year was the most profitable for EACH branch?
--   2. In the focus year, WHICH BRANCH made the most profit?
--   3. WHY - which quarters carried it, and where did the money go?
--
--       NET PROFIT = REVENUE - SALARY COST - BRANCH EXPENSES
--
--   where  REVENUE      = product sales (order_fact)
--                       + service sales (reservation_fact)
--          SALARY COST  = payroll paid to that branch's staff
--                         (salary_payment_fact)
--          EXPENSES     = rent, utilities etc. (branch_expense_fact)
--
-- DIMENSIONS USED  (three)
--   date_dim          cal_year, cal_quarter          -> the drill path
--   branch_dim        br_ID, br_city                 -> the rows
--   branch_utils_dim  util_name                      -> expense split
--   plus a drill-ACROSS of four fact tables on those conformed dims:
--   order_fact, reservation_fact, salary_payment_fact,
--   branch_expense_fact.
--
-- REPORT SECTIONS  (the drill-down path)
--   1  COMPANY PROFIT PER YEAR             2019-2025 overview
--   2  BEST YEAR PER BRANCH                years ACROSS, one row per
--                                          branch -> picks the year
--   3  FOCUS YEAR - BRANCH RANKING         which branch is #1
--   4A FOCUS YEAR - REVENUE BY QUARTER     drill year -> quarter
--   4B FOCUS YEAR - NET PROFIT BY QUARTER
--   5  FOCUS YEAR - EXPENSES BY CATEGORY   3rd dimension
--   6  SUMMARY STATISTICS
--   Sections 1, 2, 4 and 6 roll up from the SAME quarter-grain base
--   query (WITH pnl AS ...), so the totals reconcile across sections.
--
-- MEASURE DEFINITIONS
--   Revenue     = gross - discount, EXCLUDING tax (SST is passed on to
--                 the government, it is not income). Only COMPLETED
--                 orders / reservations count.
--   Salary cost = gross_amount (base + bonus). The deduction column is
--                 EPF withheld from the employee - it still costs the
--                 company, so it is NOT subtracted.
--   Expenses    = payment_amount for every utility category.
--   Margin %    = net profit / revenue * 100
--
--   All facts are grouped on the branch NATURAL key (br_ID), not the
--   surrogate branch_key - branch_dim is SCD2, so one branch could
--   own several branch_key rows and must still roll up as one line.
--
-- WHAT TO LOOK FOR
--   - Section 2: 2020 or 2021 is the WORST year on every branch
--     (MCO / FMCO - salons closed, payroll only partly cut); 2025 is
--     the BEST year on most branches after two rounds of price rises
--   - Section 3: Kuala Lumpur should rank #1, Melaka last
--   - Section 4: the quarterly shape shows Q4 strongest (festive
--     season + 13th-month bonus lands in salary the same quarter)
--   - Section 5: rent is by far the largest expense line
--   - Run again with focus year 2023 to see Ipoh's opening-quarter
--     LOSS (staff paid from Feb, doors open 1 March)
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

ACCEPT focus_year NUMBER DEFAULT 2025 PROMPT 'Enter the focus year to zoom into (default 2025): '

-- ---- values reused in every title ---------------------------------
-- TERMOUT OFF hides these helper queries (only works when the file is
-- run with @, which is how this report is meant to be run). TO_CHAR
-- keeps the number from being captured with leading spaces.
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN focus_y NEW_VALUE focus_y NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL branch_profitability_output.txt


-- ###################################################################
-- SECTION 1 - COMPANY PROFIT PER YEAR
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. COMPANY PROFIT PER YEAR' SKIP 1 -
       CENTER 'ALL BRANCHES, 2019 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year      HEADING 'YEAR'                FORMAT 9999
COLUMN product_rev   HEADING 'PRODUCT|REV (RM)'    FORMAT 999,999,990.00
COLUMN service_rev   HEADING 'SERVICE|REV (RM)'    FORMAT 999,999,990.00
COLUMN total_rev     HEADING 'TOTAL|REVENUE (RM)'  FORMAT 999,999,990.00
COLUMN salary_cost   HEADING 'SALARY|COST (RM)'    FORMAT 999,999,990.00
COLUMN expense_cost  HEADING 'BRANCH|EXPENSE (RM)' FORMAT 999,999,990.00
COLUMN net_profit    HEADING 'NET|PROFIT (RM)'     FORMAT S99,999,990.00
COLUMN margin_pct    HEADING 'MARGIN|%'            FORMAT S990.0
COLUMN yoy_pct       HEADING 'PROFIT|YOY %'        FORMAT S990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF product_rev service_rev total_rev salary_cost expense_cost net_profit ON REPORT

WITH pnl AS (
    -- quarter-grain base: one row per branch / year / quarter with all
    -- four measures already side by side
    SELECT br_ID, br_city, cal_year, cal_quarter,
           SUM(product_rev)  AS product_rev,
           SUM(service_rev)  AS service_rev,
           SUM(salary_cost)  AS salary_cost,
           SUM(expense_cost) AS expense_cost
    FROM (
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               SUM(f.order_gross_amt - f.order_discount_amt) AS product_rev,
               0 AS service_rev, 0 AS salary_cost, 0 AS expense_cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, SUM(f.serv_price - f.serv_discount_amt), 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, 0, SUM(f.gross_amount), 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, 0, 0, SUM(f.payment_amount)
        FROM   branch_expense_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
    )
    GROUP BY br_ID, br_city, cal_year, cal_quarter
),
company_year AS (
    SELECT cal_year,
           SUM(product_rev)                     AS product_rev,
           SUM(service_rev)                     AS service_rev,
           SUM(product_rev) + SUM(service_rev)  AS total_rev,
           SUM(salary_cost)                     AS salary_cost,
           SUM(expense_cost)                    AS expense_cost,
           SUM(product_rev) + SUM(service_rev)
             - SUM(salary_cost) - SUM(expense_cost) AS net_profit
    FROM   pnl
    GROUP  BY cal_year
)
SELECT cal_year, product_rev, service_rev, total_rev, salary_cost, expense_cost, net_profit,
       ROUND(net_profit / NULLIF(total_rev, 0) * 100, 1)                        AS margin_pct,
       ROUND( (net_profit - LAG(net_profit) OVER (ORDER BY cal_year))
             / NULLIF(ABS(LAG(net_profit) OVER (ORDER BY cal_year)), 0) * 100, 1) AS yoy_pct
FROM   company_year
ORDER  BY cal_year;


-- ###################################################################
-- SECTION 2 - BEST YEAR PER BRANCH  (net profit, years across)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. WHICH YEAR WAS MOST PROFITABLE FOR EACH BRANCH?' SKIP 1 -
       CENTER 'NET PROFIT (RM) PER YEAR, 2019 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city   HEADING 'BRANCH'      FORMAT A15
COLUMN y2019     HEADING '2019'        FORMAT S9,999,990.00
COLUMN y2020     HEADING '2020'        FORMAT S9,999,990.00
COLUMN y2021     HEADING '2021'        FORMAT S9,999,990.00
COLUMN y2022     HEADING '2022'        FORMAT S9,999,990.00
COLUMN y2023     HEADING '2023'        FORMAT S9,999,990.00
COLUMN y2024     HEADING '2024'        FORMAT S9,999,990.00
COLUMN y2025     HEADING '2025'        FORMAT S9,999,990.00
COLUMN best_yr   HEADING 'BEST|YEAR'   FORMAT 9999
COLUMN worst_yr  HEADING 'WORST|YEAR'  FORMAT 9999
COLUMN br_ID     NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL BRANCHES' OF y2019 y2020 y2021 y2022 y2023 y2024 y2025 ON REPORT

WITH pnl AS (
    SELECT br_ID, br_city, cal_year, cal_quarter,
           SUM(product_rev)  AS product_rev,
           SUM(service_rev)  AS service_rev,
           SUM(salary_cost)  AS salary_cost,
           SUM(expense_cost) AS expense_cost
    FROM (
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               SUM(f.order_gross_amt - f.order_discount_amt) AS product_rev,
               0 AS service_rev, 0 AS salary_cost, 0 AS expense_cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, SUM(f.serv_price - f.serv_discount_amt), 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, 0, SUM(f.gross_amount), 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, 0, 0, SUM(f.payment_amount)
        FROM   branch_expense_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
    )
    GROUP BY br_ID, br_city, cal_year, cal_quarter
),
branch_year AS (
    SELECT br_ID, br_city, cal_year,
           SUM(product_rev) + SUM(service_rev)
             - SUM(salary_cost) - SUM(expense_cost) AS net_profit
    FROM   pnl
    GROUP  BY br_ID, br_city, cal_year
)
SELECT br_city,
       -- years across. No ELSE, so a year the branch did not trade
       -- (Ipoh before 2023) prints blank instead of 0.00
       SUM(CASE WHEN cal_year = 2019 THEN net_profit END) AS y2019,
       SUM(CASE WHEN cal_year = 2020 THEN net_profit END) AS y2020,
       SUM(CASE WHEN cal_year = 2021 THEN net_profit END) AS y2021,
       SUM(CASE WHEN cal_year = 2022 THEN net_profit END) AS y2022,
       SUM(CASE WHEN cal_year = 2023 THEN net_profit END) AS y2023,
       SUM(CASE WHEN cal_year = 2024 THEN net_profit END) AS y2024,
       SUM(CASE WHEN cal_year = 2025 THEN net_profit END) AS y2025,
       MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY net_profit DESC) AS best_yr,
       MIN(cal_year) KEEP (DENSE_RANK LAST  ORDER BY net_profit DESC) AS worst_yr,
       br_ID
FROM   branch_year
GROUP  BY br_ID, br_city
ORDER  BY br_ID;


-- ###################################################################
-- SECTION 3 - FOCUS YEAR: WHICH BRANCH MADE THE MOST?
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. FOCUS YEAR &focus_y: BRANCH RANKING BY NET PROFIT' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk           HEADING 'RANK'                FORMAT 99
COLUMN br_city       HEADING 'BRANCH'              FORMAT A15
COLUMN total_rev     HEADING 'TOTAL|REVENUE (RM)'  FORMAT 999,999,990.00
COLUMN salary_cost   HEADING 'SALARY|COST (RM)'    FORMAT 999,999,990.00
COLUMN expense_cost  HEADING 'BRANCH|EXPENSE (RM)' FORMAT 999,999,990.00
COLUMN net_profit    HEADING 'NET|PROFIT (RM)'     FORMAT S99,999,990.00
COLUMN margin_pct    HEADING 'MARGIN|%'            FORMAT S990.0
COLUMN share_pct     HEADING 'SHARE OF|PROFIT %'   FORMAT 990.0
COLUMN vs_prior_pct  HEADING 'VS PRIOR|YEAR %'     FORMAT S990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF total_rev salary_cost expense_cost net_profit ON REPORT

WITH pnl AS (
    SELECT br_ID, br_city, cal_year,
           SUM(product_rev)  AS product_rev,
           SUM(service_rev)  AS service_rev,
           SUM(salary_cost)  AS salary_cost,
           SUM(expense_cost) AS expense_cost
    FROM (
        SELECT b.br_ID, b.br_city, d.cal_year,
               SUM(f.order_gross_amt - f.order_discount_amt) AS product_rev,
               0 AS service_rev, 0 AS salary_cost, 0 AS expense_cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year,
               0, SUM(f.serv_price - f.serv_discount_amt), 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year,
               0, 0, SUM(f.gross_amount), 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year,
               0, 0, 0, SUM(f.payment_amount)
        FROM   branch_expense_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year
    )
    GROUP BY br_ID, br_city, cal_year
),
branch_year AS (
    -- prior-year profit is looked up BEFORE filtering to the focus
    -- year, otherwise LAG would have nothing to look back to
    SELECT br_ID, br_city, cal_year,
           product_rev + service_rev                              AS total_rev,
           salary_cost, expense_cost,
           product_rev + service_rev - salary_cost - expense_cost AS net_profit,
           LAG(product_rev + service_rev - salary_cost - expense_cost)
               OVER (PARTITION BY br_ID ORDER BY cal_year)         AS prior_profit
    FROM   pnl
)
SELECT RANK() OVER (ORDER BY net_profit DESC)                            AS rnk,
       br_city, total_rev, salary_cost, expense_cost, net_profit,
       ROUND(net_profit / NULLIF(total_rev, 0) * 100, 1)                 AS margin_pct,
       ROUND(RATIO_TO_REPORT(net_profit) OVER () * 100, 1)               AS share_pct,
       ROUND((net_profit - prior_profit) / NULLIF(ABS(prior_profit), 0) * 100, 1) AS vs_prior_pct
FROM   branch_year
WHERE  cal_year = &focus_year
ORDER  BY rnk;


-- ###################################################################
-- SECTION 4A - FOCUS YEAR: REVENUE BY QUARTER  (drill year -> quarter)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4A. FOCUS YEAR &focus_y: REVENUE BY QUARTER' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city   HEADING 'BRANCH'          FORMAT A15
COLUMN q1        HEADING 'Q1 (RM)'         FORMAT 99,999,990.00
COLUMN q2        HEADING 'Q2 (RM)'         FORMAT 99,999,990.00
COLUMN q3        HEADING 'Q3 (RM)'         FORMAT 99,999,990.00
COLUMN q4        HEADING 'Q4 (RM)'         FORMAT 99,999,990.00
COLUMN yr_total  HEADING 'YEAR|TOTAL (RM)' FORMAT 999,999,990.00
COLUMN br_ID     NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL BRANCHES' OF q1 q2 q3 q4 yr_total ON REPORT

WITH rev AS (
    SELECT b.br_ID, b.br_city, d.cal_quarter,
           SUM(f.order_gross_amt - f.order_discount_amt) AS amt
    FROM   order_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year = &focus_year
    GROUP  BY b.br_ID, b.br_city, d.cal_quarter
    UNION ALL
    SELECT b.br_ID, b.br_city, d.cal_quarter,
           SUM(f.serv_price - f.serv_discount_amt)
    FROM   reservation_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year = &focus_year
    GROUP  BY b.br_ID, b.br_city, d.cal_quarter
)
SELECT br_city,
       SUM(CASE WHEN cal_quarter = 1 THEN amt ELSE 0 END) AS q1,
       SUM(CASE WHEN cal_quarter = 2 THEN amt ELSE 0 END) AS q2,
       SUM(CASE WHEN cal_quarter = 3 THEN amt ELSE 0 END) AS q3,
       SUM(CASE WHEN cal_quarter = 4 THEN amt ELSE 0 END) AS q4,
       SUM(amt)                                           AS yr_total,
       br_ID
FROM   rev
GROUP  BY br_ID, br_city
ORDER  BY br_ID;


-- ###################################################################
-- SECTION 4B - FOCUS YEAR: NET PROFIT BY QUARTER
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4B. FOCUS YEAR &focus_y: NET PROFIT BY QUARTER' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city    HEADING 'BRANCH'           FORMAT A15
COLUMN q1         HEADING 'Q1 (RM)'          FORMAT S9,999,990.00
COLUMN q2         HEADING 'Q2 (RM)'          FORMAT S9,999,990.00
COLUMN q3         HEADING 'Q3 (RM)'          FORMAT S9,999,990.00
COLUMN q4         HEADING 'Q4 (RM)'          FORMAT S9,999,990.00
COLUMN yr_total   HEADING 'YEAR|PROFIT (RM)' FORMAT S99,999,990.00
COLUMN margin_pct HEADING 'YEAR|MARGIN %'    FORMAT S990.0
COLUMN br_ID      NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL BRANCHES' OF q1 q2 q3 q4 yr_total ON REPORT

WITH pnl AS (
    SELECT br_ID, br_city, cal_quarter,
           SUM(rev) AS rev, SUM(cost) AS cost
    FROM (
        SELECT b.br_ID, b.br_city, d.cal_quarter,
               SUM(f.order_gross_amt - f.order_discount_amt) AS rev, 0 AS cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_quarter,
               SUM(f.serv_price - f.serv_discount_amt), 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_quarter,
               0, SUM(f.gross_amount)
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_quarter,
               0, SUM(f.payment_amount)
        FROM   branch_expense_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, d.cal_quarter
    )
    GROUP BY br_ID, br_city, cal_quarter
)
SELECT br_city,
       SUM(CASE WHEN cal_quarter = 1 THEN rev - cost ELSE 0 END) AS q1,
       SUM(CASE WHEN cal_quarter = 2 THEN rev - cost ELSE 0 END) AS q2,
       SUM(CASE WHEN cal_quarter = 3 THEN rev - cost ELSE 0 END) AS q3,
       SUM(CASE WHEN cal_quarter = 4 THEN rev - cost ELSE 0 END) AS q4,
       SUM(rev - cost)                                           AS yr_total,
       ROUND(SUM(rev - cost) / NULLIF(SUM(rev), 0) * 100, 1)     AS margin_pct,
       br_ID
FROM   pnl
GROUP  BY br_ID, br_city
ORDER  BY br_ID;


-- ###################################################################
-- SECTION 5 - FOCUS YEAR: EXPENSES BY CATEGORY  (branch_utils_dim)
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. FOCUS YEAR &focus_y: BRANCH EXPENSES BY CATEGORY' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city       HEADING 'BRANCH'         FORMAT A15
COLUMN rent          HEADING 'RENT (RM)'      FORMAT 9,999,990.00
COLUMN electricity   HEADING 'ELECTRIC (RM)'  FORMAT 9,999,990.00
COLUMN water         HEADING 'WATER (RM)'     FORMAT 999,990.00
COLUMN internet      HEADING 'INTERNET (RM)'  FORMAT 999,990.00
COLUMN maintenance   HEADING 'MAINT. (RM)'    FORMAT 999,990.00
COLUMN waste         HEADING 'WASTE (RM)'     FORMAT 999,990.00
COLUMN total_exp     HEADING 'TOTAL|EXPENSE (RM)' FORMAT 99,999,990.00
COLUMN rent_pct      HEADING 'RENT|%'         FORMAT 990.0
COLUMN br_ID         NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL BRANCHES' OF rent electricity water internet maintenance waste total_exp ON REPORT

WITH exp_cat AS (
    -- third dimension: which utility category each payment belongs to
    SELECT b.br_ID, b.br_city, u.util_name,
           SUM(f.payment_amount) AS amt
    FROM   branch_expense_fact f
    JOIN   date_dim         d ON d.date_key         = f.date_key
    JOIN   branch_dim       b ON b.branch_key       = f.branch_key
    JOIN   branch_utils_dim u ON u.branch_utils_key = f.branch_utils_key
    WHERE  d.cal_year = &focus_year
    GROUP  BY b.br_ID, b.br_city, u.util_name
)
SELECT br_city,
       SUM(CASE WHEN util_name = 'Rent'             THEN amt ELSE 0 END) AS rent,
       SUM(CASE WHEN util_name = 'Electricity'      THEN amt ELSE 0 END) AS electricity,
       SUM(CASE WHEN util_name = 'Water'            THEN amt ELSE 0 END) AS water,
       SUM(CASE WHEN util_name = 'Internet'         THEN amt ELSE 0 END) AS internet,
       SUM(CASE WHEN util_name = 'Maintenance'      THEN amt ELSE 0 END) AS maintenance,
       SUM(CASE WHEN util_name = 'Waste Management' THEN amt ELSE 0 END) AS waste,
       SUM(amt)                                                          AS total_exp,
       ROUND(SUM(CASE WHEN util_name = 'Rent' THEN amt ELSE 0 END)
             / NULLIF(SUM(amt), 0) * 100, 1)                              AS rent_pct,
       br_ID
FROM   exp_cat
GROUP  BY br_ID, br_city
ORDER  BY br_ID;


-- ###################################################################
-- SECTION 6 - SUMMARY STATISTICS
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 6. PROFITABILITY SUMMARY STATISTICS' SKIP 1 -
       CENTER 'ALL BRANCHES 2019 - 2025, FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC'  FORMAT A36
COLUMN metric_value HEADING 'VALUE'   FORMAT A34

WITH pnl AS (
    SELECT br_ID, br_city, cal_year, cal_quarter,
           SUM(product_rev)  AS product_rev,
           SUM(service_rev)  AS service_rev,
           SUM(salary_cost)  AS salary_cost,
           SUM(expense_cost) AS expense_cost
    FROM (
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               SUM(f.order_gross_amt - f.order_discount_amt) AS product_rev,
               0 AS service_rev, 0 AS salary_cost, 0 AS expense_cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, SUM(f.serv_price - f.serv_discount_amt), 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, 0, SUM(f.gross_amount), 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, 0, 0, SUM(f.payment_amount)
        FROM   branch_expense_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
    )
    GROUP BY br_ID, br_city, cal_year, cal_quarter
),
-- one-row helper blocks; they are CROSS JOINed below instead of being
-- scalar subqueries, which Oracle 11g rejects inside an aggregate
-- SELECT list (ORA-00937)
totals AS (
    SELECT SUM(product_rev) + SUM(service_rev)                        AS total_rev,
           SUM(salary_cost)                                           AS salary_cost,
           SUM(expense_cost)                                          AS expense_cost,
           SUM(product_rev) + SUM(service_rev)
             - SUM(salary_cost) - SUM(expense_cost)                   AS net_profit,
           COUNT(DISTINCT br_ID)                                      AS num_branches,
           COUNT(DISTINCT cal_year)                                   AS num_years
    FROM   pnl
),
by_year AS (
    SELECT cal_year,
           SUM(product_rev) + SUM(service_rev) - SUM(salary_cost) - SUM(expense_cost) AS net_profit
    FROM   pnl GROUP BY cal_year
),
by_branch AS (
    SELECT br_city,
           SUM(product_rev) + SUM(service_rev) - SUM(salary_cost) - SUM(expense_cost) AS net_profit
    FROM   pnl GROUP BY br_city
),
by_branch_focus AS (
    SELECT br_city,
           SUM(product_rev) + SUM(service_rev) - SUM(salary_cost) - SUM(expense_cost) AS net_profit
    FROM   pnl WHERE cal_year = &focus_year GROUP BY br_city
),
by_quarter AS (
    SELECT br_city || ' ' || cal_year || '-Q' || cal_quarter AS label,
           product_rev + service_rev - salary_cost - expense_cost AS net_profit
    FROM   pnl
),
yr AS (
    SELECT MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY net_profit DESC) AS best_year,
           MAX(net_profit)                                               AS best_year_profit,
           MIN(cal_year) KEEP (DENSE_RANK LAST  ORDER BY net_profit DESC) AS worst_year,
           MIN(net_profit)                                               AS worst_year_profit
    FROM   by_year
),
br AS (
    SELECT MAX(br_city) KEEP (DENSE_RANK FIRST ORDER BY net_profit DESC)  AS best_branch,
           MAX(net_profit)                                               AS best_branch_profit,
           MIN(br_city) KEEP (DENSE_RANK LAST  ORDER BY net_profit DESC)  AS worst_branch,
           MIN(net_profit)                                               AS worst_branch_profit
    FROM   by_branch
),
fy AS (
    SELECT MAX(br_city) KEEP (DENSE_RANK FIRST ORDER BY net_profit DESC)  AS focus_best_branch,
           MAX(net_profit)                                               AS focus_best_profit,
           SUM(net_profit)                                               AS focus_total_profit
    FROM   by_branch_focus
),
qt AS (
    SELECT MIN(label) KEEP (DENSE_RANK LAST  ORDER BY net_profit DESC)    AS worst_quarter,
           MIN(net_profit)                                               AS worst_quarter_profit,
           SUM(CASE WHEN net_profit < 0 THEN 1 ELSE 0 END)               AS loss_quarters
    FROM   by_quarter
),
stats AS (
    SELECT t.*, yr.*, br.*, fy.*, qt.*
    FROM   totals t CROSS JOIN yr CROSS JOIN br CROSS JOIN fy CROSS JOIN qt
)
SELECT 'Total Revenue 2019-2025 (RM)'       AS metric_name,
       TO_CHAR(total_rev,    '999,999,999,990.00')                     AS metric_value FROM stats
UNION ALL SELECT 'Total Salary Cost (RM)',
       TO_CHAR(salary_cost,  '999,999,999,990.00')                     FROM stats
UNION ALL SELECT 'Total Branch Expenses (RM)',
       TO_CHAR(expense_cost, '999,999,999,990.00')                     FROM stats
UNION ALL SELECT 'Total Net Profit (RM)',
       TO_CHAR(net_profit,   'S999,999,999,990.00')                    FROM stats
UNION ALL SELECT 'Overall Margin %',
       TO_CHAR(net_profit / NULLIF(total_rev, 0) * 100, 'S990.0') || '%'   FROM stats
UNION ALL SELECT 'Salary as % of Revenue',
       TO_CHAR(salary_cost / NULLIF(total_rev, 0) * 100, '990.0') || '%'   FROM stats
UNION ALL SELECT 'Expenses as % of Revenue',
       TO_CHAR(expense_cost / NULLIF(total_rev, 0) * 100, '990.0') || '%'  FROM stats
UNION ALL SELECT 'Best Year (company)',
       TO_CHAR(best_year)  || '  (RM ' || TRIM(TO_CHAR(best_year_profit,  'S999,999,999,990.00')) || ')' FROM stats
UNION ALL SELECT 'Worst Year (company)',
       TO_CHAR(worst_year) || '  (RM ' || TRIM(TO_CHAR(worst_year_profit, 'S999,999,999,990.00')) || ')' FROM stats
UNION ALL SELECT 'Most Profitable Branch 2019-2025',
       best_branch  || '  (RM ' || TRIM(TO_CHAR(best_branch_profit,  'S999,999,999,990.00')) || ')'  FROM stats
UNION ALL SELECT 'Least Profitable Branch 2019-2025',
       worst_branch || '  (RM ' || TRIM(TO_CHAR(worst_branch_profit, 'S999,999,999,990.00')) || ')'  FROM stats
UNION ALL SELECT 'Top Branch in &focus_y',
       focus_best_branch || '  (RM ' || TRIM(TO_CHAR(focus_best_profit, 'S999,999,999,990.00')) || ')' FROM stats
UNION ALL SELECT 'Company Net Profit in &focus_y (RM)',
       TO_CHAR(focus_total_profit, 'S999,999,999,990.00')              FROM stats
UNION ALL SELECT 'Worst Branch-Quarter ever',
       worst_quarter || '  (RM ' || TRIM(TO_CHAR(worst_quarter_profit, 'S999,999,999,990.00')) || ')' FROM stats
UNION ALL SELECT 'Loss-Making Branch-Quarters',
       TO_CHAR(loss_quarters)                                          FROM stats
UNION ALL SELECT 'Number of Branches',
       TO_CHAR(num_branches)                                           FROM stats
UNION ALL SELECT 'Number of Years',
       TO_CHAR(num_years)                                              FROM stats;

PROMPT
PROMPT +==========================================================+
PROMPT |           END OF BRANCH PROFITABILITY REPORT             |
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
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
