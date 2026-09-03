-- ===================================================================
-- exec_sub_proc25.sql
-- RUNS the subsequent load for DATA25 (2025). Creates nothing.
--
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading\exec_sub_proc25.sql
--
-- ===================================================================
-- HOW THIS DIFFERS FROM exec_sub_proc24.sql
-- ===================================================================
--   exec_sub_proc24.sql   the DATA24 run  (2024)
--       calendar + fact windows end DATE '2024-12-31'
--       maintain_product_dim_scd2(DATE '2024-01-01')
--
--   exec_sub_proc25.sql   THIS FILE, the DATA25 run  (2025)
--       calendar + fact windows end DATE '2025-12-31'
--       maintain_product_dim_scd2(DATE '2025-01-01')
--       maintain_service_dim_scd2(DATE '2025-01-01')   <- new this run
--
-- The calendar and the five facts take only p_end_date (an UPPER
-- bound, DEFAULT SYSDATE); each fact finds its own lower bound from
-- what it already holds. The SCD2 effective dates are business dates:
-- WHEN a price changed is nowhere in the data, so it stays a
-- parameter. Nothing is redefined here, so the two files can live
-- side by side and you re-run whichever year you are loading.
--
-- ===================================================================
-- BEFORE YOU RUN THIS
-- ===================================================================
--   1. the 16 numbered scripts have been run at least once, so the
--      procedures exist  (STEP 0 below checks)
--   2. the data25 CSVs are loaded into the OLTP
--        cd operational_DB\sqlloader_control_files
--        load_all.bat dwh <password> XE "...\sales_data5\data25"
--   3. the 2025 price changes are applied to the OLTP
--        @sales_data5\data25\99_price_change_2025.sql
--
--   Step 3 must come BEFORE this file. The maintain procedures compare
--   the dimension against the OLTP, so the OLTP has to carry the new
--   prices already or there is nothing for them to detect.
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

-- Anything listed here is broken. INVALID is what produces PLS-00905.
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

-- This must return 16. Fewer means a numbered script was never run.
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


-- ###################################################################
-- STEP 1 of 3 - NEW DIMENSION RECORDS
-- 6,824 customers, 6 staff, 1 supplier, 8 products (the men's line) + extend the calendar to 2025
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  STEP 1 of 3 - NEW DIMENSION RECORDS
PROMPT ##############################################

-- Extends the calendar from its current end (2024-12-31 after the
-- data24 run) through 2025-12-31. Must run before the facts, or their
-- date lookups fail SILENTLY - the staging views use INNER JOIN, so an
-- unresolved key drops the row with no error at all.
EXEC load_date_dim_incremental(DATE '2025-12-31');

-- The new 2025 days arrive with holiday_ind = 'N'. AFTER this file
-- finishes, regenerate and apply the holiday file:
--     cd ETL_Process\initial_loading\init_data_dim
--     python gen_holidays.py 2019 2025 > holiday_update.sql
--     @holiday_update.sql

-- expect 1 new (HIM Care Labs)
EXEC load_supplier_dim_incremental;
-- expect 8 new (HIM Essentials men's line 49-54 + two face masks 55-56, launched 2025-01-01)
EXEC load_product_dim_incremental;
-- expect 6,824 new
EXEC load_customer_dim_incremental;

-- Nothing new in these two for 2025 - no branch or service was added.
-- They run anyway and should report 0, which is itself a useful
-- confirmation.
EXEC load_branch_dim_incremental;
EXEC load_service_dim_incremental;
-- expect 6 new (2025 growth hires)
EXEC load_staff_dim_incremental;


-- ###################################################################
-- STEP 2 of 3 - CHANGED DIMENSION RECORDS
-- the 2025 price changes become dimension history
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  STEP 2 of 3 - CHANGED DIMENSION RECORDS
PROMPT ##############################################

-- Both dated 2025-01-01, because that is when the prices in
-- data25\99_price_change_2025.sql actually changed. The expired
-- versions end 2024-12-31 and the new ones start 2025-01-01.
--
-- PRODUCTS 4 AND 16 GAIN A THIRD VERSION HERE. They already rose in
-- 2024, so after this run they read:
--     42 / 120   ending 2023-12-31
--     48 / 135   2024-01-01 to 2024-12-31
--     54 / 149   from 2025-01-01
-- expect 8 expired, 8 new versions
EXEC maintain_product_dim_scd2(DATE '2025-01-01');

-- FIRST TIME SERVICES HAVE EVER CHANGED - service_dim gets its first
-- version history.
-- expect 6 expired, 6 new versions
EXEC maintain_service_dim_scd2(DATE '2025-01-01');

-- Nothing changed in these for 2025. They should all report 0.
EXEC maintain_staff_dim_scd2;
EXEC maintain_customer_dim_scd2;


-- ###################################################################
-- STEP 3 of 3 - FACTS
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  STEP 3 of 3 - FACTS
PROMPT ##############################################

-- No start date to pass: each procedure opens its window at the
-- newest date already in ITS OWN fact (2024-12-31 after the data24
-- run). That last day is re-read on purpose - late rows for it are
-- caught, and the NOT EXISTS anti-join skips everything already
-- loaded, so nothing is duplicated.
--
-- p_end_date = 2025-12-31 caps the window at the data25 year. The
-- 2025 lines resolve to the 2025 price versions by date; the 2024
-- rows already in the fact keep the versions they were loaded with.
EXEC load_order_fact_incremental(DATE '2025-12-31');
EXEC load_res_fact_incremental(DATE '2025-12-31');
EXEC load_purchase_fact_incremental(DATE '2025-12-31');
EXEC load_salary_fact_incremental(DATE '2025-12-31');
EXEC load_br_utils_fact_incremental(DATE '2025-12-31');


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
       (SELECT COUNT(*) FROM supplier), 8                          FROM dual
UNION ALL SELECT 'service_dim',
       (SELECT COUNT(*) FROM service_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM service), 18                          FROM dual
UNION ALL SELECT 'product_dim',
       (SELECT COUNT(*) FROM product_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM product), 56                          FROM dual
UNION ALL SELECT 'staff_dim',
       (SELECT COUNT(*) FROM staff_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM staff), 319                           FROM dual
UNION ALL SELECT 'customer_dim',
       (SELECT COUNT(*) FROM customer_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM customer), 39175                      FROM dual
ORDER BY 1;
-- current_rows must equal source_rows on every line.

SELECT COUNT(*) AS date_dim_rows, 2558 AS expected FROM date_dim;
-- 2,557 days for 2019-2025 + the Unknown member

PROMPT
PROMPT ##############################################
PROMPT #  VERSION HISTORY - totals include expired rows
PROMPT ##############################################

SELECT 'product_dim' AS dimension, COUNT(*) AS total_rows,
       SUM(CASE WHEN is_current_flag='Y' THEN 1 ELSE 0 END) AS current_rows,
       72 AS expected_total FROM product_dim
UNION ALL
SELECT 'service_dim', COUNT(*),
       SUM(CASE WHEN is_current_flag='Y' THEN 1 ELSE 0 END), 24 FROM service_dim;
-- product_dim 72 = 56 current + 8 expired in 2024 + 8 expired in 2025
-- service_dim 24 = 18 current + 6 expired in 2025


PROMPT
PROMPT ##############################################
PROMPT #  FACT ROW COUNTS
PROMPT ##############################################

-- order_fact is one row per (order, product) and reservation_fact one
-- row per (reservation, service, therapist), so the source side counts
-- the DISTINCT groups, not the OLTP detail lines (order_detail has
-- 873,490 lines here; 17,555 of them repeat a product inside an order).
SELECT 'order_fact' AS fact_table,
       (SELECT COUNT(*) FROM order_fact)   AS fact_rows,
       (SELECT COUNT(*) FROM (SELECT DISTINCT order_ID, product_ID FROM order_detail)) AS source_rows,
       857664 AS expected FROM dual
UNION ALL SELECT 'reservation_fact',
       (SELECT COUNT(*) FROM reservation_fact),
       (SELECT COUNT(*) FROM (SELECT DISTINCT res_ID, serv_ID, st_ID FROM reservation_detail)), 166658 FROM dual
UNION ALL SELECT 'purchase_fact',
       (SELECT COUNT(*) FROM purchase_fact),
       (SELECT COUNT(*) FROM purchase), 53933            FROM dual
UNION ALL SELECT 'salary_payment_fact',
       (SELECT COUNT(*) FROM salary_payment_fact),
       (SELECT COUNT(*) FROM salary_payment), 18934      FROM dual
UNION ALL SELECT 'branch_utils_fact',
       (SELECT COUNT(*) FROM branch_utils_fact),
       (SELECT COUNT(*) FROM branch_utils), 7128         FROM dual
ORDER BY 1;


PROMPT
PROMPT ##############################################
PROMPT #  SEVEN YEARS OF REVENUE  2019-2025
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
-- SEVEN rows. Fewer means date_dim did not reach far enough.
-- 2019 baseline, 2020-2021 dip (lockdowns), 2022 jumps (online), 2025 jumps (men's line).
-- revenue = total - tax (qty * price - discount, tax excluded); the
-- facts store no unit price, the dimension version does.


PROMPT
PROMPT ##############################################
PROMPT #  THE SCD2 PAYOFF - one product, THREE prices
PROMPT ##############################################

SELECT p.product_unit_price, p.is_current_flag,
       p.effective_start_date, p.effective_end_date,
       MIN(d.cal_date) AS first_sold, MAX(d.cal_date) AS last_sold,
       COUNT(*)        AS order_lines
FROM   order_fact  f
JOIN   product_dim p ON p.product_key = f.product_key
JOIN   date_dim    d ON d.date_key    = f.date_key
WHERE  p.product_ID = 16          -- Peptide Firming Serum
GROUP  BY p.product_unit_price, p.is_current_flag,
          p.effective_start_date, p.effective_end_date
ORDER  BY first_sold;
-- Expect THREE rows:
--   120.00  'N'  first sold 2019-01-xx, last 2023-12-xx
--   135.00  'N'  first sold 2024-01-xx, last 2024-12-xx
--   149.00  'Y'  first sold 2025-01-xx
-- Each price sits against exactly the order lines that paid it. With
-- Type 1 there would be one row at 149.00 and six years of history
-- would silently revalue.

PROMPT
PROMPT ##############################################
PROMPT #  SERVICE_DIM's FIRST version history
PROMPT ##############################################

SELECT serv_ID, serv_name, serv_price, is_current_flag,
       effective_start_date, effective_end_date
FROM   service_dim
WHERE  serv_ID IN (5, 6, 7, 10, 12, 17)
ORDER  BY serv_ID, service_key;
-- 12 rows: 6 flagged 'N' ending 2024-12-31, 6 flagged 'Y' from
-- 2025-01-01


-- ===================================================================
-- THE IDEMPOTENCY TEST
-- ===================================================================
-- Run this file a SECOND time. Every procedure must report 0 inserted,
-- 0 expired and 0 updated, and the counts above must not move.
--
-- Deeper integrity checks live in validate_subsequent_loading.sql.
-- ===================================================================
