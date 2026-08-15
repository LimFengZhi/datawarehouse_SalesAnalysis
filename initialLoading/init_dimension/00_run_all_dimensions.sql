-- ===================================================================
-- 00_run_all_dimensions.sql
-- Runs every dimension initial load, in order.
--
-- Usage (from sqlplus, connected as your DWH schema):
--     @c:\Users\laoli\Downloads\datawarehouseAnalysis\init_dimension\00_run_all_dimensions.sql
--
-- @@ resolves each file relative to the folder holding THIS script, so
-- it works no matter which directory you started sqlplus from.
--
-- PREREQUISITES
--   1. 01_create_operational_db.sql has run and the 14 CSVs are loaded
--   2. create_dwh.sql has run (dimension + fact tables exist)
--   3. All dimension tables are EMPTY - each procedure refuses to load
--      into a non-empty table (see "Reload" at the bottom)
--
-- The dimensions do not depend on each other, so this order is only
-- smallest-first for readability. date_dim is separate and lives in
-- ..\initial_load_date_dim.sql
-- ===================================================================

SET SERVEROUTPUT ON
SET DEFINE OFF

PROMPT ============================================
PROMPT  1/7  BRANCH_DIM          (expect 5)
PROMPT ============================================
@@01_init_branch_dim.sql

PROMPT ============================================
PROMPT  2/7  BRANCH_UTILS_DIM    (expect 6)
PROMPT ============================================
@@02_init_branch_utils_dim.sql

PROMPT ============================================
PROMPT  3/7  SUPPLIER_DIM        (expect 6)
PROMPT ============================================
@@03_init_supplier_dim.sql

PROMPT ============================================
PROMPT  4/7  SERVICE_DIM         (expect 16)
PROMPT ============================================
@@04_init_service_dim.sql

PROMPT ============================================
PROMPT  5/7  PRODUCT_DIM         (expect 43)
PROMPT ============================================
@@05_init_product_dim.sql

PROMPT ============================================
PROMPT  6/7  STAFF_DIM           (expect 96)
PROMPT ============================================
@@06_init_staff_dim.sql

PROMPT ============================================
PROMPT  7/7  CUSTOMER_DIM        (expect 26000)
PROMPT ============================================
@@07_init_customer_dim.sql


-- ===================================================================
-- FINAL SUMMARY
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  ALL DIMENSIONS - ROW COUNT SUMMARY
PROMPT ============================================

SELECT 'date_dim'         AS dimension, COUNT(*) AS rows_loaded,
       1462               AS expected FROM date_dim
UNION ALL
SELECT 'branch_dim',       COUNT(*),     5      FROM branch_dim
UNION ALL
SELECT 'branch_utils_dim', COUNT(*),     6      FROM branch_utils_dim
UNION ALL
SELECT 'supplier_dim',     COUNT(*),     6      FROM supplier_dim
UNION ALL
SELECT 'service_dim',      COUNT(*),     16     FROM service_dim
UNION ALL
SELECT 'product_dim',      COUNT(*),     43     FROM product_dim
UNION ALL
SELECT 'staff_dim',        COUNT(*),     96     FROM staff_dim
UNION ALL
SELECT 'customer_dim',     COUNT(*),     26000  FROM customer_dim
ORDER BY 1;

-- Surrogate key ranges - each dimension should sit in its own band
SELECT 'branch_dim'       AS dimension, MIN(branch_key)       AS min_key,
       MAX(branch_key)       AS max_key FROM branch_dim
UNION ALL
SELECT 'branch_utils_dim', MIN(branch_utils_key),
       MAX(branch_utils_key)            FROM branch_utils_dim
UNION ALL
SELECT 'supplier_dim',     MIN(supplier_key),
       MAX(supplier_key)                FROM supplier_dim
UNION ALL
SELECT 'service_dim',      MIN(service_key),
       MAX(service_key)                 FROM service_dim
UNION ALL
SELECT 'product_dim',      MIN(product_key),
       MAX(product_key)                 FROM product_dim
UNION ALL
SELECT 'staff_dim',        MIN(staff_key),
       MAX(staff_key)                   FROM staff_dim
UNION ALL
SELECT 'customer_dim',     MIN(customer_key),
       MAX(customer_key)                FROM customer_dim
ORDER BY 2;

-- Every SCD2 dimension: exactly one current row per natural key
SELECT 'branch_dim' AS dimension, COUNT(*) AS non_current_or_dup FROM (
    SELECT br_ID FROM branch_dim WHERE is_current_flag = 'Y'
    GROUP BY br_ID HAVING COUNT(*) <> 1)
UNION ALL
SELECT 'supplier_dim', COUNT(*) FROM (
    SELECT sup_ID FROM supplier_dim WHERE is_current_flag = 'Y'
    GROUP BY sup_ID HAVING COUNT(*) <> 1)
UNION ALL
SELECT 'service_dim', COUNT(*) FROM (
    SELECT serv_ID FROM service_dim WHERE is_current_flag = 'Y'
    GROUP BY serv_ID HAVING COUNT(*) <> 1)
UNION ALL
SELECT 'product_dim', COUNT(*) FROM (
    SELECT product_ID FROM product_dim WHERE is_current_flag = 'Y'
    GROUP BY product_ID HAVING COUNT(*) <> 1)
UNION ALL
SELECT 'staff_dim', COUNT(*) FROM (
    SELECT st_ID FROM staff_dim WHERE is_current_flag = 'Y'
    GROUP BY st_ID HAVING COUNT(*) <> 1)
UNION ALL
SELECT 'customer_dim', COUNT(*) FROM (
    SELECT cus_ID FROM customer_dim WHERE is_current_flag = 'Y'
    GROUP BY cus_ID HAVING COUNT(*) <> 1);
-- every row above must be 0


-- ===================================================================
-- RELOAD  (run this block first if you need to start over)
-- ===================================================================
-- Each load procedure refuses to run when its table already has rows.
-- Use DELETE, not TRUNCATE: the fact tables have foreign keys pointing
-- at these dimensions, and Oracle blocks TRUNCATE on a parent table
-- whenever an enabled FK references it - even when the child is empty.
--
-- DELETE FROM customer_dim;
-- DELETE FROM staff_dim;
-- DELETE FROM product_dim;
-- DELETE FROM service_dim;
-- DELETE FROM supplier_dim;
-- DELETE FROM branch_utils_dim;
-- DELETE FROM branch_dim;
-- COMMIT;
--
-- The sequences also need resetting, or the new keys continue from
-- where the last run stopped. Oracle 11.2 has no ALTER SEQUENCE
-- RESTART, so drop and recreate them - the CREATE statements are in
-- SECTION 2 of each file:
--
-- DROP SEQUENCE seq_branch_key;
-- DROP SEQUENCE seq_branch_utils_key;
-- DROP SEQUENCE seq_supplier_key;
-- DROP SEQUENCE seq_service_key;
-- DROP SEQUENCE seq_product_key;
-- DROP SEQUENCE seq_staff_key;
-- DROP SEQUENCE seq_customer_key;
-- ===================================================================
