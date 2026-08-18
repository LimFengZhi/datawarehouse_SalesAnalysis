-- ===================================================================
-- 01_fy2024_branch_paradox.sql
-- SALES ANALYSIS - FY2024 BRANCH PERFORMANCE PARADOX
--   "Our top-revenue branch is our least profitable" - is it true?
--   company per year -> SLICE the focus year -> rank revenue vs profit
--   (in RM and in margin) -> why (cost structure) -> is the year
--   special -> the two branches quarter by quarter -> their expense
--   lines -> verdict
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Fz\01_fy2024_branch_paradox.sql
--
-- PARAMETER (prompted)
--   focus year   the financial year every slice zooms into (default 2024)
--
-- WHAT IT ANSWERS
--   1. Is the branch that sells the most really the branch that keeps
--      the least?  (revenue rank vs net-profit rank vs margin rank,
--      side by side - the answer differs by yardstick, see below)
--   2. If not - who IS the least profitable, and WHY?  (cost structure:
--      COGS, payroll and rent as a share of what each branch sells)
--   3. Is the focus year a one-off, or the standing order of things?
--      (profit rank and margin rank of every branch in every year
--      2018-2025)
--   4. Where inside the year does the money go for the top-revenue
--      branch and for the least-profitable one?  (quarters, expense
--      categories)
--
-- THE CUBE
--   facts     five, drilled ACROSS on the conformed dimensions:
--               order_fact             product revenue
--               reservation_fact       service revenue
--               purchase_fact          cost of goods bought (COGS)
--               salary_payment_fact    payroll
--               branch_expense_fact    rent, utilities and upkeep
--   dims      date_dim.cal_year / cal_quarter        -> the drill path
--             branch_dim.br_ID / br_city             -> the rows
--             branch_utils_dim.util_name             -> expense split
--             staff_dim.st_ID                        -> headcount only
--   measures  see MEASURE DEFINITIONS
--
-- MEASURE DEFINITIONS
--   Product revenue = order_total_amt - order_tax_amt
--                     (= qty x price of the day - discount; SST is passed
--                     on to the government, so it is not revenue).
--                     COMPLETED orders only.
--   Service revenue = serv_total_amt - serv_tax_amt, COMPLETED
--                     reservations only, dated by the appointment day.
--   COGS            = purchase_total_cost - what the branch spent buying
--                     stock in the period (see the caveat below).
--   Salary          = base_amount + bonus_amount (gross pay). The
--                     deduction column is the employee's EPF share; it
--                     is withheld from the payslip but still paid out by
--                     the company, so it is NOT subtracted.
--   Expenses        = payment_amount over all six utility categories.
--   Gross profit    = revenue - COGS
--   Net profit      = revenue - COGS - salary - expenses
--                     (the warehouse's own definition, see the header of
--                     ETL_Process\initial_loading\init_fact\03_init_purchase_fact.sql)
--   Margin %        = net profit / revenue x 100
--   Headcount       = COUNT(DISTINCT st_ID) of staff paid in the year
--
--   Every fact is cut on date_dim.cal_year through its date_key, never
--   on the pay_period / billing_period strings - so a December pay
--   period paid on 25 Jan counts in January's year, consistently for
--   both cost facts.
--
--   All facts are grouped on the branch NATURAL key (br_ID), not the
--   surrogate branch_key - branch_dim is SCD2, so one branch could own
--   several branch_key rows and must still roll up as one line. Heads
--   are COUNT(DISTINCT st_ID) for the same reason (staff_dim is SCD2).
--
--   Sections 1-5 and 7 all roll up from the SAME quarter-grain base
--   query (WITH pnl AS ...), so the totals reconcile across sections.
--
-- ===================================================================
-- READ THIS BEFORE QUOTING ANY NUMBER
-- ===================================================================
--   - COGS here is stock BOUGHT in the period (purchase_fact), not the
--     cost of the units actually sold. Gross profit is therefore a
--     "restocking-adjusted" figure; a branch that stocked up in
--     December looks worse than one that ran its shelves down.
--   - Which data revision is loaded matters. With sales_data3 (revision
--     3, the current dataset) the P+L is sane: about break-even in
--     2018-19, MCO losses in 2020-21, profitable from 2022, ~10 % margin
--     in 2024. With sales_data2 (revision 2) payroll alone is 80-130 %
--     of revenue and EVERY branch shows a net loss in every year - read
--     the RANKS, MARGINS and cost RATIOS there, not the sign of the RM
--     figure. Row counts and IDs are identical in both revisions.
--   - Ipoh opened 2023-03-01: blank before 2023 in the year pivot, and
--     a part year in 2023 (staff paid from February, doors open March).
--   - 2020 and 2021 carry MCO / FMCO closure months (salons shut, pay
--     cuts, rent rebates) - ranks in those years are distorted.
--
-- DIMENSIONS USED  (four)
--   date_dim          cal_year, cal_quarter
--   branch_dim        br_ID, br_city
--   branch_utils_dim  util_name
--   staff_dim         st_ID  (headcount only)
--
-- REPORT SECTIONS  (each one is ONE OLAP operation)
--   1  COMPANY P+L PER YEAR              ROLL-UP    all branches, 2018-2025
--   2  FOCUS YEAR: REVENUE vs PROFIT     SLICE      year = focus year, one
--      RANKING                                      row per branch - THE TEST
--   3  FOCUS YEAR: COST STRUCTURE        SLICE      same slice, cost ratios
--                                                   and per-head figures - WHY
--   4A NET-PROFIT (RM) RANK PER YEAR     PIVOT      years across - is the
--   4B NET-MARGIN RANK PER YEAR          PIVOT      focus year special, and
--                                                   does the yardstick matter?
--   5  THE TWO BRANCHES BY QUARTER       DRILL-DOWN year -> quarter for the
--                                                   top-revenue and the
--                                                   least-profitable branch
--   6  THE TWO BRANCHES: EXPENSES BY     DICE       2 branches x 6 utility
--      CATEGORY                                     categories x focus year
--   7  SUMMARY STATISTICS + VERDICT                 the answer in one line
--
--   The two branches in sections 5-6 are NOT hard-coded: the script
--   looks up which branch has the highest revenue and which has the
--   lowest net profit in the focus year and drills into those.
--
-- WHAT TO LOOK FOR  (FY2024)
--   Revision 3 (sales_data3), from the CSV pre-check - confirm against
--   the spool after loading:
--   - Section 1: revenue RM 9.6 M (2018) -> 16.3 M (2024); margin -4 %
--     2018, -2 % 2019, -16 % / -29 % in the MCO years, +5 % 2022, +8 %
--     2023, +10 % 2024, +12 % 2025. Payroll ~44 % of revenue, COGS ~36 %.
--   - Section 2: Petaling Jaya #1 revenue (RM 2.20 M) AND #1 net profit
--     (RM +391 k, 17.8 %); Kuala Lumpur #2 / #2 (14.2 %); 12 of 13
--     branches positive; Ipoh (2nd year, 18 heads) the only loss
--     (-13 %); Melaka the weakest of the rest (about 0 %). The headline
--     does NOT hold on either yardstick.
--   - Section 3: PJ salary 38 % / rent 8 % of revenue; Ipoh salary 64 %.
--   - Sections 5-6: Q4 still the biggest revenue quarter and the
--     December bonus still dents Q4 profit; rent ~78 % of expenses.
--
--   Revision 2 (sales_data2), from the spool of the full 2018-2025 load:
--   THE ANSWER DEPENDS ON THE YARDSTICK - and that is the real finding.
--   - Section 1: revenue grows every year except the MCO dip (2020-21)
--     and margin improves steadily (-106 % in 2018 to -70 % in 2025),
--     but the company never reaches break-even: payroll alone is
--     ~91 % of revenue and COGS ~60 %. FY2024 is not special.
--   - Section 2, in RM: Petaling Jaya sells the most (RM 1.40 M) and
--     ranks #12 of 13 by net profit (-RM 732 k); Kuala Lumpur (#2 on
--     revenue) is #13 (-RM 786 k). The three smallest shops - Gombak,
--     Selayang, Melaka - are the "most profitable" simply because they
--     lose the least. Rank gap -11 for PJ and KL, +11 for Gombak.
--   - Section 2, in margin: the same PJ has the BEST margin (-52.3 %),
--     KL second (-61.2 %); Ipoh is worst (-124.5 %), Melaka next
--     (-97.2 %). Sort by margin and the table nearly inverts.
--   - Section 3: PJ has the lowest salary-to-revenue ratio (78 %) and
--     the lowest rent-to-revenue (14.5 %) and is the ONLY branch that
--     covers salary + premises before stock (pre-COGS margin +3.3 %).
--     KL's rent is 20.6 % of revenue (Bukit Bintang) and its expenses
--     26.5 % - the reason it drops below PJ. Ipoh: salary 132 % of
--     revenue (18 heads for a shop selling RM 569 k).
--   - Section 4A: in RM, PJ has been second-last or third-last EVERY
--     year 2018-2025 (#11 of 12 before Ipoh, #12 of 13 in 2024) and KL
--     last or second-last every year - the standing order, not a 2024
--     event. Section 4B: on margin PJ is #1 in ALL eight years and KL
--     #2 in seven of them; the yardstick, not the year, makes the
--     paradox.
--   - Section 5: Q4 is the biggest revenue quarter for both branches
--     (28 % of the year) but also the worst-loss quarter in RM: the
--     13th-month bonus lands in December payroll.
--   - Section 6: rent is ~78 % of expenses in every branch; KL pays
--     RM 265 k against the average branch's RM 143 k.
--   - Section 7: two verdict rows - "HOLDS"/"DOES NOT HOLD" in RM and
--     in margin - with the ranks that back them.
--   Note "least profitable" in RM is Kuala Lumpur, not PJ, so even the
--   RM verdict reads DOES NOT HOLD (PJ is #12 of 13, one place above).
-- ===================================================================

-- reset anything a previous script left behind in this session
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 150
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

-- SQL*Plus caps an ACCEPT prompt at 99 characters - keep it short.
ACCEPT focus_year NUMBER DEFAULT 2024 PROMPT 'Focus year (default 2024): '

-- ---- values reused in every title ---------------------------------
-- TERMOUT OFF hides these helper queries (only works when the file is
-- run with @, which is how this report is meant to be run). TO_CHAR
-- keeps the numbers from being captured with leading spaces.
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN focus_y NEW_VALUE focus_y NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;

-- ---- the two branches sections 5 and 6 drill into ------------------
-- top_rev_*  = the branch with the highest revenue in the focus year
-- low_prof_* = the branch with the lowest net profit in the focus year
-- If they are the same branch, the headline holds and sections 5-6
-- simply show that one branch.
COLUMN top_rev_id    NEW_VALUE top_rev_id    NOPRINT
COLUMN top_rev_city  NEW_VALUE top_rev_city  NOPRINT
COLUMN low_prof_id   NEW_VALUE low_prof_id   NOPRINT
COLUMN low_prof_city NEW_VALUE low_prof_city NOPRINT

WITH pnl AS (
    SELECT br_ID, br_city,
           SUM(rev) AS rev, SUM(cost) AS cost
    FROM (
        SELECT b.br_ID, b.br_city,
               SUM(f.order_total_amt - f.order_tax_amt) AS rev, 0 AS cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               SUM(f.serv_total_amt - f.serv_tax_amt), 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, SUM(f.purchase_total_cost)
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, SUM(f.base_amount + f.bonus_amount)
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, SUM(f.payment_amount)
        FROM   branch_expense_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
    )
    GROUP BY br_ID, br_city
)
SELECT TO_CHAR(MAX(br_ID)   KEEP (DENSE_RANK FIRST ORDER BY rev DESC))        AS top_rev_id,
       MAX(br_city)         KEEP (DENSE_RANK FIRST ORDER BY rev DESC)         AS top_rev_city,
       TO_CHAR(MAX(br_ID)   KEEP (DENSE_RANK FIRST ORDER BY rev - cost ASC))  AS low_prof_id,
       MAX(br_city)         KEEP (DENSE_RANK FIRST ORDER BY rev - cost ASC)   AS low_prof_city
FROM   pnl;

CLEAR COLUMNS
SET TERMOUT ON

SPOOL fy2024_branch_paradox_output.txt


-- ###################################################################
-- SECTION 1 - COMPANY P+L PER YEAR  (profit and loss)
-- OLAP: ROLL-UP to year grain over all five facts, all branches.
-- Sets the scene: how big is the business, and is the focus year
-- unusual for the company as a whole?
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. COMPANY P+L PER YEAR' SKIP 1 -
       CENTER 'ALL BRANCHES, 2018 - 2025 (ROLL-UP)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year      HEADING 'YEAR'                FORMAT 9999
COLUMN product_rev   HEADING 'PRODUCT|REV (RM)'    FORMAT 999,999,990.00
COLUMN service_rev   HEADING 'SERVICE|REV (RM)'    FORMAT 999,999,990.00
COLUMN total_rev     HEADING 'TOTAL|REVENUE (RM)'  FORMAT 999,999,990.00
COLUMN cogs          HEADING 'COGS (RM)'           FORMAT 999,999,990.00
COLUMN gross_profit  HEADING 'GROSS|PROFIT (RM)'   FORMAT S999,999,990.00
COLUMN salary_cost   HEADING 'SALARY (RM)'         FORMAT 999,999,990.00
COLUMN expense_cost  HEADING 'EXPENSES (RM)'       FORMAT 999,999,990.00
COLUMN net_profit    HEADING 'NET|PROFIT (RM)'     FORMAT S999,999,990.00
COLUMN margin_pct    HEADING 'MARGIN|%'            FORMAT S990.0
COLUMN yoy_pct       HEADING 'NET|YOY %'           FORMAT S9990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF product_rev service_rev total_rev cogs gross_profit salary_cost expense_cost net_profit ON REPORT

WITH pnl AS (
    -- quarter-grain base: one row per branch / year / quarter with all
    -- five measures already side by side (drill-across on date + branch)
    SELECT br_ID, br_city, cal_year, cal_quarter,
           SUM(product_rev)  AS product_rev,
           SUM(service_rev)  AS service_rev,
           SUM(cogs)         AS cogs,
           SUM(salary_cost)  AS salary_cost,
           SUM(expense_cost) AS expense_cost
    FROM (
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               SUM(f.order_total_amt - f.order_tax_amt) AS product_rev,
               0 AS service_rev, 0 AS cogs, 0 AS salary_cost, 0 AS expense_cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, SUM(f.serv_total_amt - f.serv_tax_amt), 0, 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, 0, SUM(f.purchase_total_cost), 0, 0
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, 0, 0, SUM(f.base_amount + f.bonus_amount), 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year, d.cal_quarter,
               0, 0, 0, 0, SUM(f.payment_amount)
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
           SUM(cogs)                            AS cogs,
           SUM(salary_cost)                     AS salary_cost,
           SUM(expense_cost)                    AS expense_cost,
           SUM(product_rev) + SUM(service_rev)
             - SUM(cogs) - SUM(salary_cost) - SUM(expense_cost) AS net_profit
    FROM   pnl
    GROUP  BY cal_year
)
SELECT cal_year, product_rev, service_rev, total_rev, cogs,
       total_rev - cogs                                                  AS gross_profit,
       salary_cost, expense_cost, net_profit,
       ROUND(net_profit / NULLIF(total_rev, 0) * 100, 1)                 AS margin_pct,
       -- ABS on the denominator: profits are negative, and "less loss
       -- than last year" must read as a positive change
       ROUND( (net_profit - LAG(net_profit) OVER (ORDER BY cal_year))
             / NULLIF(ABS(LAG(net_profit) OVER (ORDER BY cal_year)), 0) * 100, 1) AS yoy_pct
FROM   company_year
ORDER  BY cal_year;


-- ###################################################################
-- SECTION 2 - FOCUS YEAR: BRANCH RANKING, REVENUE vs NET PROFIT
-- OLAP: SLICE - fix ONE dimension member (cal_year = focus year) and
-- look at the branch plane of that year. This is THE TEST of the
-- headline: read the PROFIT RANK and the MARGIN RANK on the row where
-- REV RANK = 1.
-- RANK GAP = revenue rank - profit rank: 0 means the branch keeps
-- exactly as much as its sales rank suggests; positive means it ranks
-- HIGHER on profit than on revenue; negative means it sells well but
-- keeps less (in RM) than its peers.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. FY&focus_y BRANCH RANKING: REVENUE vs NET PROFIT' SKIP 1 -
       CENTER 'ONE ROW PER BRANCH, ORDERED BY REVENUE (SLICE: YEAR = &focus_y)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rev_rank      HEADING 'REV|RANK'            FORMAT 99
COLUMN br_city       HEADING 'BRANCH'              FORMAT A15
COLUMN total_rev     HEADING 'TOTAL|REVENUE (RM)'  FORMAT 99,999,990.00
COLUMN cogs          HEADING 'COGS (RM)'           FORMAT 99,999,990.00
COLUMN gross_profit  HEADING 'GROSS|PROFIT (RM)'   FORMAT S9,999,990.00
COLUMN salary_cost   HEADING 'SALARY (RM)'         FORMAT 99,999,990.00
COLUMN expense_cost  HEADING 'EXPENSES (RM)'       FORMAT 9,999,990.00
COLUMN net_profit    HEADING 'NET|PROFIT (RM)'     FORMAT S99,999,990.00
COLUMN profit_rank   HEADING 'PROFIT|RANK'         FORMAT 99
COLUMN rank_gap      HEADING 'RANK|GAP'            FORMAT S99
COLUMN margin_pct    HEADING 'MARGIN|%'            FORMAT S990.0
COLUMN margin_rank   HEADING 'MARGIN|RANK'         FORMAT 99
COLUMN br_ID         NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF total_rev cogs gross_profit salary_cost expense_cost net_profit ON REPORT

WITH pnl AS (
    SELECT br_ID, br_city,
           SUM(product_rev)  AS product_rev,
           SUM(service_rev)  AS service_rev,
           SUM(cogs)         AS cogs,
           SUM(salary_cost)  AS salary_cost,
           SUM(expense_cost) AS expense_cost
    FROM (
        SELECT b.br_ID, b.br_city,
               SUM(f.order_total_amt - f.order_tax_amt) AS product_rev,
               0 AS service_rev, 0 AS cogs, 0 AS salary_cost, 0 AS expense_cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, SUM(f.serv_total_amt - f.serv_tax_amt), 0, 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, 0, SUM(f.purchase_total_cost), 0, 0
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, 0, 0, SUM(f.base_amount + f.bonus_amount), 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, 0, 0, 0, SUM(f.payment_amount)
        FROM   branch_expense_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
    )
    GROUP BY br_ID, br_city
),
branch_year AS (
    SELECT br_ID, br_city,
           product_rev + service_rev                                     AS total_rev,
           cogs, salary_cost, expense_cost,
           product_rev + service_rev - cogs                              AS gross_profit,
           product_rev + service_rev - cogs - salary_cost - expense_cost AS net_profit
    FROM   pnl
)
SELECT RANK() OVER (ORDER BY total_rev  DESC)                          AS rev_rank,
       br_city, total_rev, cogs, gross_profit, salary_cost, expense_cost, net_profit,
       RANK() OVER (ORDER BY net_profit DESC)                          AS profit_rank,
       RANK() OVER (ORDER BY total_rev  DESC)
         - RANK() OVER (ORDER BY net_profit DESC)                      AS rank_gap,
       ROUND(net_profit / NULLIF(total_rev, 0) * 100, 1)               AS margin_pct,
       -- second yardstick: profit per RM of sales. When every branch
       -- runs at a loss, the RM rank rewards being small; the margin
       -- rank rewards converting sales into profit
       RANK() OVER (ORDER BY net_profit / NULLIF(total_rev, 0) DESC)   AS margin_rank,
       br_ID
FROM   branch_year
ORDER  BY rev_rank;


-- ###################################################################
-- SECTION 3 - FOCUS YEAR: COST STRUCTURE PER BRANCH
-- OLAP: SLICE (same slice as section 2), the WHY behind the ranks -
-- every cost line as a share of that branch's own revenue, plus
-- revenue and salary per head. Sorted by net margin, best first.
-- "PRE-COGS" = revenue - salary - expenses: does the branch at least
-- cover its people and its premises before stock is counted?
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. FY&focus_y COST STRUCTURE PER BRANCH' SKIP 1 -
       CENTER 'EVERY COST LINE AS % OF EACH BRANCH REVENUE, BEST MARGIN FIRST' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city       HEADING 'BRANCH'              FORMAT A15
COLUMN total_rev     HEADING 'TOTAL|REVENUE (RM)'  FORMAT 99,999,990.00
COLUMN heads         HEADING 'HEADS'               FORMAT 990
COLUMN rev_head      HEADING 'REVENUE|PER HEAD'    FORMAT 999,990
COLUMN sal_head      HEADING 'SALARY|PER HEAD'     FORMAT 999,990
COLUMN cogs_pct      HEADING 'COGS|% REV'          FORMAT 990.0
COLUMN salary_pct    HEADING 'SALARY|% REV'        FORMAT 990.0
COLUMN expense_pct   HEADING 'EXPENSE|% REV'       FORMAT 990.0
COLUMN rent_pct      HEADING 'RENT|% REV'          FORMAT 990.0
COLUMN gross_pct     HEADING 'GROSS|MARGIN %'      FORMAT S990.0
COLUMN precogs_pct   HEADING 'PRE-COGS|MARGIN %'   FORMAT S990.0
COLUMN margin_pct    HEADING 'NET|MARGIN %'        FORMAT S990.0
COLUMN br_ID         NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF total_rev heads ON REPORT
COMPUTE AVG LABEL 'AVG' OF cogs_pct salary_pct expense_pct rent_pct gross_pct precogs_pct margin_pct ON REPORT

WITH pnl AS (
    SELECT br_ID, br_city,
           SUM(product_rev)  AS product_rev,
           SUM(service_rev)  AS service_rev,
           SUM(cogs)         AS cogs,
           SUM(salary_cost)  AS salary_cost,
           SUM(expense_cost) AS expense_cost,
           SUM(rent_cost)    AS rent_cost
    FROM (
        SELECT b.br_ID, b.br_city,
               SUM(f.order_total_amt - f.order_tax_amt) AS product_rev,
               0 AS service_rev, 0 AS cogs, 0 AS salary_cost, 0 AS expense_cost, 0 AS rent_cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, SUM(f.serv_total_amt - f.serv_tax_amt), 0, 0, 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, 0, SUM(f.purchase_total_cost), 0, 0, 0
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, 0, 0, SUM(f.base_amount + f.bonus_amount), 0, 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        -- expenses carry the third dimension: rent is split out here
        SELECT b.br_ID, b.br_city,
               0, 0, 0, 0, SUM(f.payment_amount),
               SUM(CASE WHEN u.util_name = 'Rent' THEN f.payment_amount ELSE 0 END)
        FROM   branch_expense_fact f
        JOIN   date_dim         d ON d.date_key         = f.date_key
        JOIN   branch_dim       b ON b.branch_key       = f.branch_key
        JOIN   branch_utils_dim u ON u.branch_utils_key = f.branch_utils_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
    )
    GROUP BY br_ID, br_city
),
heads AS (
    -- people paid in the focus year, counted once each (st_ID, not the
    -- SCD2 surrogate staff_key)
    SELECT b.br_ID, COUNT(DISTINCT s.st_ID) AS heads
    FROM   salary_payment_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    JOIN   staff_dim  s ON s.staff_key  = f.staff_key
    WHERE  d.cal_year = &focus_year
    GROUP  BY b.br_ID
)
SELECT p.br_city,
       p.product_rev + p.service_rev                                        AS total_rev,
       h.heads,
       ROUND((p.product_rev + p.service_rev) / NULLIF(h.heads, 0))          AS rev_head,
       ROUND(p.salary_cost / NULLIF(h.heads, 0))                            AS sal_head,
       ROUND(p.cogs         / NULLIF(p.product_rev + p.service_rev, 0) * 100, 1) AS cogs_pct,
       ROUND(p.salary_cost  / NULLIF(p.product_rev + p.service_rev, 0) * 100, 1) AS salary_pct,
       ROUND(p.expense_cost / NULLIF(p.product_rev + p.service_rev, 0) * 100, 1) AS expense_pct,
       ROUND(p.rent_cost    / NULLIF(p.product_rev + p.service_rev, 0) * 100, 1) AS rent_pct,
       ROUND((p.product_rev + p.service_rev - p.cogs)
             / NULLIF(p.product_rev + p.service_rev, 0) * 100, 1)              AS gross_pct,
       ROUND((p.product_rev + p.service_rev - p.salary_cost - p.expense_cost)
             / NULLIF(p.product_rev + p.service_rev, 0) * 100, 1)              AS precogs_pct,
       ROUND((p.product_rev + p.service_rev - p.cogs - p.salary_cost - p.expense_cost)
             / NULLIF(p.product_rev + p.service_rev, 0) * 100, 1)              AS margin_pct,
       p.br_ID
FROM   pnl p
LEFT   JOIN heads h ON h.br_ID = p.br_ID
ORDER  BY margin_pct DESC;


-- ###################################################################
-- SECTION 4A - NET-PROFIT (RM) RANK PER BRANCH PER YEAR
-- OLAP: PIVOT - years across, branches down; each cell is the branch's
-- rank by net profit in RM among the branches trading that year
-- (1 = best). Answers "is the focus year a one-off?": a branch that
-- sits at the bottom every year is there structurally; a branch that
-- only slipped in the focus year had a bad year.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4A. NET-PROFIT (RM) RANK PER BRANCH PER YEAR' SKIP 1 -
       CENTER '1 = MOST PROFITABLE THAT YEAR, 2018 - 2025 (PIVOT: YEARS ACROSS)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city   HEADING 'BRANCH'      FORMAT A15
COLUMN y2018     HEADING '2018'        FORMAT 99
COLUMN y2019     HEADING '2019'        FORMAT 99
COLUMN y2020     HEADING '2020'        FORMAT 99
COLUMN y2021     HEADING '2021'        FORMAT 99
COLUMN y2022     HEADING '2022'        FORMAT 99
COLUMN y2023     HEADING '2023'        FORMAT 99
COLUMN y2024     HEADING '2024'        FORMAT 99
COLUMN y2025     HEADING '2025'        FORMAT 99
COLUMN avg_rank  HEADING 'AVG|RANK'    FORMAT 90.0
COLUMN best_yr   HEADING 'BEST|YEAR'   FORMAT 9999
COLUMN worst_yr  HEADING 'WORST|YEAR'  FORMAT 9999
COLUMN focus_np  HEADING 'FY&focus_y NET|PROFIT (RM)' FORMAT S99,999,990.00
COLUMN br_ID     NOPRINT

WITH pnl AS (
    SELECT br_ID, br_city, cal_year,
           SUM(rev) AS rev, SUM(cost) AS cost
    FROM (
        SELECT b.br_ID, b.br_city, d.cal_year,
               SUM(f.order_total_amt - f.order_tax_amt) AS rev, 0 AS cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year,
               SUM(f.serv_total_amt - f.serv_tax_amt), 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year,
               0, SUM(f.purchase_total_cost)
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year,
               0, SUM(f.base_amount + f.bonus_amount)
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year,
               0, SUM(f.payment_amount)
        FROM   branch_expense_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year
    )
    GROUP BY br_ID, br_city, cal_year
),
ranked AS (
    SELECT br_ID, br_city, cal_year,
           rev - cost                                                        AS net_profit,
           RANK() OVER (PARTITION BY cal_year ORDER BY rev - cost DESC)      AS rnk
    FROM   pnl
)
SELECT br_city,
       -- no ELSE, so a year the branch did not trade (Ipoh before 2023)
       -- prints blank instead of a rank
       MAX(CASE WHEN cal_year = 2018 THEN rnk END) AS y2018,
       MAX(CASE WHEN cal_year = 2019 THEN rnk END) AS y2019,
       MAX(CASE WHEN cal_year = 2020 THEN rnk END) AS y2020,
       MAX(CASE WHEN cal_year = 2021 THEN rnk END) AS y2021,
       MAX(CASE WHEN cal_year = 2022 THEN rnk END) AS y2022,
       MAX(CASE WHEN cal_year = 2023 THEN rnk END) AS y2023,
       MAX(CASE WHEN cal_year = 2024 THEN rnk END) AS y2024,
       MAX(CASE WHEN cal_year = 2025 THEN rnk END) AS y2025,
       ROUND(AVG(rnk), 1)                                                  AS avg_rank,
       MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY rnk ASC,  net_profit DESC) AS best_yr,
       MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY rnk DESC, net_profit ASC)  AS worst_yr,
       MAX(CASE WHEN cal_year = &focus_year THEN net_profit END)          AS focus_np,
       br_ID
FROM   ranked
GROUP  BY br_ID, br_city
ORDER  BY MAX(CASE WHEN cal_year = &focus_year THEN rnk END) NULLS LAST, br_ID;


-- ###################################################################
-- SECTION 4B - MARGIN RANK PER BRANCH PER YEAR
-- OLAP: PIVOT again, same cube, other yardstick: rank by net margin
-- (net profit / revenue). Because every branch runs at a loss, the RM
-- rank in 4A favours SMALL branches (small shop, small loss); the
-- margin rank shows who converts each ringgit of sales best. If the
-- top-revenue branch is at the bottom of 4A and the top of 4B, the
-- "paradox" is an artefact of the yardstick, not of the branch.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4B. NET-MARGIN RANK PER BRANCH PER YEAR' SKIP 1 -
       CENTER '1 = BEST MARGIN THAT YEAR, 2018 - 2025 (PIVOT: YEARS ACROSS)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city   HEADING 'BRANCH'      FORMAT A15
COLUMN y2018     HEADING '2018'        FORMAT 99
COLUMN y2019     HEADING '2019'        FORMAT 99
COLUMN y2020     HEADING '2020'        FORMAT 99
COLUMN y2021     HEADING '2021'        FORMAT 99
COLUMN y2022     HEADING '2022'        FORMAT 99
COLUMN y2023     HEADING '2023'        FORMAT 99
COLUMN y2024     HEADING '2024'        FORMAT 99
COLUMN y2025     HEADING '2025'        FORMAT 99
COLUMN avg_rank  HEADING 'AVG|RANK'    FORMAT 90.0
COLUMN best_yr   HEADING 'BEST|YEAR'   FORMAT 9999
COLUMN worst_yr  HEADING 'WORST|YEAR'  FORMAT 9999
COLUMN focus_mg  HEADING 'FY&focus_y|MARGIN %' FORMAT S990.0
COLUMN br_ID     NOPRINT

WITH pnl AS (
    SELECT br_ID, br_city, cal_year,
           SUM(rev) AS rev, SUM(cost) AS cost
    FROM (
        SELECT b.br_ID, b.br_city, d.cal_year,
               SUM(f.order_total_amt - f.order_tax_amt) AS rev, 0 AS cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year,
               SUM(f.serv_total_amt - f.serv_tax_amt), 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        GROUP  BY b.br_ID, b.br_city, d.cal_year
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year,
               0, SUM(f.purchase_total_cost)
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year,
               0, SUM(f.base_amount + f.bonus_amount)
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_year,
               0, SUM(f.payment_amount)
        FROM   branch_expense_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, b.br_city, d.cal_year
    )
    GROUP BY br_ID, br_city, cal_year
),
ranked AS (
    SELECT br_ID, br_city, cal_year,
           (rev - cost) / NULLIF(rev, 0) * 100                                AS margin_pct,
           RANK() OVER (PARTITION BY cal_year
                        ORDER BY (rev - cost) / NULLIF(rev, 0) DESC)          AS rnk
    FROM   pnl
)
SELECT br_city,
       MAX(CASE WHEN cal_year = 2018 THEN rnk END) AS y2018,
       MAX(CASE WHEN cal_year = 2019 THEN rnk END) AS y2019,
       MAX(CASE WHEN cal_year = 2020 THEN rnk END) AS y2020,
       MAX(CASE WHEN cal_year = 2021 THEN rnk END) AS y2021,
       MAX(CASE WHEN cal_year = 2022 THEN rnk END) AS y2022,
       MAX(CASE WHEN cal_year = 2023 THEN rnk END) AS y2023,
       MAX(CASE WHEN cal_year = 2024 THEN rnk END) AS y2024,
       MAX(CASE WHEN cal_year = 2025 THEN rnk END) AS y2025,
       ROUND(AVG(rnk), 1)                                                  AS avg_rank,
       MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY rnk ASC,  margin_pct DESC) AS best_yr,
       MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY rnk DESC, margin_pct ASC)  AS worst_yr,
       ROUND(MAX(CASE WHEN cal_year = &focus_year THEN margin_pct END), 1) AS focus_mg,
       br_ID
FROM   ranked
GROUP  BY br_ID, br_city
ORDER  BY MAX(CASE WHEN cal_year = &focus_year THEN rnk END) NULLS LAST, br_ID;


-- ###################################################################
-- SECTION 5 - THE TWO BRANCHES, QUARTER BY QUARTER
-- OLAP: DRILL-DOWN year -> quarter, restricted to the branch with the
-- highest revenue in the focus year and the branch with the lowest
-- net profit (looked up above; if they are the same branch only one
-- block prints and the headline holds).
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. FY&focus_y BY QUARTER (DRILL-DOWN)' SKIP 1 -
       CENTER 'TOP REVENUE: &top_rev_city   vs   LEAST PROFITABLE: &low_prof_city' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN role          HEADING 'ROLE'                FORMAT A16
COLUMN br_city       HEADING 'BRANCH'              FORMAT A15
COLUMN qtr           HEADING 'QTR'                 FORMAT A3
COLUMN total_rev     HEADING 'REVENUE (RM)'        FORMAT 9,999,990.00
COLUMN cogs          HEADING 'COGS (RM)'           FORMAT 9,999,990.00
COLUMN salary_cost   HEADING 'SALARY (RM)'         FORMAT 9,999,990.00
COLUMN expense_cost  HEADING 'EXPENSES (RM)'       FORMAT 999,990.00
COLUMN net_profit    HEADING 'NET|PROFIT (RM)'     FORMAT S9,999,990.00
-- a branch's opening quarter (Ipoh Q1 2023: one month of sales against
-- two months of payroll) can run below -1000 %, so one digit wider here
COLUMN margin_pct    HEADING 'MARGIN|%'            FORMAT S9990.0
COLUMN rev_share     HEADING 'SHARE OF|YEAR REV %' FORMAT 990.0
COLUMN sort_key      NOPRINT

BREAK ON role SKIP 1 ON br_city
COMPUTE SUM LABEL 'YEAR' OF total_rev cogs salary_cost expense_cost net_profit ON role

WITH pnl AS (
    SELECT br_ID, br_city, cal_quarter,
           SUM(rev) AS rev, SUM(cogs) AS cogs, SUM(sal) AS sal, SUM(exp) AS exp
    FROM (
        SELECT b.br_ID, b.br_city, d.cal_quarter,
               SUM(f.order_total_amt - f.order_tax_amt) AS rev, 0 AS cogs, 0 AS sal, 0 AS exp
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year = &focus_year
        AND    b.br_ID IN (&top_rev_id, &low_prof_id)
        GROUP  BY b.br_ID, b.br_city, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_quarter,
               SUM(f.serv_total_amt - f.serv_tax_amt), 0, 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        AND    b.br_ID IN (&top_rev_id, &low_prof_id)
        GROUP  BY b.br_ID, b.br_city, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_quarter,
               0, SUM(f.purchase_total_cost), 0, 0
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        AND    b.br_ID IN (&top_rev_id, &low_prof_id)
        GROUP  BY b.br_ID, b.br_city, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_quarter,
               0, 0, SUM(f.base_amount + f.bonus_amount), 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        AND    b.br_ID IN (&top_rev_id, &low_prof_id)
        GROUP  BY b.br_ID, b.br_city, d.cal_quarter
        UNION ALL
        SELECT b.br_ID, b.br_city, d.cal_quarter,
               0, 0, 0, SUM(f.payment_amount)
        FROM   branch_expense_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        AND    b.br_ID IN (&top_rev_id, &low_prof_id)
        GROUP  BY b.br_ID, b.br_city, d.cal_quarter
    )
    GROUP BY br_ID, br_city, cal_quarter
)
SELECT CASE WHEN br_ID = &top_rev_id AND br_ID = &low_prof_id THEN 'TOP REV + LOWEST'
            WHEN br_ID = &top_rev_id                          THEN 'TOP REVENUE'
            ELSE                                                   'LEAST PROFITABLE' END AS role,
       br_city,
       'Q' || cal_quarter                                              AS qtr,
       rev                                                             AS total_rev,
       cogs, sal                                                       AS salary_cost,
       exp                                                             AS expense_cost,
       rev - cogs - sal - exp                                          AS net_profit,
       ROUND((rev - cogs - sal - exp) / NULLIF(rev, 0) * 100, 1)       AS margin_pct,
       ROUND(RATIO_TO_REPORT(rev) OVER (PARTITION BY br_ID) * 100, 1)  AS rev_share,
       CASE WHEN br_ID = &top_rev_id THEN 1 ELSE 2 END                 AS sort_key
FROM   pnl
ORDER  BY sort_key, cal_quarter;


-- ###################################################################
-- SECTION 6 - THE TWO BRANCHES: EXPENSES BY CATEGORY
-- OLAP: DICE - a sub-cube of two branch members x six utility members
-- x one year, with the all-branch AVERAGE as the yardstick (third
-- dimension branch_utils_dim). Rent % = rent / total expenses.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 6. FY&focus_y EXPENSES BY CATEGORY (DICE)' SKIP 1 -
       CENTER '&top_rev_city vs &low_prof_city vs THE AVERAGE BRANCH' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_label      HEADING 'BRANCH'         FORMAT A27
COLUMN rent          HEADING 'RENT (RM)'      FORMAT 9,999,990.00
COLUMN electricity   HEADING 'ELECTRIC (RM)'  FORMAT 999,990.00
COLUMN water         HEADING 'WATER (RM)'     FORMAT 999,990.00
COLUMN internet      HEADING 'INTERNET (RM)'  FORMAT 999,990.00
COLUMN maintenance   HEADING 'MAINT. (RM)'    FORMAT 999,990.00
COLUMN waste         HEADING 'WASTE (RM)'     FORMAT 999,990.00
COLUMN total_exp     HEADING 'TOTAL|EXPENSE (RM)' FORMAT 9,999,990.00
COLUMN rent_pct      HEADING 'RENT %|OF EXP'  FORMAT 990.0
COLUMN sort_key      NOPRINT

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
),
pivoted AS (
    SELECT br_ID, br_city,
           SUM(CASE WHEN util_name = 'Rent'             THEN amt ELSE 0 END) AS rent,
           SUM(CASE WHEN util_name = 'Electricity'      THEN amt ELSE 0 END) AS electricity,
           SUM(CASE WHEN util_name = 'Water'            THEN amt ELSE 0 END) AS water,
           SUM(CASE WHEN util_name = 'Internet'         THEN amt ELSE 0 END) AS internet,
           SUM(CASE WHEN util_name = 'Maintenance'      THEN amt ELSE 0 END) AS maintenance,
           SUM(CASE WHEN util_name = 'Waste Management' THEN amt ELSE 0 END) AS waste,
           SUM(amt)                                                          AS total_exp
    FROM   exp_cat
    GROUP  BY br_ID, br_city
),
picked AS (
    SELECT CASE WHEN br_ID = &top_rev_id AND br_ID = &low_prof_id THEN br_city || ' (both)'
                WHEN br_ID = &top_rev_id THEN br_city || ' (top rev)'
                ELSE                          br_city || ' (least prof)' END AS br_label,
           rent, electricity, water, internet, maintenance, waste, total_exp,
           CASE WHEN br_ID = &top_rev_id THEN 1 ELSE 2 END AS sort_key
    FROM   pivoted
    WHERE  br_ID IN (&top_rev_id, &low_prof_id)
    UNION ALL
    -- the yardstick: the average branch of the focus year
    SELECT 'AVERAGE BRANCH',
           AVG(rent), AVG(electricity), AVG(water), AVG(internet),
           AVG(maintenance), AVG(waste), AVG(total_exp), 3
    FROM   pivoted
)
SELECT br_label, rent, electricity, water, internet, maintenance, waste, total_exp,
       ROUND(rent / NULLIF(total_exp, 0) * 100, 1) AS rent_pct,
       sort_key
FROM   picked
ORDER  BY sort_key;


-- ###################################################################
-- SECTION 7 - SUMMARY STATISTICS + VERDICT
-- The focus-year headline numbers, then the answer to the question in
-- the title in one line.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 7. FY&focus_y SUMMARY STATISTICS AND VERDICT' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC'  FORMAT A38
COLUMN metric_value HEADING 'VALUE'   FORMAT A95

WITH pnl AS (
    SELECT br_ID, br_city,
           SUM(product_rev)  AS product_rev,
           SUM(service_rev)  AS service_rev,
           SUM(cogs)         AS cogs,
           SUM(salary_cost)  AS salary_cost,
           SUM(expense_cost) AS expense_cost
    FROM (
        SELECT b.br_ID, b.br_city,
               SUM(f.order_total_amt - f.order_tax_amt) AS product_rev,
               0 AS service_rev, 0 AS cogs, 0 AS salary_cost, 0 AS expense_cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, SUM(f.serv_total_amt - f.serv_tax_amt), 0, 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, 0, SUM(f.purchase_total_cost), 0, 0
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, 0, 0, SUM(f.base_amount + f.bonus_amount), 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, 0, 0, 0, SUM(f.payment_amount)
        FROM   branch_expense_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
    )
    GROUP BY br_ID, br_city
),
ranked AS (
    SELECT br_ID, br_city,
           product_rev + service_rev                                     AS total_rev,
           cogs, salary_cost, expense_cost,
           product_rev + service_rev - salary_cost - expense_cost        AS precogs_profit,
           product_rev + service_rev - cogs - salary_cost - expense_cost AS net_profit,
           RANK() OVER (ORDER BY product_rev + service_rev DESC)         AS rev_rank,
           RANK() OVER (ORDER BY product_rev + service_rev
                                 - cogs - salary_cost - expense_cost DESC) AS profit_rank,
           RANK() OVER (ORDER BY (product_rev + service_rev - cogs - salary_cost - expense_cost)
                                 / NULLIF(product_rev + service_rev, 0) DESC) AS margin_rank
    FROM   pnl
),
-- one-row helper blocks; they are CROSS JOINed below instead of being
-- scalar subqueries, which Oracle 11g rejects inside an aggregate
-- SELECT list (ORA-00937)
totals AS (
    SELECT SUM(total_rev)                                   AS total_rev,
           SUM(cogs)                                        AS cogs,
           SUM(salary_cost)                                 AS salary_cost,
           SUM(expense_cost)                                AS expense_cost,
           SUM(net_profit)                                  AS net_profit,
           COUNT(*)                                         AS num_branches,
           SUM(CASE WHEN net_profit     > 0 THEN 1 ELSE 0 END) AS in_black_net,
           SUM(CASE WHEN precogs_profit > 0 THEN 1 ELSE 0 END) AS in_black_precogs
    FROM   ranked
),
top_rev AS (
    SELECT br_city, total_rev, net_profit, profit_rank, margin_rank,
           ROUND(net_profit / NULLIF(total_rev, 0) * 100, 1) AS margin_pct
    FROM   ranked WHERE rev_rank = 1 AND ROWNUM = 1
),
best AS (
    SELECT MAX(br_city)    KEEP (DENSE_RANK FIRST ORDER BY net_profit DESC) AS br_city,
           MAX(net_profit)                                                AS net_profit,
           MAX(rev_rank)   KEEP (DENSE_RANK FIRST ORDER BY net_profit DESC) AS rev_rank
    FROM   ranked
),
worst AS (
    SELECT MIN(br_city)    KEEP (DENSE_RANK LAST  ORDER BY net_profit DESC) AS br_city,
           MIN(net_profit)                                                AS net_profit,
           MIN(rev_rank)   KEEP (DENSE_RANK LAST  ORDER BY net_profit DESC) AS rev_rank
    FROM   ranked
),
mrg AS (
    SELECT MAX(br_city) KEEP (DENSE_RANK FIRST ORDER BY net_profit / NULLIF(total_rev, 0) DESC) AS best_city,
           MAX(net_profit / NULLIF(total_rev, 0) * 100)                                          AS best_margin,
           MIN(br_city) KEEP (DENSE_RANK LAST  ORDER BY net_profit / NULLIF(total_rev, 0) DESC) AS worst_city,
           MIN(net_profit / NULLIF(total_rev, 0) * 100)                                          AS worst_margin
    FROM   ranked
),
stats AS (
    SELECT t.total_rev, t.cogs, t.salary_cost, t.expense_cost, t.net_profit,
           t.num_branches, t.in_black_net, t.in_black_precogs,
           tr.br_city AS top_city, tr.total_rev AS top_rev, tr.net_profit AS top_np,
           tr.profit_rank AS top_prank, tr.margin_rank AS top_mrank, tr.margin_pct AS top_margin,
           b.br_city AS best_city, b.net_profit AS best_np, b.rev_rank AS best_rrank,
           w.br_city AS worst_city, w.net_profit AS worst_np, w.rev_rank AS worst_rrank,
           m.best_city AS bm_city, m.best_margin, m.worst_city AS wm_city, m.worst_margin
    FROM   totals t CROSS JOIN top_rev tr CROSS JOIN best b CROSS JOIN worst w CROSS JOIN mrg m
)
SELECT 'Company revenue FY&focus_y (RM)'         AS metric_name,
       TO_CHAR(total_rev,    '999,999,999,990.00')                       AS metric_value FROM stats
UNION ALL SELECT 'Company COGS (RM)',
       TO_CHAR(cogs,         '999,999,999,990.00')                       FROM stats
UNION ALL SELECT 'Company salary cost (RM)',
       TO_CHAR(salary_cost,  '999,999,999,990.00')                       FROM stats
UNION ALL SELECT 'Company branch expenses (RM)',
       TO_CHAR(expense_cost, '999,999,999,990.00')                       FROM stats
UNION ALL SELECT 'Company net profit (RM)',
       TO_CHAR(net_profit,   'S999,999,999,990.00')                      FROM stats
UNION ALL SELECT 'Company margin %',
       TO_CHAR(net_profit / NULLIF(total_rev, 0) * 100, 'S990.0') || '%'      FROM stats
UNION ALL SELECT 'COGS as % of revenue',
       TO_CHAR(cogs / NULLIF(total_rev, 0) * 100, '990.0') || '%'             FROM stats
UNION ALL SELECT 'Salary as % of revenue',
       TO_CHAR(salary_cost / NULLIF(total_rev, 0) * 100, '990.0') || '%'      FROM stats
UNION ALL SELECT 'Expenses as % of revenue',
       TO_CHAR(expense_cost / NULLIF(total_rev, 0) * 100, '990.0') || '%'     FROM stats
UNION ALL SELECT 'Branches trading',
       TO_CHAR(num_branches)                                              FROM stats
UNION ALL SELECT 'Branches in the black (net)',
       TO_CHAR(in_black_net) || ' of ' || TO_CHAR(num_branches)           FROM stats
UNION ALL SELECT 'Branches in the black before COGS',
       TO_CHAR(in_black_precogs) || ' of ' || TO_CHAR(num_branches)       FROM stats
UNION ALL SELECT '-- the test --------------------------', ' ' FROM dual
UNION ALL SELECT 'Top-revenue branch',
       top_city || '  (RM ' || TRIM(TO_CHAR(top_rev, '999,999,990.00')) || ')' FROM stats
UNION ALL SELECT '   its net profit (RM)',
       'RM ' || TRIM(TO_CHAR(top_np, 'S999,999,990.00')) || '  = profit rank #'
       || TO_CHAR(top_prank) || ' of ' || TO_CHAR(num_branches)           FROM stats
UNION ALL SELECT '   its net margin',
       TRIM(TO_CHAR(top_margin, 'S990.0')) || '%  = margin rank #'
       || TO_CHAR(top_mrank) || ' of ' || TO_CHAR(num_branches)           FROM stats
UNION ALL SELECT 'Most profitable branch (RM)',
       best_city  || '  (RM ' || TRIM(TO_CHAR(best_np,  'S999,999,990.00'))
       || ', revenue rank #' || TO_CHAR(best_rrank) || ')'                FROM stats
UNION ALL SELECT 'Least profitable branch (RM)',
       worst_city || '  (RM ' || TRIM(TO_CHAR(worst_np, 'S999,999,990.00'))
       || ', revenue rank #' || TO_CHAR(worst_rrank) || ')'               FROM stats
UNION ALL SELECT 'Best margin',
       bm_city || '  (' || TRIM(TO_CHAR(best_margin,  'S990.0')) || '%)'  FROM stats
UNION ALL SELECT 'Worst margin',
       wm_city || '  (' || TRIM(TO_CHAR(worst_margin, 'S990.0')) || '%)'  FROM stats
UNION ALL SELECT '-- verdict ---------------------------', ' ' FROM dual
-- two yardsticks, two verdicts: in RM the biggest shop can post the
-- biggest loss; per ringgit of sales the same shop can be the best
UNION ALL SELECT 'PARADOX in RM (net profit)',
       CASE WHEN top_city = worst_city
            THEN 'HOLDS - ' || top_city || ' sells the most and loses the most (rank #'
                 || TO_CHAR(top_prank) || ' of ' || TO_CHAR(num_branches) || ')'
            ELSE 'DOES NOT HOLD - ' || top_city || ' is #' || TO_CHAR(top_prank)
                 || ' of ' || TO_CHAR(num_branches) || ' by RM; '
                 || worst_city || ' loses the most'
       END                                                                FROM stats
UNION ALL SELECT 'PARADOX in margin (per RM of sales)',
       CASE WHEN top_city = wm_city
            THEN 'HOLDS - ' || top_city || ' sells the most and has the worst margin'
            ELSE 'DOES NOT HOLD - ' || top_city || ' is #' || TO_CHAR(top_mrank)
                 || ' of ' || TO_CHAR(num_branches) || ' by margin; '
                 || wm_city || ' has the worst margin'
       END                                                                FROM stats;

PROMPT
PROMPT +==========================================================+
PROMPT |         END OF FY BRANCH PERFORMANCE PARADOX REPORT      |
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
UNDEFINE top_rev_id
UNDEFINE top_rev_city
UNDEFINE low_prof_id
UNDEFINE low_prof_city
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
