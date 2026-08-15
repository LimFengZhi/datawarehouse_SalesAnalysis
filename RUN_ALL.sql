-- ===================================================================
-- RUN_ALL.sql          FULL WAREHOUSE REBUILD, ONE COMMAND
--
-- Usage:
--   sqlplus dwh/<password>@XE
--   @c:\Users\laoli\Downloads\datawarehouseAnalysis\RUN_ALL.sql
--
-- *******************************************************************
-- *  STEP 1 CLEARS ALL WAREHOUSE DATA before reloading. The OLTP    *
-- *  tables are never touched.                                      *
-- *******************************************************************
--
-- WHAT RUNS, IN ORDER
--   1. 00_clear_all.sql            empty every dim + fact, drop sequences
--   2. initial_load_date_dim.sql   date_dim, 1,462 rows
--   3. init_dimension\00_...       the 7 source-fed dimensions
--   4. init_fact\00_...            the 5 fact tables
--
-- PREREQUISITES - not done here, do them once by hand
--   a. operationalDB\01_create_operational_db.sql   (14 OLTP tables)
--   b. sqlloader_control_files\load_all.bat dwh <pw> XE   (the CSVs)
--   c. create_dwh.sql                        (13 warehouse tables)
--   d. holidays, if you want them:
--        cd initialLoading\init_data_dim
--        python gen_holidays.py 2019 2022 > holiday_update.sql
--
--   Step (c) drops and recreates every warehouse table, so run it only
--   when the DDL itself changed. For a normal data reload, RUN_ALL is
--   enough - 00_clear_all.sql empties the tables without dropping them.
--
-- @@ resolves each path relative to the folder holding this file, so
-- it works from any working directory.
--
-- TIMING: expect a few minutes. Nearly all of it is order_fact -
-- 349,396 rows joined to 5 dimensions whose natural keys have no
-- index. Helper CREATE INDEX statements are at the bottom of
-- initialLoading\init_fact\00_run_all_facts.sql if it drags.
-- ===================================================================

SET SERVEROUTPUT ON
SET DEFINE OFF

PROMPT
PROMPT ##############################################
PROMPT #  STEP 1 of 4 - CLEAR EVERYTHING
PROMPT ##############################################
@@00_clear_all.sql

PROMPT
PROMPT ##############################################
PROMPT #  STEP 2 of 4 - DATE DIMENSION   (expect 1462)
PROMPT ##############################################
@@initialLoading\init_data_dim\initial_load_date_dim.sql

-- ---- HOLIDAYS ----
-- date_dim loads with holiday_ind = 'N' everywhere. To flag them:
--     cd initialLoading\init_data_dim
--     python gen_holidays.py 2019 2022 > holiday_update.sql
-- then uncomment the next line:
--
-- @@initialLoading\init_data_dim\holiday_update.sql

PROMPT
PROMPT ##############################################
PROMPT #  STEP 3 of 4 - DIMENSIONS
PROMPT ##############################################
@@initialLoading\init_dimension\00_run_all_dimensions.sql

PROMPT
PROMPT ##############################################
PROMPT #  STEP 4 of 4 - FACTS
PROMPT ##############################################
@@initialLoading\init_fact\00_run_all_facts.sql


-- ===================================================================
-- FINAL CHECK - warehouse vs source, every line must match
-- ===================================================================
PROMPT
PROMPT ##############################################
PROMPT #  FINAL ROW COUNTS
PROMPT ##############################################

SELECT 'date_dim' AS tbl,
       (SELECT COUNT(*) FROM date_dim)              AS loaded,
       1462                                         AS expected FROM dual
UNION ALL SELECT 'branch_dim',
       (SELECT COUNT(*) FROM branch_dim),           (SELECT COUNT(*) FROM branch)        FROM dual
UNION ALL SELECT 'branch_utils_dim',
       (SELECT COUNT(*) FROM branch_utils_dim),     (SELECT COUNT(*) FROM branch_utils_category) FROM dual
UNION ALL SELECT 'supplier_dim',
       (SELECT COUNT(*) FROM supplier_dim),         (SELECT COUNT(*) FROM supplier)      FROM dual
UNION ALL SELECT 'service_dim',
       (SELECT COUNT(*) FROM service_dim),          (SELECT COUNT(*) FROM service)       FROM dual
UNION ALL SELECT 'product_dim',
       (SELECT COUNT(*) FROM product_dim),          (SELECT COUNT(*) FROM product)       FROM dual
UNION ALL SELECT 'staff_dim',
       (SELECT COUNT(*) FROM staff_dim),            (SELECT COUNT(*) FROM staff)         FROM dual
UNION ALL SELECT 'customer_dim',
       (SELECT COUNT(*) FROM customer_dim),         (SELECT COUNT(*) FROM customer)      FROM dual
UNION ALL SELECT 'order_fact',
       (SELECT COUNT(*) FROM order_fact),           (SELECT COUNT(*) FROM order_detail)  FROM dual
UNION ALL SELECT 'reservation_fact',
       (SELECT COUNT(*) FROM reservation_fact),     (SELECT COUNT(*) FROM reservation_detail) FROM dual
UNION ALL SELECT 'purchase_fact',
       (SELECT COUNT(*) FROM purchase_fact),        (SELECT COUNT(*) FROM purchase)      FROM dual
UNION ALL SELECT 'salary_payment_fact',
       (SELECT COUNT(*) FROM salary_payment_fact),  (SELECT COUNT(*) FROM salary_payment) FROM dual
UNION ALL SELECT 'branch_expense_fact',
       (SELECT COUNT(*) FROM branch_expense_fact),  (SELECT COUNT(*) FROM branch_expense) FROM dual
ORDER BY 1;


-- ===================================================================
-- THE PAYOFF: branch profitability across all five facts
-- ===================================================================
PROMPT
PROMPT ##############################################
PROMPT #  BRANCH PROFITABILITY  2019-2022
PROMPT ##############################################

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
-- Kuala Lumpur should lead on revenue (~RM 9.08m) and Melaka trail
-- (~RM 3.40m), matching data\README_DATASET.md.


-- ===================================================================
-- AFTERWARDS - the incremental layer, run when new data arrives
-- ===================================================================
-- These are NOT part of the rebuild. Run them later, in this order:
--
--   1. new records:
--      @subsequentLoading\sub_dimension\00_run_all_sub_dimensions.sql
--   2. changed records (SCD2):
--      @subsequentLoading\maintain_SCD2\00_run_all_maintain_scd2.sql
--
-- Both are idempotent - running either twice does nothing the second
-- time.
-- ===================================================================
