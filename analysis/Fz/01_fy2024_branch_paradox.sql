-- ===================================================================
-- 01_fy2024_branch_paradox.sql
-- SALES ANALYSIS - FY2024 BRANCH PERFORMANCE PARADOX
--   "Our top-revenue branch is our least profitable" - is it true,
--   and if a branch IS in the red, why?
--   company per year (money + customers) -> SLICE the focus year ->
--   the average branch per STATE -> every branch under its state ->
--   ONE branch (default Ipoh, the loss-maker) vs the average branch:
--   its customers -> WHY (staffing, purchasing, cost ratios, what-ifs).
--   The companion 01b_focus_branch_sales_mix.sql (same prompts) drills
--   the same branch into its product / service mix, loyalty tiers and
--   customer home cities.
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Fz\01_fy2024_branch_paradox.sql
--
-- PARAMETERS (prompted)
--   focus year   the financial year every slice zooms into (default 2024)
--   branch       the branch city sections 4-5 drill into (default Ipoh -
--                if the name matches nothing, the branch with the LOWEST
--                net profit in the focus year is taken)
--
-- WHAT IT ANSWERS
--   1. Is the branch that sells the most really the branch that keeps
--      the least?  (revenue rank vs net-profit rank vs margin rank,
--      side by side - the answer differs by yardstick, see below)
--   2. If not - who IS the least profitable, and WHY?  (cost structure:
--      COGS, payroll and rent as a share of what each branch sells)
--   3. Is the focus year a one-off, or the standing order of things?
--      (profit rank and margin rank of every branch in every year
--      2019-2025)
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
--               branch_utils_fact      rent, utilities and upkeep
--   dims      date_dim.cal_year / cal_quarter        -> the drill path
--             branch_dim.br_state / br_ID / br_city  -> the rows
--             customer_dim cus_ID / cus_state         -> who buys, from where
--             branch_utils_fact.util_name            -> expense split (rent)
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
--   Margin %        = net profit / revenue x 100  (printed as EARNING %
--                     in sections 1-3: how many sen of every ringgit sold
--                     the branch keeps)
--   Customer        = a distinct cus_ID (never customer_key: customer_dim
--                     is SCD2) with at least one COMPLETED order or visit
--                     in the period. A customer who shops at two branches
--                     counts once at each branch, once for the company.
--   New customer    = first ever transaction anywhere falls in the year
--   Local %         = customers whose home state (customer_dim.cus_state)
--                     is the branch's state (2, 3)
--
--   Every fact is cut on date_dim.cal_year through its date_key, never
--   on the pay_period / billing_period strings - so a December pay
--   period paid on 25 Jan counts in January's year, consistently for
--   both cost facts.
--
--   All facts are grouped on the branch NATURAL key (br_ID), not the
--   surrogate branch_key - branch_dim is SCD2, so one branch could own
--   several branch_key rows and must still roll up as one line.
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
--   - Written for sales_data5 (revision 5: 2019-2025, 17 branches).
--     Seremban, Kuantan, Subang Jaya and Bukit Jalil open 2024-01-01,
--     so they are blank before 2024 and ramp through their first year -
--     expect them in the red in FY2024 and positive in FY2025.
--   - Ipoh trades from 2019-01-15 but buys ALL its stock from an
--     Ipoh-only supplier (Perak Beauty Supplies) that charges 46-54 % of
--     the shelf price (33-43 % everywhere else) and 62-72 % from 2024 -
--     so its purchase cost % of sales is the number to watch.
--   - 2020 and 2021 carry MCO / FMCO closure months (salons shut, pay
--     cuts, rent rebates) - ranks in those years are distorted.
--
-- DIMENSIONS USED  (four; util_name is a text attribute on branch_utils_fact)
--   date_dim          cal_year, cal_date
--   branch_dim        br_ID, br_city, br_state
--   customer_dim      cus_ID, cus_state                (sections 1-4)
--   staff_dim         st_ID                            (section 5, heads)
--
-- REPORT SECTIONS  (each one is ONE OLAP operation)
--   1  COMPANY P+L AND CUSTOMERS         ROLL-UP    product / service /
--      PER YEAR                                     total sales, purchase
--                                                   cost, salary, expense,
--                                                   net profit, earning %,
--                                                   customers, new %, sales
--                                                   per customer
--   2  FOCUS YEAR BY STATE               SLICE +    the AVERAGE branch of
--                                        ROLL-UP    each state: avg sales,
--                                                   costs, profit, cost %,
--                                                   avg customers, new %,
--                                                   local %, sales/customer
--   3  FOCUS YEAR: EVERY BRANCH          SLICE      all 17 branches under
--                                                   their state: money +
--                                                   customers, AVERAGE
--                                                   branch as the last row
--   -- from here on: THE FOCUS BRANCH vs THE AVERAGE BRANCH --
--   4  FOCUS BRANCH: ITS CUSTOMERS        DRILL-     how many customers, new vs
--                                        ACROSS     returning, orders, visits,
--                                                   sales per customer, vs the
--                                                   average branch
--   5  WHY                                          cost structure side by
--                                                   side + what-ifs + verdict
--
--   The best-earning branch used as the yardstick in section 5 is NOT
--   hard-coded: the script looks it up for the focus year.
--
-- WHAT TO LOOK FOR  (FY2024, revision 5 = sales_data5, from the spool
--   of the full 2019-2025 load: 17 branches)
--   - Section 1: total sales RM 13.48 M (2019) -> 24.01 M (2024) ->
--     31.40 M (2025); earning % +7.5 (2019), -5.7 / -14.5 in the MCO
--     years, +21.2 (2022, the year the shop went online: sales +120 %),
--     +21.3 (2023), +16.6 (2024 - four new branches ramping up), +24.7
--     (2025, the men's line). Purchase cost ~39 % of sales, salary ~36 %,
--     branch expense ~8-9 % in 2024. Customers 8,383 (2019) -> 21,236
--     (2024) -> 26,002 (2025); 2019 shows NEW 100 % because it is the
--     first year of history; ~RM 1,100-1,300 per customer from 2022.
--   - Section 2: Johor (Johor Bahru alone) has the highest average
--     sales per branch (RM 1.86 M), then Selangor (6 branches, RM 1.72 M
--     avg, best earning % +22.7) and Wilayah Persekutuan (5). Klang
--     Valley branches serve ~2,700-3,200 customers each, 76-80 % local;
--     the single-branch states 34-37 % local (online orders are fulfilled
--     by any branch since 2022). Three states are in the red: Negeri
--     Sembilan and Pahang (Seremban / Kuantan, opened 2024-01-01 and still
--     ramping: salary 57-58 % of sales, 42-46 % new customers) and Perak -
--     Ipoh, in its sixth year, with purchase cost 64.9 % of sales.
--     Company average branch: RM 1.41 M sales, 2,674 customers,
--     RM 235 k net profit, +16.6 %.
--   - Section 3: Petaling Jaya leads by every yardstick (RM 3.34 M,
--     +33.2 %, 5,960 customers), Kuala Lumpur second (RM 2.43 M, +21.4 %,
--     4,664) - the "top-revenue branch is the least profitable" paradox
--     is FALSE in this data. The four 2024 openings are the thin ones
--     (Subang Jaya +3.6 %, Bukit Jalil -7.3 %, Seremban -9.7 %, Kuantan
--     -11.7 %), and Ipoh (-8.7 %) is the only ESTABLISHED branch in the
--     red: 1,695 customers (vs 2,674 average) spending RM 458 each (vs
--     528). Sales per customer is flat across the other branches - they
--     differ in HOW MANY customers they have, not in what each spends.
--   - Section 4 - Ipoh's customers: 1,695 vs 2,674 at the average branch
--     (-37 %), 29.9 % of them new (28.9 % average), 1.85 transactions
--     each (2.05). Fewer customers who buy a little less - that explains
--     the smaller top line, not the loss. (01b shows the same product /
--     service mix as the company at ~half the average branch's volume.)
--   - Section 5 - THE WHY is PURCHASING: Ipoh's purchase cost is 64.9 %
--     of sales against 39.1 % at the average branch (+25.8 pts) - it
--     buys everything from its Ipoh-only supplier (Perak Beauty
--     Supplies) at 62-72 % of shelf price since 2024 (46-54 % before,
--     33-43 % everywhere else). Payroll and premises are on par (salary
--     36.0 % vs 35.8 %, expense 7.8 % vs 8.5 %, 8 heads with the highest
--     sales per head after PJ). What-ifs: at the average salary ratio it
--     saves almost nothing (RM 1 k); at the average PURCHASE ratio it
--     would earn RM +133 k (+17 %); it must sell RM 968 k (+25 %) to break
--     even on the current cost structure. Verdict: PURCHASING.
--   - Run it with year 2023 to see Ipoh in the black (+15.9 %, purchase
--     cost 51 %), with year 2025 to see the new branches turn positive
--     while Ipoh stays red (-2.6 %), with branch = Kuantan for the
--     opening-year story (PAYROLL sized for a mature branch, customer base
--     of a new one), or with a nonsense branch name to land on the least
--     profitable branch automatically.
-- ===================================================================

-- reset anything a previous script left behind in this session
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 165
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

-- SQL*Plus caps an ACCEPT prompt at 99 characters - keep it short.
ACCEPT focus_year  NUMBER DEFAULT 2024       PROMPT 'Focus year (default 2024): '
ACCEPT focus_branch CHAR  DEFAULT 'Ipoh'     PROMPT 'Branch city for sections 4-5 (default Ipoh): '

-- ---- values reused in every title ---------------------------------
-- TERMOUT OFF hides these helper queries (only works when the file is
-- run with @, which is how this report is meant to be run). TO_CHAR
-- keeps the numbers from being captured with leading spaces.
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN focus_y NEW_VALUE focus_y NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;

-- ---- the branch sections 4-5 drill into -----------------------------
-- focus_*  = the branch whose city matches the prompt (default Ipoh,
--            the loss-making one). If nothing matches, the script falls
--            back to the branch with the LOWEST net profit in the focus
--            year, so the drill always lands on the branch that most
--            needs explaining.
-- best_*   = the branch with the highest earning % in the focus year -
--            the yardstick sections 6 and 7 compare against.
COLUMN focus_id     NEW_VALUE focus_id     NOPRINT
COLUMN focus_city   NEW_VALUE focus_city   NOPRINT
COLUMN focus_br_state NEW_VALUE focus_br_state NOPRINT
COLUMN best_id      NEW_VALUE best_id      NOPRINT
COLUMN best_city    NEW_VALUE best_city    NOPRINT

WITH pnl AS (
    SELECT br_ID, br_city, br_state,
           SUM(rev) AS rev, SUM(cost) AS cost
    FROM (
        SELECT b.br_ID, b.br_city, b.br_state,
               SUM(f.order_total_amt - f.order_tax_amt) AS rev, 0 AS cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               SUM(f.serv_total_amt - f.serv_tax_amt), 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               0, SUM(f.purchase_total_cost)
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               0, SUM(f.base_amount + f.bonus_amount)
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               0, SUM(f.payment_amount)
        FROM   branch_utils_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
    )
    GROUP BY br_ID, br_city, br_state
),
cand AS (
    SELECT br_ID, br_city, br_state, rev - cost AS net,
           (rev - cost) / NULLIF(rev, 0) AS margin,
           CASE WHEN UPPER(br_city) LIKE '%' || UPPER(TRIM('&focus_branch')) || '%'
                THEN 0 ELSE 1 END AS miss
    FROM   pnl
)
SELECT TO_CHAR(MAX(br_ID) KEEP (DENSE_RANK FIRST ORDER BY miss, net))       AS focus_id,
       MAX(br_city)       KEEP (DENSE_RANK FIRST ORDER BY miss, net)        AS focus_city,
       MAX(br_state)      KEEP (DENSE_RANK FIRST ORDER BY miss, net)        AS focus_br_state,
       TO_CHAR(MAX(br_ID) KEEP (DENSE_RANK FIRST ORDER BY margin DESC NULLS LAST)) AS best_id,
       MAX(br_city)       KEEP (DENSE_RANK FIRST ORDER BY margin DESC NULLS LAST)  AS best_city
FROM   cand;

CLEAR COLUMNS
SET TERMOUT ON

SPOOL fy2024_branch_paradox_output.txt


-- ###################################################################
-- SECTION 1 - COMPANY P+L AND CUSTOMERS PER YEAR
-- OLAP: ROLL-UP to year grain over all five facts, all branches, plus
-- the customer side of the same year: how many distinct customers
-- bought, how many were NEW (first ever seen that year) and what each
-- one was worth. EARNING % = net profit / total sales.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. COMPANY P+L AND CUSTOMERS PER YEAR' SKIP 1 -
       CENTER 'ALL BRANCHES, 2019 - 2025 (ROLL-UP)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year      HEADING 'YEAR'                 FORMAT 9999
COLUMN product_rev   HEADING 'PRODUCT|SALES (RM)'   FORMAT 999,999,990.00
COLUMN service_rev   HEADING 'SERVICE|SALES (RM)'   FORMAT 999,999,990.00
COLUMN total_rev     HEADING 'TOTAL|SALES (RM)'     FORMAT 999,999,990.00
COLUMN cogs          HEADING 'PURCHASE|COST (RM)'   FORMAT 999,999,990.00
COLUMN salary_cost   HEADING 'SALARY|PAID (RM)'     FORMAT 999,999,990.00
COLUMN expense_cost  HEADING 'BRANCH|EXPENSE (RM)'  FORMAT 999,999,990.00
COLUMN net_profit    HEADING 'NET|PROFIT (RM)'      FORMAT S999,999,990.00
COLUMN earning_pct   HEADING 'EARNING|%'            FORMAT S990.0
COLUMN customers     HEADING 'CUSTOMERS'            FORMAT 999,990
COLUMN new_pct       HEADING 'NEW|%'                FORMAT 990.0
COLUMN sales_cus     HEADING 'SALES PER|CUSTOMER'   FORMAT 99,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF product_rev service_rev total_rev cogs salary_cost expense_cost net_profit ON REPORT

WITH pnl AS (
    -- year-grain base: one row per branch / year with all five money
    -- measures side by side (drill-across on date + branch)
    SELECT br_ID, cal_year,
           SUM(product_rev)  AS product_rev,
           SUM(service_rev)  AS service_rev,
           SUM(cogs)         AS cogs,
           SUM(salary_cost)  AS salary_cost,
           SUM(expense_cost) AS expense_cost
    FROM (
        SELECT b.br_ID, d.cal_year,
               SUM(f.order_total_amt - f.order_tax_amt) AS product_rev,
               0 AS service_rev, 0 AS cogs, 0 AS salary_cost, 0 AS expense_cost
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        GROUP  BY b.br_ID, d.cal_year
        UNION ALL
        SELECT b.br_ID, d.cal_year,
               0, SUM(f.serv_total_amt - f.serv_tax_amt), 0, 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        GROUP  BY b.br_ID, d.cal_year
        UNION ALL
        SELECT b.br_ID, d.cal_year,
               0, 0, SUM(f.purchase_total_cost), 0, 0
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, d.cal_year
        UNION ALL
        SELECT b.br_ID, d.cal_year,
               0, 0, 0, SUM(f.base_amount + f.bonus_amount), 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, d.cal_year
        UNION ALL
        SELECT b.br_ID, d.cal_year,
               0, 0, 0, 0, SUM(f.payment_amount)
        FROM   branch_utils_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        GROUP  BY b.br_ID, d.cal_year
    )
    GROUP BY br_ID, cal_year
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
),
cus_year AS (
    -- one row per customer per year they bought (orders or visits,
    -- Completed only); first_year marks when they were first seen
    SELECT cus_ID, cal_year, MIN(cal_year) OVER (PARTITION BY cus_ID) AS first_year
    FROM (
        SELECT c.cus_ID, d.cal_year
        FROM   order_fact   f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        WHERE  f.order_status = 'Completed'
        UNION
        SELECT c.cus_ID, d.cal_year
        FROM   reservation_fact f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        WHERE  f.res_status = 'Completed'
    )
),
cust AS (
    SELECT cal_year, COUNT(*) AS customers,
           SUM(CASE WHEN first_year = cal_year THEN 1 ELSE 0 END) AS new_cus
    FROM   cus_year
    GROUP  BY cal_year
)
SELECT y.cal_year, y.product_rev, y.service_rev, y.total_rev, y.cogs, y.salary_cost, y.expense_cost,
       y.net_profit,
       ROUND(y.net_profit / NULLIF(y.total_rev, 0) * 100, 1)           AS earning_pct,
       c.customers,
       ROUND(c.new_cus / NULLIF(c.customers, 0) * 100, 1)              AS new_pct,
       ROUND(y.total_rev / NULLIF(c.customers, 0), 2)                  AS sales_cus
FROM   company_year y
LEFT   JOIN cust c ON c.cal_year = y.cal_year
ORDER  BY y.cal_year;


-- ###################################################################
-- SECTION 2 - FOCUS YEAR BY STATE: THE AVERAGE BRANCH
-- OLAP: SLICE (cal_year = focus year) then ROLL-UP branch -> state.
-- One row per state: how many branches trade there and what the
-- AVERAGE branch in that state sold, spent, kept and served - with
-- the cost lines and the earning as a % of the state's sales, the
-- average number of customers per branch, how many of them were NEW
-- this year, how many are LOCAL (home state = branch state) and what
-- each customer was worth. The last row is the average branch of the
-- whole company.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. FY&focus_y BY STATE: THE AVERAGE BRANCH' SKIP 1 -
       CENTER 'PER-BRANCH AVERAGES, COST / EARNING %, CUSTOMERS (SLICE: YEAR = &focus_y, ROLL-UP TO STATE)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_state      HEADING 'STATE'                FORMAT A19
COLUMN branches      HEADING 'BR'                   FORMAT 99
COLUMN avg_sales     HEADING 'AVG TOTAL|SALES (RM)' FORMAT 9,999,990.00
COLUMN avg_cogs      HEADING 'AVG PURCH|COST (RM)'  FORMAT 9,999,990.00
COLUMN avg_salary    HEADING 'AVG SALARY|PAID (RM)' FORMAT 9,999,990.00
COLUMN avg_expense   HEADING 'AVG BRANCH|EXPENSE'   FORMAT 999,990.00
COLUMN avg_profit    HEADING 'AVG NET|PROFIT (RM)'  FORMAT S9,999,990.00
COLUMN cogs_pct      HEADING 'PURCH|%'              FORMAT 990.0
COLUMN salary_pct    HEADING 'SALARY|%'             FORMAT 990.0
COLUMN expense_pct   HEADING 'EXPENSE|%'            FORMAT 990.0
COLUMN earning_pct   HEADING 'EARNING|%'            FORMAT S990.0
COLUMN avg_cust      HEADING 'AVG CUST|PER BR'      FORMAT 99,990
COLUMN new_pct       HEADING 'NEW|%'                FORMAT 990.0
COLUMN local_pct     HEADING 'LOCAL|%'              FORMAT 990.0
COLUMN sales_cus     HEADING 'SALES PER|CUSTOMER'   FORMAT 9,990.00
COLUMN sort_key      NOPRINT

WITH pnl AS (
    -- one row per branch for the focus year (state carried along)
    SELECT br_ID, br_state,
           SUM(rev) AS rev, SUM(cogs) AS cogs, SUM(sal) AS sal, SUM(exp) AS exp
    FROM (
        SELECT b.br_ID, b.br_state,
               SUM(f.order_total_amt - f.order_tax_amt) AS rev, 0 AS cogs, 0 AS sal, 0 AS exp
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_state,
               SUM(f.serv_total_amt - f.serv_tax_amt), 0, 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_state,
               0, SUM(f.purchase_total_cost), 0, 0
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_state,
               0, 0, SUM(f.base_amount + f.bonus_amount), 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_state,
               0, 0, 0, SUM(f.payment_amount)
        FROM   branch_utils_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_state
    )
    GROUP BY br_ID, br_state
),
txn AS (
    -- customer side, all years (needed to know when a customer was first seen)
    SELECT b.br_ID, b.br_state, c.cus_ID, c.cus_state, d.cal_year
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    UNION ALL
    SELECT b.br_ID, b.br_state, c.cus_ID, c.cus_state, d.cal_year
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
),
first_seen AS (
    SELECT cus_ID, MIN(cal_year) AS first_year FROM txn GROUP BY cus_ID
),
cust AS (
    SELECT t.br_ID,
           COUNT(DISTINCT t.cus_ID)                                                    AS customers,
           COUNT(DISTINCT CASE WHEN fs.first_year = &focus_year THEN t.cus_ID END)      AS new_cus,
           COUNT(DISTINCT CASE WHEN t.cus_state = t.br_state THEN t.cus_ID END)         AS local_cus
    FROM   txn t JOIN first_seen fs ON fs.cus_ID = t.cus_ID
    WHERE  t.cal_year = &focus_year
    GROUP  BY t.br_ID
),
by_state AS (
    -- roll-up branch -> state (plus the whole company as one more row)
    SELECT p.br_state, COUNT(*) AS branches,
           SUM(p.rev) AS sales, SUM(p.cogs) AS cogs, SUM(p.sal) AS sal, SUM(p.exp) AS exp,
           SUM(c.customers) AS customers, SUM(c.new_cus) AS new_cus, SUM(c.local_cus) AS local_cus,
           1 AS sort_key
    FROM   pnl p LEFT JOIN cust c ON c.br_ID = p.br_ID
    GROUP  BY p.br_state
    UNION ALL
    SELECT 'ALL STATES', COUNT(*),
           SUM(p.rev), SUM(p.cogs), SUM(p.sal), SUM(p.exp),
           SUM(c.customers), SUM(c.new_cus), SUM(c.local_cus), 2
    FROM   pnl p LEFT JOIN cust c ON c.br_ID = p.br_ID
)
SELECT br_state, branches,
       sales / branches                                    AS avg_sales,
       cogs  / branches                                    AS avg_cogs,
       sal   / branches                                    AS avg_salary,
       exp   / branches                                    AS avg_expense,
       (sales - cogs - sal - exp) / branches               AS avg_profit,
       ROUND(cogs / NULLIF(sales, 0) * 100, 1)             AS cogs_pct,
       ROUND(sal  / NULLIF(sales, 0) * 100, 1)             AS salary_pct,
       ROUND(exp  / NULLIF(sales, 0) * 100, 1)             AS expense_pct,
       ROUND((sales - cogs - sal - exp) / NULLIF(sales, 0) * 100, 1) AS earning_pct,
       ROUND(customers / branches)                         AS avg_cust,
       ROUND(new_cus   / NULLIF(customers, 0) * 100, 1)    AS new_pct,
       ROUND(local_cus / NULLIF(customers, 0) * 100, 1)    AS local_pct,
       ROUND(sales / NULLIF(customers, 0), 2)              AS sales_cus,
       sort_key
FROM   by_state
ORDER  BY sort_key, avg_sales DESC;


-- ###################################################################
-- SECTION 3 - FOCUS YEAR: EVERY BRANCH, STATE BY STATE
-- OLAP: SLICE (year = focus year) down to the branch grain, all 13
-- branches grouped under their state (biggest branch first inside a
-- state): sales, each cost line, net profit, earning %, and the
-- customer side - customers served, NEW %, LOCAL % and sales per
-- customer. The last row is the AVERAGE branch (mean of the 13 rows),
-- the yardstick section 4 uses.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. FY&focus_y EVERY BRANCH, STATE BY STATE' SKIP 1 -
       CENTER 'MONEY AND CUSTOMERS, ONE ROW PER BRANCH, AVERAGE BRANCH LAST (SLICE: YEAR = &focus_y)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_state      HEADING 'STATE'                FORMAT A19
COLUMN br_city       HEADING 'BRANCH'               FORMAT A14
COLUMN total_rev     HEADING 'TOTAL|SALES (RM)'     FORMAT 99,999,990.00
COLUMN cogs          HEADING 'PURCHASE|COST (RM)'   FORMAT 9,999,990.00
COLUMN salary_cost   HEADING 'SALARY|PAID (RM)'     FORMAT 9,999,990.00
COLUMN expense_cost  HEADING 'BRANCH|EXPENSE (RM)'  FORMAT 9,999,990.00
COLUMN net_profit    HEADING 'NET|PROFIT (RM)'      FORMAT S9,999,990.00
COLUMN earning_pct   HEADING 'EARNING|%'            FORMAT S990.0
COLUMN customers     HEADING 'CUSTOMERS'            FORMAT 99,990
COLUMN new_pct       HEADING 'NEW|%'                FORMAT 990.0
COLUMN local_pct     HEADING 'LOCAL|%'              FORMAT 990.0
COLUMN sales_cus     HEADING 'SALES PER|CUSTOMER'   FORMAT 9,990.00
COLUMN br_ID         NOPRINT

-- state printed once per group; the report row is the AVERAGE branch
-- (mean of the branch rows - the % and per-customer columns are the
-- mean of the branch values, not recomputed from totals)
BREAK ON br_state SKIP 1 ON REPORT
COMPUTE AVG LABEL 'AVERAGE BRANCH' OF total_rev cogs salary_cost expense_cost net_profit earning_pct customers new_pct local_pct sales_cus ON REPORT

WITH pnl AS (
    SELECT br_ID, br_city, br_state,
           SUM(rev) AS rev, SUM(cogs) AS cogs, SUM(sal) AS sal, SUM(exp) AS exp
    FROM (
        SELECT b.br_ID, b.br_city, b.br_state,
               SUM(f.order_total_amt - f.order_tax_amt) AS rev, 0 AS cogs, 0 AS sal, 0 AS exp
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               SUM(f.serv_total_amt - f.serv_tax_amt), 0, 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               0, SUM(f.purchase_total_cost), 0, 0
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               0, 0, SUM(f.base_amount + f.bonus_amount), 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT b.br_ID, b.br_city, b.br_state,
               0, 0, 0, SUM(f.payment_amount)
        FROM   branch_utils_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city, b.br_state
    )
    GROUP BY br_ID, br_city, br_state
),
txn AS (
    SELECT b.br_ID, b.br_state, c.cus_ID, c.cus_state, d.cal_year
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    UNION ALL
    SELECT b.br_ID, b.br_state, c.cus_ID, c.cus_state, d.cal_year
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
),
first_seen AS (
    SELECT cus_ID, MIN(cal_year) AS first_year FROM txn GROUP BY cus_ID
),
cust AS (
    SELECT t.br_ID,
           COUNT(DISTINCT t.cus_ID)                                                    AS customers,
           COUNT(DISTINCT CASE WHEN fs.first_year = &focus_year THEN t.cus_ID END)      AS new_cus,
           COUNT(DISTINCT CASE WHEN t.cus_state = t.br_state THEN t.cus_ID END)         AS local_cus
    FROM   txn t JOIN first_seen fs ON fs.cus_ID = t.cus_ID
    WHERE  t.cal_year = &focus_year
    GROUP  BY t.br_ID
)
SELECT p.br_state, p.br_city,
       p.rev                                                         AS total_rev,
       p.cogs, p.sal AS salary_cost, p.exp AS expense_cost,
       p.rev - p.cogs - p.sal - p.exp                                AS net_profit,
       ROUND((p.rev - p.cogs - p.sal - p.exp) / NULLIF(p.rev, 0) * 100, 1) AS earning_pct,
       c.customers,
       ROUND(c.new_cus   / NULLIF(c.customers, 0) * 100, 1)          AS new_pct,
       ROUND(c.local_cus / NULLIF(c.customers, 0) * 100, 1)          AS local_pct,
       ROUND(p.rev / NULLIF(c.customers, 0), 2)                      AS sales_cus,
       p.br_ID
FROM   pnl p
LEFT   JOIN cust c ON c.br_ID = p.br_ID
ORDER  BY p.br_state, p.rev DESC;


-- ###################################################################
-- SECTION 4 - THE FOCUS BRANCH: ITS CUSTOMERS IN THE FOCUS YEAR
-- OLAP: DRILL-ACROSS order_fact + reservation_fact on customer_dim
-- for the focus branch, with the AVERAGE branch underneath. A
-- customer = a distinct cus_ID (never customer_key - SCD2) who
-- COMPLETED at least one order or visit at the branch in the year.
-- NEW = the customer's first-ever transaction anywhere in the company
-- falls in the focus year; RETURNING = seen before.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. FY&focus_y &focus_city: HOW MANY CUSTOMERS, HOW MUCH SALES' SKIP 1 -
       CENTER 'THE FOCUS BRANCH vs THE AVERAGE BRANCH' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN role          HEADING 'BRANCH'               FORMAT A16
COLUMN customers     HEADING 'CUSTOMERS'            FORMAT 99,990
COLUMN new_cus       HEADING 'NEW'                  FORMAT 99,990
COLUMN ret_cus       HEADING 'RETURNING'            FORMAT 99,990
COLUMN new_pct       HEADING 'NEW|%'                FORMAT 990.0
COLUMN orders        HEADING 'ORDERS'               FORMAT 99,990
COLUMN visits        HEADING 'VISITS'               FORMAT 99,990
COLUMN sales         HEADING 'TOTAL|SALES (RM)'     FORMAT 9,999,990.00
COLUMN sales_cus     HEADING 'SALES PER|CUSTOMER'   FORMAT 99,990.00
COLUMN txn_cus       HEADING 'TXNS PER|CUSTOMER'    FORMAT 90.00
COLUMN sort_key      NOPRINT

WITH txn AS (
    -- every completed order and visit, all years, with the customer
    -- (all years are needed to know when a customer was first seen)
    SELECT b.br_ID, c.cus_ID, d.cal_date, d.cal_year, 'O' AS kind, f.order_ID AS txn_id,
           f.order_total_amt - f.order_tax_amt AS amt
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    UNION ALL
    SELECT b.br_ID, c.cus_ID, d.cal_date, d.cal_year, 'R', f.res_ID,
           f.serv_total_amt - f.serv_tax_amt
    FROM   reservation_fact f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.res_status = 'Completed'
),
first_seen AS (
    SELECT cus_ID, MIN(cal_date) AS first_dt FROM txn GROUP BY cus_ID
),
yr AS (
    SELECT t.br_ID, t.cus_ID, t.kind, t.txn_id, t.amt,
           CASE WHEN EXTRACT(YEAR FROM fs.first_dt) = &focus_year THEN 1 ELSE 0 END AS is_new
    FROM   txn t
    JOIN   first_seen fs ON fs.cus_ID = t.cus_ID
    WHERE  t.cal_year = &focus_year
),
per_branch AS (
    SELECT br_ID,
           COUNT(DISTINCT cus_ID)                                     AS customers,
           COUNT(DISTINCT CASE WHEN is_new = 1 THEN cus_ID END)       AS new_cus,
           COUNT(DISTINCT CASE WHEN kind = 'O' THEN txn_id END)       AS orders,
           COUNT(DISTINCT CASE WHEN kind = 'R' THEN txn_id END)       AS visits,
           SUM(amt)                                                   AS sales
    FROM   yr
    GROUP  BY br_ID
),
rows_ AS (
    SELECT UPPER('&focus_city') AS role, customers, new_cus, orders, visits, sales, 1 AS sort_key
    FROM   per_branch WHERE br_ID = &focus_id
    UNION ALL
    SELECT 'AVERAGE BRANCH', AVG(customers), AVG(new_cus), AVG(orders), AVG(visits), AVG(sales), 2
    FROM   per_branch
)
SELECT role, customers, new_cus,
       customers - new_cus                                   AS ret_cus,
       ROUND(new_cus / NULLIF(customers, 0) * 100, 1)        AS new_pct,
       orders, visits, sales,
       ROUND(sales / NULLIF(customers, 0), 2)                AS sales_cus,
       ROUND((orders + visits) / NULLIF(customers, 0), 2)    AS txn_cus,
       sort_key
FROM   rows_
ORDER  BY 11;


-- ###################################################################
-- SECTION 5 - WHY: THE FOCUS BRANCH vs THE AVERAGE AND THE BEST BRANCH
-- The cost structure side by side - staffing, sales per head, salary
-- per head, every cost line as % of sales - then two what-ifs that
-- size the problem: what profit would be at the average branch's
-- salary ratio, and how much the branch must sell to break even on
-- its current cost base.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. FY&focus_y WHY IS &focus_city WHERE IT IS?' SKIP 1 -
       CENTER 'FOCUS BRANCH vs THE AVERAGE BRANCH vs &best_city (BEST EARNING %)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC'                    FORMAT A37
COLUMN v_focus      HEADING '&focus_city'                FORMAT A16 JUSTIFY RIGHT
COLUMN v_avg        HEADING 'AVERAGE|BRANCH'             FORMAT A16 JUSTIFY RIGHT
COLUMN v_best       HEADING '&best_city'                 FORMAT A16 JUSTIFY RIGHT
COLUMN v_gap        HEADING 'FOCUS vs|AVERAGE'           FORMAT A18 JUSTIFY RIGHT
COLUMN sort_key     NOPRINT

WITH pnl AS (
    SELECT br_ID, br_city,
           SUM(rev) AS rev, SUM(cogs) AS cogs, SUM(sal) AS sal, SUM(exp) AS exp, SUM(rent) AS rent
    FROM (
        SELECT b.br_ID, b.br_city,
               SUM(f.order_total_amt - f.order_tax_amt) AS rev, 0 AS cogs, 0 AS sal, 0 AS exp, 0 AS rent
        FROM   order_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               SUM(f.serv_total_amt - f.serv_tax_amt), 0, 0, 0, 0
        FROM   reservation_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, SUM(f.purchase_total_cost), 0, 0, 0
        FROM   purchase_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        SELECT b.br_ID, b.br_city,
               0, 0, SUM(f.base_amount + f.bonus_amount), 0, 0
        FROM   salary_payment_fact f
        JOIN   date_dim   d ON d.date_key   = f.date_key
        JOIN   branch_dim b ON b.branch_key = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
        UNION ALL
        -- expenses carry the third dimension: rent is split out here
        SELECT b.br_ID, b.br_city,
               0, 0, 0, SUM(f.payment_amount),
               SUM(CASE WHEN f.util_name = 'Rent' THEN f.payment_amount ELSE 0 END)
        FROM   branch_utils_fact f
        JOIN   date_dim         d ON d.date_key         = f.date_key
        JOIN   branch_dim       b ON b.branch_key       = f.branch_key
        WHERE  d.cal_year = &focus_year
        GROUP  BY b.br_ID, b.br_city
    )
    GROUP BY br_ID, br_city
),
heads AS (
    SELECT b.br_ID, COUNT(DISTINCT s.st_ID) AS heads
    FROM   salary_payment_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    JOIN   staff_dim  s ON s.staff_key  = f.staff_key
    WHERE  d.cal_year = &focus_year
    GROUP  BY b.br_ID
),
m AS (
    SELECT p.br_ID, p.br_city, p.rev, p.cogs, p.sal, p.exp, p.rent, NVL(h.heads, 0) AS heads,
           p.rev - p.cogs - p.sal - p.exp AS net
    FROM   pnl p LEFT JOIN heads h ON h.br_ID = p.br_ID
),
-- one-row helper blocks, CROSS JOINed below (Oracle 11g rejects KEEP /
-- scalar subqueries inside an aggregate SELECT list - ORA-00937)
fx AS (SELECT * FROM m WHERE br_ID = &focus_id),
bx AS (SELECT * FROM m WHERE br_ID = &best_id),
ax AS (
    -- the average branch: every sum / number of branches; ratios from the sums
    SELECT SUM(rev) / COUNT(*) AS rev, SUM(cogs) / COUNT(*) AS cogs, SUM(sal) / COUNT(*) AS sal,
           SUM(exp) / COUNT(*) AS exp, SUM(rent) / COUNT(*) AS rent, SUM(heads) / COUNT(*) AS heads,
           SUM(net) / COUNT(*) AS net
    FROM   m
),
x AS (
    SELECT fx.rev  AS f_rev,  ax.rev  AS a_rev,  bx.rev  AS b_rev,
           fx.cogs AS f_cogs, ax.cogs AS a_cogs, bx.cogs AS b_cogs,
           fx.sal  AS f_sal,  ax.sal  AS a_sal,  bx.sal  AS b_sal,
           fx.exp  AS f_exp,  ax.exp  AS a_exp,  bx.exp  AS b_exp,
           fx.rent AS f_rent, ax.rent AS a_rent, bx.rent AS b_rent,
           fx.heads AS f_heads, ax.heads AS a_heads, bx.heads AS b_heads,
           fx.net  AS f_net,  ax.net  AS a_net,  bx.net  AS b_net
    FROM   fx CROSS JOIN ax CROSS JOIN bx
)
-- outer SELECT only right-aligns the four value columns with LPAD/TRIM,
-- the rows are built by the UNION ALL inside (no semicolon in these
-- comments - SQL*Plus would end the statement there)
SELECT metric_name,
       LPAD(TRIM(v_focus), 16) AS v_focus, LPAD(TRIM(v_avg), 16) AS v_avg,
       LPAD(TRIM(v_best), 16) AS v_best,  LPAD(TRIM(v_gap), 18) AS v_gap, sort_key
FROM (
SELECT 'Total sales (RM)' AS metric_name,
       TO_CHAR(f_rev, '99,999,990') AS v_focus, TO_CHAR(a_rev, '99,999,990') AS v_avg,
       TO_CHAR(b_rev, '99,999,990') AS v_best,
       TO_CHAR((f_rev - a_rev) / NULLIF(a_rev, 0) * 100, 'S990.0') || '%' AS v_gap, 1 AS sort_key
FROM   x
UNION ALL SELECT 'Heads paid in the year',
       TO_CHAR(f_heads, '990'), TO_CHAR(a_heads, '990.0'), TO_CHAR(b_heads, '990'),
       TO_CHAR((f_heads - a_heads) / NULLIF(a_heads, 0) * 100, 'S990.0') || '%', 2 FROM x
UNION ALL SELECT 'Sales per head (RM)',
       TO_CHAR(f_rev / NULLIF(f_heads, 0), '99,999,990'), TO_CHAR(a_rev / NULLIF(a_heads, 0), '99,999,990'),
       TO_CHAR(b_rev / NULLIF(b_heads, 0), '99,999,990'),
       TO_CHAR((f_rev / NULLIF(f_heads, 0) - a_rev / NULLIF(a_heads, 0))
               / NULLIF(a_rev / NULLIF(a_heads, 0), 0) * 100, 'S990.0') || '%', 3 FROM x
UNION ALL SELECT 'Salary per head (RM)',
       TO_CHAR(f_sal / NULLIF(f_heads, 0), '99,999,990'), TO_CHAR(a_sal / NULLIF(a_heads, 0), '99,999,990'),
       TO_CHAR(b_sal / NULLIF(b_heads, 0), '99,999,990'),
       TO_CHAR((f_sal / NULLIF(f_heads, 0) - a_sal / NULLIF(a_heads, 0))
               / NULLIF(a_sal / NULLIF(a_heads, 0), 0) * 100, 'S990.0') || '%', 4 FROM x
UNION ALL SELECT 'Salary paid % of sales',
       TO_CHAR(f_sal / NULLIF(f_rev, 0) * 100, '990.0') || '%', TO_CHAR(a_sal / NULLIF(a_rev, 0) * 100, '990.0') || '%',
       TO_CHAR(b_sal / NULLIF(b_rev, 0) * 100, '990.0') || '%',
       TO_CHAR((f_sal / NULLIF(f_rev, 0) - a_sal / NULLIF(a_rev, 0)) * 100, 'S990.0') || ' pts', 5 FROM x
UNION ALL SELECT 'Purchase cost % of sales',
       TO_CHAR(f_cogs / NULLIF(f_rev, 0) * 100, '990.0') || '%', TO_CHAR(a_cogs / NULLIF(a_rev, 0) * 100, '990.0') || '%',
       TO_CHAR(b_cogs / NULLIF(b_rev, 0) * 100, '990.0') || '%',
       TO_CHAR((f_cogs / NULLIF(f_rev, 0) - a_cogs / NULLIF(a_rev, 0)) * 100, 'S990.0') || ' pts', 6 FROM x
UNION ALL SELECT 'Branch expense % of sales',
       TO_CHAR(f_exp / NULLIF(f_rev, 0) * 100, '990.0') || '%', TO_CHAR(a_exp / NULLIF(a_rev, 0) * 100, '990.0') || '%',
       TO_CHAR(b_exp / NULLIF(b_rev, 0) * 100, '990.0') || '%',
       TO_CHAR((f_exp / NULLIF(f_rev, 0) - a_exp / NULLIF(a_rev, 0)) * 100, 'S990.0') || ' pts', 7 FROM x
UNION ALL SELECT '   of which rent % of sales',
       TO_CHAR(f_rent / NULLIF(f_rev, 0) * 100, '990.0') || '%', TO_CHAR(a_rent / NULLIF(a_rev, 0) * 100, '990.0') || '%',
       TO_CHAR(b_rent / NULLIF(b_rev, 0) * 100, '990.0') || '%',
       TO_CHAR((f_rent / NULLIF(f_rev, 0) - a_rent / NULLIF(a_rev, 0)) * 100, 'S990.0') || ' pts', 8 FROM x
UNION ALL SELECT 'Net profit (RM)',
       TO_CHAR(f_net, 'S99,999,990'), TO_CHAR(a_net, 'S99,999,990'), TO_CHAR(b_net, 'S99,999,990'),
       TO_CHAR(f_net - a_net, 'S99,999,990'), 9 FROM x
UNION ALL SELECT 'Earning %',
       TO_CHAR(f_net / NULLIF(f_rev, 0) * 100, 'S990.0') || '%', TO_CHAR(a_net / NULLIF(a_rev, 0) * 100, 'S990.0') || '%',
       TO_CHAR(b_net / NULLIF(b_rev, 0) * 100, 'S990.0') || '%',
       TO_CHAR((f_net / NULLIF(f_rev, 0) - a_net / NULLIF(a_rev, 0)) * 100, 'S990.0') || ' pts', 10 FROM x
UNION ALL SELECT '-- what if ----------------------', ' ', ' ', ' ', ' ', 11 FROM dual
-- what-if 1: same sales, but payroll at the AVERAGE branch's % of sales
UNION ALL SELECT 'Payroll at the average % of sales',
       'RM ' || TRIM(TO_CHAR(f_rev * a_sal / NULLIF(a_rev, 0), '99,999,990')), ' ', ' ',
       'saves ' || TRIM(TO_CHAR(f_sal - f_rev * a_sal / NULLIF(a_rev, 0), 'S99,999,990')), 12 FROM x
UNION ALL SELECT '   -> net profit would be',
       'RM ' || TRIM(TO_CHAR(f_net + f_sal - f_rev * a_sal / NULLIF(a_rev, 0), 'S99,999,990')), ' ', ' ',
       TRIM(TO_CHAR((f_net + f_sal - f_rev * a_sal / NULLIF(a_rev, 0)) / NULLIF(f_rev, 0) * 100, 'S990.0')) || '% earning', 13 FROM x
-- what-if 2: same sales, but stock bought at the AVERAGE branch's % of sales
-- (the lever for a branch whose supplier is dear - Ipoh)
UNION ALL SELECT 'Purchasing at the average % of sales',
       'RM ' || TRIM(TO_CHAR(f_rev * a_cogs / NULLIF(a_rev, 0), '99,999,990')), ' ', ' ',
       'saves ' || TRIM(TO_CHAR(f_cogs - f_rev * a_cogs / NULLIF(a_rev, 0), 'S99,999,990')), 14 FROM x
UNION ALL SELECT '   -> net profit would be',
       'RM ' || TRIM(TO_CHAR(f_net + f_cogs - f_rev * a_cogs / NULLIF(a_rev, 0), 'S99,999,990')), ' ', ' ',
       TRIM(TO_CHAR((f_net + f_cogs - f_rev * a_cogs / NULLIF(a_rev, 0)) / NULLIF(f_rev, 0) * 100, 'S990.0')) || '% earning', 15 FROM x
-- what-if 3: heads the branch would need at the average sales per head
UNION ALL SELECT 'Heads at average sales per head',
       TRIM(TO_CHAR(f_rev / NULLIF(a_rev / NULLIF(a_heads, 0), 0), '990.0')) || ' heads', ' ', ' ',
       'has ' || TRIM(TO_CHAR(f_heads, '990')), 16 FROM x
-- what-if 4: sales needed to break even on the current payroll + expenses
-- (purchase cost scales with sales at the branch's own ratio)
UNION ALL SELECT 'Break-even sales at current costs',
       'RM ' || TRIM(TO_CHAR((f_sal + f_exp) / NULLIF(1 - f_cogs / NULLIF(f_rev, 0), 0), '99,999,990')), ' ', ' ',
       TRIM(TO_CHAR(((f_sal + f_exp) / NULLIF(1 - f_cogs / NULLIF(f_rev, 0), 0) - f_rev)
                    / NULLIF(f_rev, 0) * 100, 'S990.0')) || '% vs actual', 17 FROM x
UNION ALL SELECT '-- verdict ----------------------', ' ', ' ', ' ', ' ', 18 FROM dual
UNION ALL SELECT 'WHY',
       CASE WHEN f_net >= 0 THEN 'in the black'
            WHEN (f_sal / NULLIF(f_rev, 0) - a_sal / NULLIF(a_rev, 0))
                 >= GREATEST(f_cogs / NULLIF(f_rev, 0) - a_cogs / NULLIF(a_rev, 0),
                             f_exp  / NULLIF(f_rev, 0) - a_exp  / NULLIF(a_rev, 0))
            THEN 'PAYROLL'
            WHEN (f_exp / NULLIF(f_rev, 0) - a_exp / NULLIF(a_rev, 0))
                 >= (f_cogs / NULLIF(f_rev, 0) - a_cogs / NULLIF(a_rev, 0))
            THEN 'PREMISES'
            ELSE 'PURCHASING' END,
       ' ', ' ',
       CASE WHEN f_net >= 0 THEN 'no gap to close'
            ELSE 'largest gap vs avg' END, 19 FROM x
)
ORDER  BY sort_key;

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
UNDEFINE focus_branch
UNDEFINE focus_id
UNDEFINE focus_city
UNDEFINE focus_br_state
UNDEFINE best_id
UNDEFINE best_city
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
