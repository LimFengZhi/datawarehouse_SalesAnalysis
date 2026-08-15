-- ===================================================================
-- 00_run_all_facts.sql
-- Runs every fact table initial load, in order.
--
-- Usage:
--   @c:\Users\laoli\Downloads\datawarehouseAnalysis\initialLoading\init_fact\00_run_all_facts.sql
--
-- PREREQUISITES - in this order:
--   1. 01_create_operational_db.sql + the 14 CSVs loaded (SQL*Loader)
--   2. create_dwh.sql               (dimension + fact tables exist)
--   3. initial_load_date_dim.sql    (date_dim: 1,462 rows)
--   4. init_dimension\00_run_all_dimensions.sql  (all 7 dimensions)
--   5. THIS FILE
--
-- The facts have foreign keys to BOTH the dimensions and the original
-- OLTP tables, so every one of the steps above must be complete.
--
-- Facts do not reference each other, so the order below is only
-- largest-first for readability.
--
-- SPEED: order_fact is 349,396 rows joined to 5 dimensions with no
-- indexes on the natural keys. Expect a few minutes on XE. If it drags,
-- create the helper indexes listed at the bottom of this file first.
-- ===================================================================

SET SERVEROUTPUT ON
SET DEFINE OFF

PROMPT ============================================
PROMPT  1/5  ORDER_FACT             (expect 349396)
PROMPT ============================================
@@01_init_order_fact.sql

PROMPT ============================================
PROMPT  2/5  RESERVATION_FACT       (expect 88790)
PROMPT ============================================
@@02_init_reservation_fact.sql

PROMPT ============================================
PROMPT  3/5  PURCHASE_FACT          (expect 10615)
PROMPT ============================================
@@03_init_purchase_fact.sql

PROMPT ============================================
PROMPT  4/5  SALARY_PAYMENT_FACT    (expect 3135)
PROMPT ============================================
@@04_init_salary_payment_fact.sql

PROMPT ============================================
PROMPT  5/5  BRANCH_EXPENSE_FACT    (expect 1440)
PROMPT ============================================
@@05_init_branch_expense_fact.sql


-- ===================================================================
-- FINAL SUMMARY
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  ALL FACTS - FACT vs SOURCE ROW COUNTS
PROMPT ============================================

SELECT 'order_fact'          AS fact_table,
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
-- fact_rows must equal source_rows on every line


-- ===================================================================
-- THE PAYOFF: branch profitability, the whole star schema at work
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  BRANCH PROFITABILITY  (2019-2022)
PROMPT ============================================

WITH rev AS (
    SELECT branch_key,
           SUM(order_gross_amt - order_discount_amt) AS product_rev
    FROM order_fact WHERE order_status = 'Completed'
    GROUP BY branch_key),
svc AS (
    SELECT branch_key,
           SUM(serv_price - serv_discount_amt) AS service_rev
    FROM reservation_fact WHERE res_status = 'Completed'
    GROUP BY branch_key),
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


-- ===================================================================
-- OPTIONAL: helper indexes, if the fact loads are slow
-- ===================================================================
-- The joins hit dimension NATURAL keys, which have no index (a foreign
-- key constraint does not create one in Oracle).
--
-- CREATE INDEX ix_customer_dim_nk ON customer_dim (cus_ID);
-- CREATE INDEX ix_staff_dim_nk    ON staff_dim (st_ID);
-- CREATE INDEX ix_product_dim_nk  ON product_dim (product_ID);
-- CREATE INDEX ix_branch_dim_nk   ON branch_dim (br_ID);
-- CREATE INDEX ix_service_dim_nk  ON service_dim (serv_ID);
-- CREATE INDEX ix_supplier_dim_nk ON supplier_dim (sup_ID);
-- CREATE INDEX ix_date_dim_date   ON date_dim (cal_date);
--
-- ===================================================================
-- RELOAD  (run this first if you need to start over)
-- ===================================================================
-- Facts have no children, so TRUNCATE works here - unlike the
-- dimensions, which the facts point at.
--
-- TRUNCATE TABLE order_fact;
-- TRUNCATE TABLE reservation_fact;
-- TRUNCATE TABLE purchase_fact;
-- TRUNCATE TABLE salary_payment_fact;
-- TRUNCATE TABLE branch_expense_fact;
--
-- No sequences to reset: fact primary keys come from the source system.
-- ===================================================================
