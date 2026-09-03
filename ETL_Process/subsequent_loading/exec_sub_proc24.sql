-- ===================================================================
-- exec_sub_proc24.sql
-- RUNS the whole subsequent load for DATA24 (2024). Creates nothing.
--
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading\exec_sub_proc24.sql
--
-- ===================================================================
-- BEFORE YOU RUN THIS
-- ===================================================================
-- Open and run the 16 numbered scripts first, in any order. Each one
-- only does CREATE OR REPLACE PROCEDURE plus its own verification
-- queries - none of them execute anything.
--
--   sub_dimension\   01..07   (7 procedures)
--   maintain_SCD2\   01..04   (4 procedures - product, service,
--                             staff, customer; branch and supplier
--                             are NOT SCD2 any more)
--   sub_fact\        01..05   (5 procedures)
--
-- Then run this file. STEP 0 below checks all 16 exist and are VALID
-- before it calls a single one, so a missed script is caught straight
-- away instead of failing half-way through.
--
-- ===================================================================
-- WHY THE CALLS LIVE HERE
-- ===================================================================
-- Every EXEC, and every argument, sits in this one file. Two kinds
-- of date are passed, and they mean different things:
--
--   EXEC load_date_dim_incremental(DATE '2024-12-31');   <- calendar end
--   EXEC load_order_fact_incremental(DATE '2024-12-31'); <- window end
--   EXEC maintain_product_dim_scd2(DATE '2024-01-01');   <- price-rise date
--
-- The calendar and the five facts take p_end_date (DEFAULT SYSDATE) -
-- only an UPPER bound. Each fact finds its own lower bound by reading
-- the newest date already loaded into itself, so there is no start
-- date to pass anywhere. The SCD2 effective date is different: WHEN a
-- price changed is a business fact that is nowhere in the data (the
-- OLTP keeps no price history), so it cannot be detected - only told.
--
-- ===================================================================
-- THE THREE LAYERS, AND WHY THIS ORDER
-- ===================================================================
--   sub_dimension  a natural key that does not exist yet -> insert it
--   maintain_SCD2  a natural key that exists and CHANGED -> expire the
--                  old row, insert a new version
--   sub_fact       a fact row that is new -> insert; one already there
--                  whose status or money moved -> update it
--
-- The first two are deliberately orthogonal: sub_dimension never
-- updates, maintain_SCD2 never inserts a brand-new record. Run them
-- the other way round and a new product would be versioned before it
-- exists.
--
-- Facts come last because they point at the dimensions. date_dim must
-- reach 2024 BEFORE they run, or every 2024 transaction fails its
-- date lookup - and that failure is SILENT. The staging views use
-- INNER JOIN, so an unresolved key drops the row with no error at all.
-- Skip the date step and 161,093 order rows vanish with nothing to
-- show for it.
--
-- ===================================================================
-- PREREQUISITES
-- ===================================================================
--   1. the warehouse is already built from sales_data5\data19_23\
--      (see DWH_Setup.md Part A)
--   2. the data24 CSVs are loaded into the OLTP (4 new branches + teams)
--        cd operational_DB\sqlloader_control_files
--        load_all.bat dwh <password> XE "...\sales_data5\data24"
--   3. the 2024 price rise is applied to the OLTP
--        @sales_data5\data24\99_price_increase_2024.sql
--
--   Step 3 must come BEFORE this file. maintain_SCD2 compares the
--   dimension against the OLTP, so the OLTP has to carry the new
--   prices already or there is nothing for it to detect.
--
-- IDEMPOTENT: run it twice and the second pass reports 0 inserted,
-- 0 expired, 0 updated everywhere.
-- ===================================================================

SET SERVEROUTPUT ON
SET DEFINE OFF


-- ###################################################################
-- STEP 0 - ARE ALL 16 PROCEDURES THERE AND VALID?
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  STEP 0 - checking the 16 procedures
PROMPT ##############################################

-- Anything listed here is missing or broken. INVALID is what produces
-- PLS-00905 when you try to call it.
SELECT object_name, status
FROM   user_objects
WHERE  object_type = 'PROCEDURE'
AND    object_name IN (
    'LOAD_DATE_DIM_INCREMENTAL','LOAD_SUPPLIER_DIM_INCREMENTAL',
    'LOAD_PRODUCT_DIM_INCREMENTAL','LOAD_BRANCH_DIM_INCREMENTAL',
    'LOAD_SERVICE_DIM_INCREMENTAL',
    'LOAD_STAFF_DIM_INCREMENTAL','LOAD_CUSTOMER_DIM_INCREMENTAL',
    'MAINTAIN_PRODUCT_DIM_SCD2','MAINTAIN_SERVICE_DIM_SCD2',
    'MAINTAIN_STAFF_DIM_SCD2','MAINTAIN_CUSTOMER_DIM_SCD2',
    'LOAD_ORDER_FACT_INCREMENTAL','LOAD_RES_FACT_INCREMENTAL',
    'LOAD_PURCHASE_FACT_INCREMENTAL','LOAD_SALARY_FACT_INCREMENTAL',
    'LOAD_BR_UTILS_FACT_INCREMENTAL')
AND    status <> 'VALID'
ORDER BY object_name;
-- NO ROWS = every procedure that exists is valid.

-- This one must return 16. Fewer means a numbered script was not run.
SELECT COUNT(*) AS procedures_found, 16 AS expected
FROM   user_objects
WHERE  object_type = 'PROCEDURE'
AND    object_name IN (
    'LOAD_DATE_DIM_INCREMENTAL','LOAD_SUPPLIER_DIM_INCREMENTAL',
    'LOAD_PRODUCT_DIM_INCREMENTAL','LOAD_BRANCH_DIM_INCREMENTAL',
    'LOAD_SERVICE_DIM_INCREMENTAL',
    'LOAD_STAFF_DIM_INCREMENTAL','LOAD_CUSTOMER_DIM_INCREMENTAL',
    'MAINTAIN_PRODUCT_DIM_SCD2','MAINTAIN_SERVICE_DIM_SCD2',
    'MAINTAIN_STAFF_DIM_SCD2','MAINTAIN_CUSTOMER_DIM_SCD2',
    'LOAD_ORDER_FACT_INCREMENTAL','LOAD_RES_FACT_INCREMENTAL',
    'LOAD_PURCHASE_FACT_INCREMENTAL','LOAD_SALARY_FACT_INCREMENTAL',
    'LOAD_BR_UTILS_FACT_INCREMENTAL');

-- If something is INVALID, this says exactly why - PLS-00905 hides it:
--   SELECT line, text FROM user_errors
--   WHERE name = '<PROCEDURE_NAME>' ORDER BY sequence;


-- ###################################################################
-- STEP 1 of 3 - NEW DIMENSION RECORDS
-- new branch, staff, products, services, customers
-- + extend the calendar
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  STEP 1 of 3 - NEW DIMENSION RECORDS
PROMPT ##############################################

-- Extends the calendar from its current end (2023-12-31) through the
-- date passed. Bare (DEFAULT SYSDATE) would also work today, but the
-- explicit year-end keeps this file reproducible. Must run before the
-- facts, or their date lookups fail silently.
EXEC load_date_dim_incremental(DATE '2024-12-31');

-- The new 2024 days arrive with holiday_ind = 'N'. AFTER this
-- file finishes, regenerate and apply the holiday file:
--     cd ETL_Process\initial_loading\init_data_dim
--     python gen_holidays.py 2019 2024 > holiday_update.sql
--     @holiday_update.sql

EXEC load_supplier_dim_incremental;
EXEC load_product_dim_incremental;
EXEC load_branch_dim_incremental;
EXEC load_service_dim_incremental;
EXEC load_staff_dim_incremental;
EXEC load_customer_dim_incremental;


-- ###################################################################
-- STEP 2 of 3 - CHANGED DIMENSION RECORDS
-- expire old versions, insert new ones
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  STEP 2 of 3 - CHANGED DIMENSION RECORDS
PROMPT ##############################################

-- p_effective_date is when the change ACTUALLY happened, not when you
-- are loading. Leave it off and the change is dated today.
--
-- PRODUCT IS DATED 2024-01-01 on purpose: that is when the eight
-- prices in data24\99_price_increase_2024.sql went up, so the expired
-- version ends 2023-12-31 and the new one starts 2024-01-01. The
-- 2019-2023 lines already in the fact carry the OLD price and stay on
-- the expired version by order date; the 2024 lines carry the new one.
-- Date it today instead and five years of order rows would be
-- attributed to the wrong price version.
EXEC maintain_product_dim_scd2(DATE '2024-01-01');

EXEC maintain_service_dim_scd2;
EXEC maintain_staff_dim_scd2;
EXEC maintain_customer_dim_scd2;


-- ###################################################################
-- STEP 3 of 3 - FACTS
-- new rows + refresh changed statuses
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  STEP 3 of 3 - FACTS
PROMPT ##############################################

-- No start date to pass: each procedure opens its window at the
-- newest date already in ITS OWN fact (2023-12-31 after the initial
-- load). That last day is re-read on purpose - late rows for it are
-- caught, and the NOT EXISTS anti-join skips everything already in.
--
-- The argument is only the UPPER bound (p_end_date, DEFAULT SYSDATE).
-- Capping it at 2024-12-31 makes this file load data24 ONLY, even if
-- the data25 CSVs are already sitting in the OLTP. For a normal daily
-- run, drop the argument:  EXEC load_order_fact_incremental;
EXEC load_order_fact_incremental(DATE '2024-12-31');
EXEC load_res_fact_incremental(DATE '2024-12-31');
EXEC load_purchase_fact_incremental(DATE '2024-12-31');
EXEC load_salary_fact_incremental(DATE '2024-12-31');
EXEC load_br_utils_fact_incremental(DATE '2024-12-31');


-- ###################################################################
-- FINAL CHECK
-- ###################################################################

PROMPT
PROMPT ##############################################
PROMPT #  DIMENSION ROW COUNTS
PROMPT ##############################################

SELECT 'branch_dim' AS dimension,
       (SELECT COUNT(*) FROM branch_dim) AS dim_rows,
       (SELECT COUNT(*) FROM branch)                               AS source_rows,
       17 AS expected FROM dual
UNION ALL SELECT 'supplier_dim',
       (SELECT COUNT(*) FROM supplier_dim),
       (SELECT COUNT(*) FROM supplier), 7                          FROM dual
UNION ALL SELECT 'service_dim',
       (SELECT COUNT(*) FROM service_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM service), 18                          FROM dual
UNION ALL SELECT 'product_dim',
       (SELECT COUNT(*) FROM product_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM product), 48                          FROM dual
UNION ALL SELECT 'staff_dim',
       (SELECT COUNT(*) FROM staff_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM staff), 313                           FROM dual
UNION ALL SELECT 'customer_dim',
       (SELECT COUNT(*) FROM customer_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM customer), 32496                      FROM dual
ORDER BY 1;
-- current_rows must equal source_rows on every line.
-- product_dim TOTAL will be 56, not 48 - the 8 extra are the expired
-- pre-2024 price versions, which is exactly what SCD2 is for.

SELECT COUNT(*) AS date_dim_rows FROM date_dim;
-- expect 2193 for 2019-2024 (2,192 days + the Unknown member)


PROMPT
PROMPT ##############################################
PROMPT #  FACT ROW COUNTS
PROMPT ##############################################

-- order_fact is one row per (order, product) and reservation_fact one
-- row per (reservation, service, therapist), so the source side counts
-- the DISTINCT groups, not the OLTP detail lines (order_detail has
-- 655,056 lines here; 13,210 of them repeat a product inside an order).
SELECT 'order_fact' AS fact_table,
       (SELECT COUNT(*) FROM order_fact)   AS fact_rows,
       (SELECT COUNT(*) FROM (SELECT DISTINCT order_ID, product_ID FROM order_detail)) AS source_rows,
       642619 AS expected FROM dual
UNION ALL SELECT 'reservation_fact',
       (SELECT COUNT(*) FROM reservation_fact),
       (SELECT COUNT(*) FROM (SELECT DISTINCT res_ID, serv_ID, st_ID FROM reservation_detail)), 129736 FROM dual
UNION ALL SELECT 'purchase_fact',
       (SELECT COUNT(*) FROM purchase_fact),
       (SELECT COUNT(*) FROM purchase), 42734            FROM dual
UNION ALL SELECT 'salary_payment_fact',
       (SELECT COUNT(*) FROM salary_payment_fact),
       (SELECT COUNT(*) FROM salary_payment), 15474      FROM dual
UNION ALL SELECT 'branch_utils_fact',
       (SELECT COUNT(*) FROM branch_utils_fact),
       (SELECT COUNT(*) FROM branch_utils), 5904         FROM dual
ORDER BY 1;


PROMPT
PROMPT ##############################################
PROMPT #  SIX YEARS OF REVENUE  2019-2024
PROMPT ##############################################

SELECT yr,
       ROUND(SUM(product_rev), 2) AS product_rev,
       ROUND(SUM(service_rev), 2) AS service_rev,
       ROUND(SUM(product_rev) + SUM(service_rev), 2) AS total_rev
FROM (
    SELECT d.cal_year AS yr,
           SUM(f.order_total_amt - f.order_tax_amt) AS product_rev,
           0 AS service_rev
    FROM order_fact f JOIN date_dim d ON d.date_key = f.date_key
    WHERE f.order_status = 'Completed'
    GROUP BY d.cal_year
    UNION ALL
    SELECT d.cal_year, 0,
           SUM(f.serv_total_amt - f.serv_tax_amt)
    FROM reservation_fact f JOIN date_dim d ON d.date_key = f.date_key
    WHERE f.res_status = 'Completed'
    GROUP BY d.cal_year
)
GROUP BY yr
ORDER BY yr;
-- 2019 baseline, 2020-2021 dip (lockdowns), 2022 jumps (online), 2023-24 grow on.
-- Six rows. Fewer means date_dim did not reach far enough.
-- revenue = total - tax (qty * price - discount, tax excluded); the
-- facts store no unit price, the dimension version does.


PROMPT
PROMPT ##############################################
PROMPT #  THE SCD2 PAYOFF - one product, two prices
PROMPT ##############################################

SELECT p.product_name, p.product_unit_price, p.is_current_flag,
       MIN(d.cal_date) AS first_sold, MAX(d.cal_date) AS last_sold,
       COUNT(*)        AS order_lines
FROM   order_fact  f
JOIN   product_dim p ON p.product_key = f.product_key
JOIN   date_dim    d ON d.date_key    = f.date_key
WHERE  p.product_ID = 16          -- Peptide Firming Serum, 120 -> 135
GROUP  BY p.product_name, p.product_unit_price, p.is_current_flag
ORDER  BY first_sold;
-- Expect two rows: the 120.00 version stopping at 2023-12-31 and the
-- 135.00 version starting 2024-01-01. That is the whole argument for
-- Type 2 - with Type 1 the price would have been overwritten and five
-- years of history would silently revalue.


-- ===================================================================
-- THE IDEMPOTENCY TEST
-- ===================================================================
-- Run this file a SECOND time. Every procedure must report 0 inserted,
-- 0 expired and 0 updated, and the counts above must not move.
--
-- Deeper integrity checks live in validate_subsequent_loading.sql.
-- ===================================================================
