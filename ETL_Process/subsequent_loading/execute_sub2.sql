-- ===================================================================
-- execute_sub2.sql
-- RUNS the subsequent load for DATA24_25 (2024-2025). Creates nothing.
--
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading\execute_sub2.sql
--
-- ===================================================================
-- HOW THIS DIFFERS FROM execute_sub_procedure.sql
-- ===================================================================
--   execute_sub_procedure.sql   the DATA22_23 run  (2022-2023)
--       load_date_dim_incremental(2023)
--       maintain_product_dim_scd2(DATE '2023-01-01')
--       facts from DATE '2022-01-01'
--
--   execute_sub2.sql            THIS FILE, the DATA24_25 run  (2024-2025)
--       load_date_dim_incremental(2025)
--       maintain_product_dim_scd2(DATE '2025-01-01')
--       maintain_service_dim_scd2(DATE '2025-01-01')   <- new this run
--       facts from DATE '2024-01-01'
--
-- Same 19 procedures, different dates. Nothing is redefined here, so
-- the two files can live side by side and you re-run whichever year
-- you are loading.
--
-- ===================================================================
-- BEFORE YOU RUN THIS
-- ===================================================================
--   1. the 19 numbered scripts have been run at least once, so the
--      procedures exist  (STEP 0 below checks)
--   2. the data24_25 CSVs are loaded into the OLTP
--        cd operational_DB\sqlloader_control_files
--        load_all.bat dwh <password> XE "...\sales_data2\data24_25"
--   3. the 2025 price changes are applied to the OLTP
--        @sales_data2\data24_25\99_price_change_2025.sql
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
-- STEP 0 - ARE ALL 19 PROCEDURES THERE AND VALID?
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  STEP 0 - checking the 19 procedures
PROMPT ##############################################

-- Anything listed here is broken. INVALID is what produces PLS-00905.
SELECT object_name, status
FROM   user_objects
WHERE  object_type = 'PROCEDURE'
AND    object_name IN (
    'LOAD_DATE_DIM_INCREMENTAL','LOAD_SUPPLIER_DIM_INCREMENTAL',
    'LOAD_PRODUCT_DIM_INCREMENTAL','LOAD_BRANCH_DIM_INCREMENTAL',
    'LOAD_SERVICE_DIM_INCREMENTAL','LOAD_BR_UTILS_DIM_INCREMENTAL',
    'LOAD_STAFF_DIM_INCREMENTAL','LOAD_CUSTOMER_DIM_INCREMENTAL',
    'MAINTAIN_SUPPLIER_DIM_SCD2','MAINTAIN_PRODUCT_DIM_SCD2',
    'MAINTAIN_BRANCH_DIM_SCD2','MAINTAIN_SERVICE_DIM_SCD2',
    'MAINTAIN_STAFF_DIM_SCD2','MAINTAIN_CUSTOMER_DIM_SCD2',
    'LOAD_ORDER_FACT_INCREMENTAL','LOAD_RES_FACT_INCREMENTAL',
    'LOAD_PURCHASE_FACT_INCREMENTAL','LOAD_SALARY_FACT_INCREMENTAL',
    'LOAD_BR_EXP_FACT_INCREMENTAL')
AND    status <> 'VALID'
ORDER BY object_name;
-- NO ROWS = every procedure that exists is valid.

-- This must return 19. Fewer means a numbered script was never run.
SELECT COUNT(*) AS procedures_found, 19 AS expected
FROM   user_objects
WHERE  object_type = 'PROCEDURE'
AND    object_name IN (
    'LOAD_DATE_DIM_INCREMENTAL','LOAD_SUPPLIER_DIM_INCREMENTAL',
    'LOAD_PRODUCT_DIM_INCREMENTAL','LOAD_BRANCH_DIM_INCREMENTAL',
    'LOAD_SERVICE_DIM_INCREMENTAL','LOAD_BR_UTILS_DIM_INCREMENTAL',
    'LOAD_STAFF_DIM_INCREMENTAL','LOAD_CUSTOMER_DIM_INCREMENTAL',
    'MAINTAIN_SUPPLIER_DIM_SCD2','MAINTAIN_PRODUCT_DIM_SCD2',
    'MAINTAIN_BRANCH_DIM_SCD2','MAINTAIN_SERVICE_DIM_SCD2',
    'MAINTAIN_STAFF_DIM_SCD2','MAINTAIN_CUSTOMER_DIM_SCD2',
    'LOAD_ORDER_FACT_INCREMENTAL','LOAD_RES_FACT_INCREMENTAL',
    'LOAD_PURCHASE_FACT_INCREMENTAL','LOAD_SALARY_FACT_INCREMENTAL',
    'LOAD_BR_EXP_FACT_INCREMENTAL');


-- ###################################################################
-- STEP 1 of 3 - NEW DIMENSION RECORDS
-- 7,143 customers, 12 staff and 2 suppliers + extend the calendar to 2025
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  STEP 1 of 3 - NEW DIMENSION RECORDS
PROMPT ##############################################

-- 2025 this time. Must run before the facts, or their date lookups
-- fail SILENTLY - the staging views use INNER JOIN, so an unresolved
-- key drops the row with no error at all.
EXEC load_date_dim_incremental(2025);

-- The new 2025 days arrive with holiday_ind = 'N'. AFTER this file
-- finishes, regenerate and apply the holiday file:
--     cd ETL_Process\initial_loading\init_data_dim
--     python gen_holidays.py 2018 2025 > holiday_update.sql
--     @holiday_update.sql

-- expect 2 new
EXEC load_supplier_dim_incremental;
-- expect 7,143 new
EXEC load_customer_dim_incremental;

-- Nothing new in these four for 2024-25 - no branch, product, service
-- or utility category was added. They run anyway and should report 0,
-- which is itself a useful confirmation.
EXEC load_product_dim_incremental;
EXEC load_branch_dim_incremental;
EXEC load_service_dim_incremental;
EXEC load_br_utils_dim_incremental;
-- expect 12 new (2024-25 growth hires)
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
-- data24_25\99_price_change_2025.sql actually changed. The expired
-- versions end 2024-12-31 and the new ones start 2025-01-01.
--
-- PRODUCTS 4 AND 16 GAIN A THIRD VERSION HERE. They already rose in
-- 2023, so after this run they read:
--     42 / 120   ending 2022-12-31
--     48 / 135   2023-01-01 to 2024-12-31
--     54 / 149   from 2025-01-01
-- expect 8 expired, 8 new versions
EXEC maintain_product_dim_scd2(DATE '2025-01-01');

-- FIRST TIME SERVICES HAVE EVER CHANGED - service_dim gets its first
-- version history.
-- expect 6 expired, 6 new versions
EXEC maintain_service_dim_scd2(DATE '2025-01-01');

-- Nothing changed in these for 2024-25. They should all report 0.
EXEC maintain_supplier_dim_scd2;
EXEC maintain_branch_dim_scd2;
EXEC maintain_staff_dim_scd2;
EXEC maintain_customer_dim_scd2;


-- ###################################################################
-- STEP 3 of 3 - FACTS
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  STEP 3 of 3 - FACTS
PROMPT ##############################################

-- Just pass the first date you want - no need to add a day. The
-- procedure filters src_date >= p_load_date - 1, so DATE '2024-01-01'
-- opens the window at 2023-12-31. That one extra day, and every other
-- 2018-2023 row, is already in the fact and the NOT EXISTS anti-join
-- skips it - nothing is duplicated.
--
-- The window has no upper bound, so one call loads all of data24_25.
-- The 2024 lines resolve to the pre-2025 price versions by date, the
-- 2025 lines to the new ones.
EXEC load_order_fact_incremental(DATE '2024-01-01');
EXEC load_res_fact_incremental(DATE '2024-01-01');
EXEC load_purchase_fact_incremental(DATE '2024-01-01');
EXEC load_salary_fact_incremental(DATE '2024-01-01');
EXEC load_br_exp_fact_incremental(DATE '2024-01-01');


-- ###################################################################
-- FINAL CHECK
-- ###################################################################

PROMPT
PROMPT ##############################################
PROMPT #  DIMENSION ROW COUNTS
PROMPT ##############################################

SELECT 'branch_dim' AS dimension,
       (SELECT COUNT(*) FROM branch_dim WHERE is_current_flag='Y') AS current_rows,
       (SELECT COUNT(*) FROM branch)                               AS source_rows,
       13 AS expected FROM dual
UNION ALL SELECT 'branch_utils_dim',
       (SELECT COUNT(*) FROM branch_utils_dim),
       (SELECT COUNT(*) FROM branch_utils_category), 6             FROM dual
UNION ALL SELECT 'supplier_dim',
       (SELECT COUNT(*) FROM supplier_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM supplier), 8                          FROM dual
UNION ALL SELECT 'service_dim',
       (SELECT COUNT(*) FROM service_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM service), 18                          FROM dual
UNION ALL SELECT 'product_dim',
       (SELECT COUNT(*) FROM product_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM product), 48                          FROM dual
UNION ALL SELECT 'staff_dim',
       (SELECT COUNT(*) FROM staff_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM staff), 264                           FROM dual
UNION ALL SELECT 'customer_dim',
       (SELECT COUNT(*) FROM customer_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM customer), 28938                      FROM dual
ORDER BY 1;
-- current_rows must equal source_rows on every line.

SELECT COUNT(*) AS date_dim_rows, 2923 AS expected FROM date_dim;
-- 2,922 days for 2018-2025 + the Unknown member

PROMPT
PROMPT ##############################################
PROMPT #  VERSION HISTORY - totals include expired rows
PROMPT ##############################################

SELECT 'product_dim' AS dimension, COUNT(*) AS total_rows,
       SUM(CASE WHEN is_current_flag='Y' THEN 1 ELSE 0 END) AS current_rows,
       63 AS expected_total FROM product_dim
UNION ALL
SELECT 'service_dim', COUNT(*),
       SUM(CASE WHEN is_current_flag='Y' THEN 1 ELSE 0 END), 24 FROM service_dim;
-- product_dim 63 = 48 current + 7 expired in 2023 + 8 expired in 2025
-- service_dim 24 = 18 current + 6 expired in 2025


PROMPT
PROMPT ##############################################
PROMPT #  FACT ROW COUNTS
PROMPT ##############################################

SELECT 'order_fact' AS fact_table,
       (SELECT COUNT(*) FROM order_fact)   AS fact_rows,
       (SELECT COUNT(*) FROM order_detail) AS source_rows,
       670282 AS expected FROM dual
UNION ALL SELECT 'reservation_fact',
       (SELECT COUNT(*) FROM reservation_fact),
       (SELECT COUNT(*) FROM reservation_detail), 159977 FROM dual
UNION ALL SELECT 'purchase_fact',
       (SELECT COUNT(*) FROM purchase_fact),
       (SELECT COUNT(*) FROM purchase), 41411            FROM dual
UNION ALL SELECT 'salary_payment_fact',
       (SELECT COUNT(*) FROM salary_payment_fact),
       (SELECT COUNT(*) FROM salary_payment), 19517      FROM dual
UNION ALL SELECT 'branch_expense_fact',
       (SELECT COUNT(*) FROM branch_expense_fact),
       (SELECT COUNT(*) FROM branch_expense), 7074       FROM dual
ORDER BY 1;


PROMPT
PROMPT ##############################################
PROMPT #  EIGHT YEARS OF REVENUE  2018-2025
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
-- EIGHT rows. Fewer means date_dim did not reach far enough.
-- 2018-19 baseline, 2020-2021 dip (lockdowns), 2022 recovers, 2023-25 grow on.
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
--   120.00  'N'  first sold 2018-01-xx, last 2022-12-xx
--   135.00  'N'  first sold 2023-01-xx, last 2024-12-xx
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
