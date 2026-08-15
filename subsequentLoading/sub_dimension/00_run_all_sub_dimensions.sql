-- ===================================================================
-- 00_run_all_sub_dimensions.sql
-- Runs every dimension SUBSEQUENT (incremental) load, in order.
--
-- Usage:
--   @c:\Users\laoli\Downloads\datawarehouseAnalysis\subsequentLoading\sub_dimension\00_run_all_sub_dimensions.sql
--
-- SCOPE: INSERT NEW RECORDS ONLY
--   A natural key present in the OLTP but missing from the dimension
--   gets a surrogate key and is added. Nothing is ever updated or
--   expired. Changed attributes - a price revision, a loyalty-tier
--   upgrade, a promotion - are deliberately NOT handled here; they are
--   SCD Type 2 and belong to the separate maintain-SCD2 step.
--
--   effective_start_date / effective_end_date / is_current_flag are
--   still populated on insert so that step has a clean starting point.
--
-- IDEMPOTENT: every procedure uses a NOT EXISTS anti-join, so running
-- this file twice inserts nothing the second time.
--
-- PREREQUISITES
--   The INITIAL loads must already have run. These procedures reuse
--   the staging views and the seq_*_key sequences created there.
--     initialLoading\init_data_dim\initial_load_date_dim.sql
--     initialLoading\init_dimension\00_run_all_dimensions.sql
--
-- DATE_DIM TAKES A PARAMETER. Edit the year inside 01_sub_date_dim.sql
-- before running, or call the procedure directly afterwards.
-- ===================================================================

SET SERVEROUTPUT ON
SET DEFINE OFF

PROMPT ============================================
PROMPT  1/8  DATE_DIM            (parameterised by year)
PROMPT ============================================
@@01_sub_date_dim.sql

-- ---- HOLIDAYS FOR ANY NEWLY ADDED YEARS ----
-- New calendar days arrive with holiday_ind = 'N'. Regenerate the
-- holiday file for the wider range, then run it:
--
--   cd c:\Users\laoli\Downloads\datawarehouseAnalysis\initialLoading\init_data_dim
--   python gen_holidays.py 2019 2026 > holiday_update.sql
--   @holiday_update.sql
--
-- The generated file resets ONLY the years it covers, so regenerating
-- a partial range (e.g. 2025 2026) leaves 2019-2022 untouched.

PROMPT ============================================
PROMPT  2/8  SUPPLIER_DIM
PROMPT ============================================
@@02_sub_supplier_dim.sql

PROMPT ============================================
PROMPT  3/8  PRODUCT_DIM
PROMPT ============================================
@@03_sub_product_dim.sql

PROMPT ============================================
PROMPT  4/8  BRANCH_DIM
PROMPT ============================================
@@04_sub_branch_dim.sql

PROMPT ============================================
PROMPT  5/8  SERVICE_DIM
PROMPT ============================================
@@05_sub_service_dim.sql

PROMPT ============================================
PROMPT  6/8  BRANCH_UTILS_DIM
PROMPT ============================================
@@06_sub_branch_utils_dim.sql

PROMPT ============================================
PROMPT  7/8  STAFF_DIM
PROMPT ============================================
@@07_sub_staff_dim.sql

PROMPT ============================================
PROMPT  8/8  CUSTOMER_DIM
PROMPT ============================================
@@08_sub_customer_dim.sql


-- ===================================================================
-- SUMMARY 1: DIMENSION vs SOURCE ROW COUNTS
-- With no versioning, dim_rows must EQUAL source_rows on every line.
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  DIMENSION ROW COUNTS  (dim must equal source)
PROMPT ============================================

SELECT 'branch_dim' AS dimension,
       (SELECT COUNT(*) FROM branch_dim)              AS dim_rows,
       (SELECT COUNT(*) FROM branch)                  AS source_rows
FROM dual
UNION ALL
SELECT 'branch_utils_dim',
       (SELECT COUNT(*) FROM branch_utils_dim),
       (SELECT COUNT(*) FROM branch_utils_category)   FROM dual
UNION ALL
SELECT 'supplier_dim',
       (SELECT COUNT(*) FROM supplier_dim),
       (SELECT COUNT(*) FROM supplier)                FROM dual
UNION ALL
SELECT 'service_dim',
       (SELECT COUNT(*) FROM service_dim),
       (SELECT COUNT(*) FROM service)                 FROM dual
UNION ALL
SELECT 'product_dim',
       (SELECT COUNT(*) FROM product_dim),
       (SELECT COUNT(*) FROM product)                 FROM dual
UNION ALL
SELECT 'staff_dim',
       (SELECT COUNT(*) FROM staff_dim),
       (SELECT COUNT(*) FROM staff)                   FROM dual
UNION ALL
SELECT 'customer_dim',
       (SELECT COUNT(*) FROM customer_dim),
       (SELECT COUNT(*) FROM customer)                FROM dual
UNION ALL
-- date_dim has no OLTP source; source_rows is the calendar-day count
SELECT 'date_dim',
       (SELECT COUNT(*) FROM date_dim),
       (SELECT COUNT(*) FROM date_dim WHERE date_key <> 0) FROM dual
ORDER BY 1;


-- ===================================================================
-- SUMMARY 2: DUPLICATE NATURAL KEYS - every number must be 0
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  DUPLICATE NATURAL KEYS  (all must be 0)
PROMPT ============================================

SELECT 'branch_dim' AS dimension, COUNT(*) AS duplicated_keys FROM (
    SELECT br_ID FROM branch_dim GROUP BY br_ID HAVING COUNT(*) > 1)
UNION ALL
SELECT 'branch_utils_dim', COUNT(*) FROM (
    SELECT br_utils_ID FROM branch_utils_dim
    GROUP BY br_utils_ID HAVING COUNT(*) > 1)
UNION ALL
SELECT 'supplier_dim', COUNT(*) FROM (
    SELECT sup_ID FROM supplier_dim GROUP BY sup_ID HAVING COUNT(*) > 1)
UNION ALL
SELECT 'service_dim', COUNT(*) FROM (
    SELECT serv_ID FROM service_dim GROUP BY serv_ID HAVING COUNT(*) > 1)
UNION ALL
SELECT 'product_dim', COUNT(*) FROM (
    SELECT product_ID FROM product_dim
    GROUP BY product_ID HAVING COUNT(*) > 1)
UNION ALL
SELECT 'staff_dim', COUNT(*) FROM (
    SELECT st_ID FROM staff_dim GROUP BY st_ID HAVING COUNT(*) > 1)
UNION ALL
SELECT 'customer_dim', COUNT(*) FROM (
    SELECT cus_ID FROM customer_dim GROUP BY cus_ID HAVING COUNT(*) > 1)
UNION ALL
SELECT 'date_dim', COUNT(*) FROM (
    SELECT cal_date FROM date_dim WHERE date_key <> 0
    GROUP BY cal_date HAVING COUNT(*) > 1);


-- ===================================================================
-- SUMMARY 3: FACTS MUST NOT BE ORPHANED - every number must be 0
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  FACT INTEGRITY  (all must be 0)
PROMPT ============================================

SELECT 'order_fact -> product_dim' AS check_name, COUNT(*) AS orphans
FROM order_fact f WHERE NOT EXISTS (
    SELECT 1 FROM product_dim d WHERE d.product_key = f.product_key)
UNION ALL
SELECT 'order_fact -> customer_dim', COUNT(*)
FROM order_fact f WHERE NOT EXISTS (
    SELECT 1 FROM customer_dim d WHERE d.customer_key = f.customer_key)
UNION ALL
SELECT 'order_fact -> staff_dim', COUNT(*)
FROM order_fact f WHERE NOT EXISTS (
    SELECT 1 FROM staff_dim d WHERE d.staff_key = f.staff_key)
UNION ALL
SELECT 'order_fact -> branch_dim', COUNT(*)
FROM order_fact f WHERE NOT EXISTS (
    SELECT 1 FROM branch_dim d WHERE d.branch_key = f.branch_key)
UNION ALL
SELECT 'order_fact -> date_dim', COUNT(*)
FROM order_fact f WHERE NOT EXISTS (
    SELECT 1 FROM date_dim d WHERE d.date_key = f.date_key)
UNION ALL
SELECT 'reservation_fact -> service_dim', COUNT(*)
FROM reservation_fact f WHERE NOT EXISTS (
    SELECT 1 FROM service_dim d WHERE d.service_key = f.service_key);


-- ===================================================================
-- THE IDEMPOTENCY TEST
-- ===================================================================
-- Run this whole file a SECOND time immediately. Every procedure must
-- report 0 inserted, and SUMMARY 1 must show identical row counts. If
-- a count grows on the second run, an anti-join is not matching the
-- natural key it should.
--
-- STILL TO COME
--   maintainSCD2\      - expire-and-version logic for changed
--                        attributes, plus Type 1 refresh for the
--                        SYSDATE-derived columns (cus_age,
--                        cus_age_band, st_age, serv_duration)
--   subsequentLoading\sub_fact\  - incremental fact loads
-- ===================================================================
