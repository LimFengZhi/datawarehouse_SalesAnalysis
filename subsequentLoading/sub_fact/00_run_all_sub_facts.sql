-- ===================================================================
-- 00_run_all_sub_facts.sql
-- Runs the incremental load for all five fact tables.
--
-- Usage:
--   @c:\Users\laoli\Downloads\datawarehouseAnalysis\subsequentLoading\sub_fact\00_run_all_sub_facts.sql
--
-- ===================================================================
-- TWO STEPS PER FACT - and the second one is the point
-- ===================================================================
--   STEP 1  INSERT rows that are not in the fact yet, matched on the
--           degenerate primary key (order_det_ID, res_det_ID, ...)
--   STEP 2  UPDATE rows that ARE in the fact but whose values moved
--
-- A dimension load only ever needs step 1 plus SCD2 versioning. A fact
-- load needs step 2 because some fact attributes are not frozen at the
-- moment of the event:
--
--   order_status   Processing -> Completed / Cancelled
--   res_status     Confirmed  -> Completed / Cancelled / No-Show
--   money          a corrected quantity, an amended payslip, an
--                  estimated utility bill replaced by a real reading
--
-- Insert-only would freeze every booking at 'Confirmed' and report a
-- no-show rate of zero forever.
--
-- ===================================================================
-- WHERE THE SURROGATE KEYS ARE RESOLVED
-- ===================================================================
-- The *_fact_staging_v views do OLTP CLEANSING ONLY. They expose the
-- NATURAL keys (cus_ID, br_ID, st_ID, product_ID, serv_ID, ...), the
-- raw source date, the cleansed measures and a set of data-quality
-- flags. They never touch a dimension.
--
-- The date_dim / product_dim / customer_dim / staff_dim / branch_dim
-- joins are written out inside each PROCEDURE - both the initial load
-- and the incremental one. Three reasons:
--   1. a view that depends only on OLTP tables compiles and can be
--      inspected before any dimension exists
--   2. is_current_flag = 'Y' is a LOAD-TIME decision, not a cleansing
--      rule, so it belongs where the loading happens
--   3. the raw date stays available, which is what the window below
--      filters on - date_key is a sequence number and cannot be
--      range-filtered
--
-- ===================================================================
-- THE WINDOW  -  p_load_date
-- ===================================================================
-- Every procedure takes p_load_date IN DATE DEFAULT SYSDATE and
-- filters the view's raw date column (order_date, res_date,
-- purchase_date, payment_date) as >= TRUNC(p_load_date) - 1, so a bare
-- call handles yesterday and today.
--
-- To BACKFILL a historical range, pass the day AFTER the earliest date
-- you want. The scripts below are set to load all of data2:
--
--     EXEC load_order_fact_incremental(DATE '2023-01-02');
--         -> order_date >= 2023-01-01, i.e. everything from 2023 on
--
-- Fixed lookback is the course pattern, and it has a known weakness:
-- if the job does not run for three days, p_load_date - 1 never reaches
-- back far enough and those days are silently missed. Widen the
-- argument after any gap.
--
-- ===================================================================
-- PREREQUISITES
-- ===================================================================
--   1. data2 CSVs loaded    load_all.bat dwh <pw> XE "...\data2"
--   2. date_dim reaches 2024
--        EXEC load_date_dim_incremental(2024);
--   3. all 7 dimensions carry the new branch / staff / products /
--      services / customers
--        @subsequentLoading\sub_dimension\00_run_all_sub_dimensions.sql
--   4. optionally the 2023 price rise + its SCD2 versions
--        @data2\99_price_increase_2023.sql
--        EXEC maintain_product_dim_scd2(DATE '2023-01-01');
--
-- Miss step 2 or 3 and rows silently vanish: every staging view uses
-- INNER JOINs, so an unresolved key drops the row. Each procedure
-- counts those and warns, and SUMMARY 2 below shows which dimension.
--
-- SPEED: order_fact is the big one - 285,944 new lines joined to five
-- dimensions with no index on the natural keys. Expect a few minutes
-- on XE. Helper CREATE INDEX statements are at the bottom of
-- initialLoading\init_fact\00_run_all_facts.sql if it drags.
-- ===================================================================

SET SERVEROUTPUT ON
SET DEFINE OFF

PROMPT ============================================
PROMPT  1/5  ORDER_FACT
PROMPT ============================================
@@01_sub_order_fact.sql

PROMPT ============================================
PROMPT  2/5  RESERVATION_FACT
PROMPT ============================================
@@02_sub_reservation_fact.sql

PROMPT ============================================
PROMPT  3/5  PURCHASE_FACT
PROMPT ============================================
@@03_sub_purchase_fact.sql

PROMPT ============================================
PROMPT  4/5  SALARY_PAYMENT_FACT
PROMPT ============================================
@@04_sub_salary_payment_fact.sql

PROMPT ============================================
PROMPT  5/5  BRANCH_EXPENSE_FACT
PROMPT ============================================
@@05_sub_branch_expense_fact.sql


-- ===================================================================
-- SUMMARY 1: FACT vs SOURCE - must match on every line
-- After loading data2 the totals are data\ + data2\
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  FACT vs SOURCE ROW COUNTS
PROMPT ============================================

SELECT 'order_fact' AS fact_table,
       (SELECT COUNT(*) FROM order_fact)          AS fact_rows,
       (SELECT COUNT(*) FROM order_detail)        AS source_rows FROM dual
UNION ALL
SELECT 'reservation_fact',
       (SELECT COUNT(*) FROM reservation_fact),
       (SELECT COUNT(*) FROM reservation_detail)  FROM dual
UNION ALL
SELECT 'purchase_fact',
       (SELECT COUNT(*) FROM purchase_fact),
       (SELECT COUNT(*) FROM purchase)            FROM dual
UNION ALL
SELECT 'salary_payment_fact',
       (SELECT COUNT(*) FROM salary_payment_fact),
       (SELECT COUNT(*) FROM salary_payment)      FROM dual
UNION ALL
SELECT 'branch_expense_fact',
       (SELECT COUNT(*) FROM branch_expense_fact),
       (SELECT COUNT(*) FROM branch_expense)      FROM dual;


-- ===================================================================
-- SUMMARY 2: WHICH DIMENSION IS DROPPING ROWS - all must be 0
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  UNRESOLVED DIMENSION KEYS  (all must be 0)
PROMPT ============================================

SELECT 'order -> date_dim' AS lookup, COUNT(*) AS unresolved
FROM order_detail od JOIN orders o ON o.order_ID = od.order_ID
WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                  WHERE d.cal_date = TRUNC(o.order_date))
UNION ALL
SELECT 'order -> customer_dim', COUNT(*) FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM customer_dim d
                  WHERE d.cus_ID = o.cus_ID AND d.is_current_flag = 'Y')
UNION ALL
SELECT 'order -> staff_dim', COUNT(*) FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM staff_dim d
                  WHERE d.st_ID = o.st_ID AND d.is_current_flag = 'Y')
UNION ALL
SELECT 'order -> branch_dim', COUNT(*) FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM branch_dim d
                  WHERE d.br_ID = o.br_ID AND d.is_current_flag = 'Y')
UNION ALL
SELECT 'order -> product_dim', COUNT(*) FROM order_detail od
WHERE NOT EXISTS (SELECT 1 FROM product_dim d
                  WHERE d.product_ID = od.product_ID
                    AND d.is_current_flag = 'Y')
UNION ALL
SELECT 'reservation -> service_dim', COUNT(*) FROM reservation_detail rd
WHERE NOT EXISTS (SELECT 1 FROM service_dim d
                  WHERE d.serv_ID = rd.serv_ID
                    AND d.is_current_flag = 'Y')
UNION ALL
SELECT 'purchase -> supplier_dim', COUNT(*) FROM purchase p
WHERE NOT EXISTS (SELECT 1 FROM supplier_dim d
                  WHERE d.sup_ID = p.sup_ID AND d.is_current_flag = 'Y');


-- ===================================================================
-- SUMMARY 3: SIX YEARS OF REVENUE
-- 2019-2022 from data\, 2023-2024 from data2\
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  REVENUE BY YEAR  2019-2024
PROMPT ============================================

SELECT yr,
       ROUND(SUM(product_rev), 2) AS product_rev,
       ROUND(SUM(service_rev), 2) AS service_rev,
       ROUND(SUM(product_rev) + SUM(service_rev), 2) AS total_rev
FROM (
    SELECT d.cal_year AS yr,
           SUM(f.order_gross_amt - f.order_discount_amt) AS product_rev,
           0 AS service_rev
    FROM order_fact f JOIN date_dim d ON d.date_key = f.date_key
    WHERE f.order_status = 'Completed'
    GROUP BY d.cal_year
    UNION ALL
    SELECT d.cal_year, 0,
           SUM(f.serv_price - f.serv_discount_amt)
    FROM reservation_fact f JOIN date_dim d ON d.date_key = f.date_key
    WHERE f.res_status = 'Completed'
    GROUP BY d.cal_year
)
GROUP BY yr
ORDER BY yr;
-- 2020-2021 should dip (lockdowns), 2022 recover, 2023-24 grow on


-- ===================================================================
-- SUMMARY 4: BRANCH PROFITABILITY, ALL SIX BRANCHES
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  BRANCH PROFITABILITY
PROMPT ============================================

WITH rev AS (
    SELECT branch_key, SUM(order_gross_amt - order_discount_amt) AS product_rev
    FROM order_fact WHERE order_status = 'Completed' GROUP BY branch_key),
svc AS (
    SELECT branch_key, SUM(serv_price - serv_discount_amt) AS service_rev
    FROM reservation_fact WHERE res_status = 'Completed' GROUP BY branch_key),
cogs AS (
    SELECT branch_key, SUM(purchase_total_cost) AS cost_of_goods
    FROM purchase_fact GROUP BY branch_key),
pay AS (
    SELECT branch_key, SUM(net_amount) AS payroll
    FROM salary_payment_fact GROUP BY branch_key),
exp AS (
    SELECT branch_key, SUM(payment_amount) AS overheads
    FROM branch_expense_fact GROUP BY branch_key)
SELECT b.br_city,
       ROUND(NVL(rev.product_rev,0), 2)    AS product_rev,
       ROUND(NVL(svc.service_rev,0), 2)    AS service_rev,
       ROUND(NVL(cogs.cost_of_goods,0), 2) AS cogs,
       ROUND(NVL(pay.payroll,0), 2)        AS payroll,
       ROUND(NVL(exp.overheads,0), 2)      AS overheads,
       ROUND(  NVL(rev.product_rev,0) + NVL(svc.service_rev,0)
             - NVL(cogs.cost_of_goods,0) - NVL(pay.payroll,0)
             - NVL(exp.overheads,0), 2)    AS profit
FROM branch_dim b
LEFT JOIN rev  ON rev.branch_key  = b.branch_key
LEFT JOIN svc  ON svc.branch_key  = b.branch_key
LEFT JOIN cogs ON cogs.branch_key = b.branch_key
LEFT JOIN pay  ON pay.branch_key  = b.branch_key
LEFT JOIN exp  ON exp.branch_key  = b.branch_key
WHERE b.is_current_flag = 'Y'
ORDER BY profit DESC;
-- Ipoh should sit last - it only traded for 22 of the 72 months


-- ===================================================================
-- THE IDEMPOTENCY TEST
-- ===================================================================
-- Run this whole file a SECOND time. Every procedure must report
-- 0 inserted and 0 updated. If "updated" stays non-zero on repeat
-- runs, a measure is being recomputed differently on each pass -
-- usually a rounding difference between the staging view and what was
-- stored.
-- ===================================================================
