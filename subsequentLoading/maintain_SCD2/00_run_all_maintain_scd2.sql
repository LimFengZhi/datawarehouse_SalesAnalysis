-- ===================================================================
-- 00_run_all_maintain_scd2.sql
-- Runs SCD maintenance for every dimension that can change.
--
-- Usage:
--   @c:\Users\laoli\Downloads\datawarehouseAnalysis\subsequentLoading\maintain_SCD2\00_run_all_maintain_scd2.sql
--
-- WHAT THIS DOES - and what it deliberately does NOT do
--   Type 2 (supplier, product, branch, service, staff, customer):
--       an attribute changed -> expire the current row
--                               (effective_end_date = yesterday,
--                                is_current_flag = 'N')
--                            -> insert a new current version
--
--   BRAND-NEW records are NOT inserted here. That is
--   subsequentLoading\sub_dimension\. The two are orthogonal:
--       sub_dimension -> natural keys that do not exist yet
--       maintain_SCD2 -> natural keys that exist and changed
--
-- RUN ORDER: sub_dimension FIRST, then this.
--
-- IDEMPOTENT: run it twice and the second pass reports 0 everywhere.
--
-- ===================================================================
-- DATING THE CHANGE  -  p_effective_date
-- ===================================================================
-- Every procedure takes an optional date:
--
--     maintain_product_dim_scd2(p_effective_date IN DATE DEFAULT SYSDATE)
--
--   old version -> effective_end_date   = p_effective_date - 1
--   new version -> effective_start_date = p_effective_date
--
-- WHY IT IS A PARAMETER AND NOT DISCOVERED AUTOMATICALLY
--   The OLTP has no last_modified column on any table. The only date
--   columns are EVENT dates - cus_reg_date, order_date, booking_date,
--   purchase_date - none of which record when a product's price or a
--   customer's tier was edited. So the warehouse genuinely cannot know
--   when a change happened; it has to be told.
--
--   Leaving the argument off dates the change TODAY, which is only
--   right if you are loading the same day it happened. If a price
--   really changed on 1 July, pass that date and the history is
--   correct:  EXEC maintain_product_dim_scd2(DATE '2024-07-01');
--
-- RUNNING THE WHOLE BATCH WITH ONE DATE
--   The @@ includes below run each procedure with the DEFAULT (today).
--   To date the whole batch instead, run this file once to create the
--   procedures, then re-run just the calls:
--
--     EXEC maintain_supplier_dim_scd2(DATE '2024-07-01');
--     EXEC maintain_product_dim_scd2 (DATE '2024-07-01');
--     EXEC maintain_branch_dim_scd2  (DATE '2024-07-01');
--     EXEC maintain_service_dim_scd2 (DATE '2024-07-01');
--     EXEC maintain_staff_dim_scd2   (DATE '2024-07-01');
--     EXEC maintain_customer_dim_scd2(DATE '2024-07-01');
--
--   Harmless to do: the first pass already versioned everything, so
--   the dated pass finds nothing left to change. Reach for it when you
--   know the real date BEFORE the first run.
--
-- SAFETY RAIL
--   effective_end_date uses GREATEST(p_effective_date - 1,
--   effective_start_date). Back-dating a change to before the current
--   version began would otherwise produce a row that ends before it
--   starts. The clamp turns that into a same-day version instead, and
--   the integrity summary below flags any inverted range.
--
-- TWO DIMENSIONS ARE ABSENT ON PURPOSE
--   date_dim         - a calendar day never changes. No SCD2 columns,
--                      nothing to maintain.
--   branch_utils_dim - a 6-row lookup of utility categories. It has no
--                      effective dates and no is_current_flag (see
--                      create_dwh.sql), so it cannot hold history, and
--                      "Rent" is not going to become something else.
--                      New categories are added by sub_dimension. On
--                      the rare occasion a label needs correcting, a
--                      one-line UPDATE does it:
--                        UPDATE branch_utils_dim SET util_name = '...'
--                         WHERE br_utils_ID = <n>;
--                      The surrogate key never moves, so every
--                      branch_expense_fact row keeps resolving.
--
-- WHY SOME COLUMNS ARE TYPE 1 INSIDE A TYPE 2 DIMENSION
--   cus_age, cus_age_band, st_age  -> derived from SYSDATE, so they
--       move on every birthday. Versioning them would add ~26,000 rows
--       a year for no business reason.
--   serv_duration -> an average over reservation_detail, drifts with
--       every new booking.
--   All four are refreshed in place and kept OUT of change detection.
-- ===================================================================

SET SERVEROUTPUT ON
SET DEFINE OFF

PROMPT ============================================
PROMPT  1/6  SUPPLIER_DIM        (Type 2)
PROMPT ============================================
@@01_maintain_supplier_dim.sql

PROMPT ============================================
PROMPT  2/6  PRODUCT_DIM         (Type 2)
PROMPT ============================================
@@02_maintain_product_dim.sql

PROMPT ============================================
PROMPT  3/6  BRANCH_DIM          (Type 2)
PROMPT ============================================
@@03_maintain_branch_dim.sql

PROMPT ============================================
PROMPT  4/6  SERVICE_DIM         (Type 2 + Type 1 duration)
PROMPT ============================================
@@04_maintain_service_dim.sql

PROMPT ============================================
PROMPT  5/6  STAFF_DIM           (Type 2 + Type 1 age)
PROMPT ============================================
@@05_maintain_staff_dim.sql

PROMPT ============================================
PROMPT  6/6  CUSTOMER_DIM        (Type 2 + Type 1 age)
PROMPT ============================================
@@06_maintain_customer_dim.sql


-- ===================================================================
-- SUMMARY 1: VERSION COUNTS
-- current_rows must equal the OLTP source count.
-- total_rows is higher wherever Type 2 has kept history.
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  VERSION COUNTS
PROMPT ============================================

SELECT 'branch_dim' AS dimension,
       (SELECT COUNT(*) FROM branch_dim)                           AS total_rows,
       (SELECT COUNT(*) FROM branch_dim WHERE is_current_flag='Y') AS current_rows,
       (SELECT COUNT(*) FROM branch)                               AS source_rows
FROM dual
UNION ALL
SELECT 'supplier_dim',
       (SELECT COUNT(*) FROM supplier_dim),
       (SELECT COUNT(*) FROM supplier_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM supplier)                             FROM dual
UNION ALL
SELECT 'service_dim',
       (SELECT COUNT(*) FROM service_dim),
       (SELECT COUNT(*) FROM service_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM service)                              FROM dual
UNION ALL
SELECT 'product_dim',
       (SELECT COUNT(*) FROM product_dim),
       (SELECT COUNT(*) FROM product_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM product)                              FROM dual
UNION ALL
SELECT 'staff_dim',
       (SELECT COUNT(*) FROM staff_dim),
       (SELECT COUNT(*) FROM staff_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM staff)                                FROM dual
UNION ALL
SELECT 'customer_dim',
       (SELECT COUNT(*) FROM customer_dim),
       (SELECT COUNT(*) FROM customer_dim WHERE is_current_flag='Y'),
       (SELECT COUNT(*) FROM customer)                             FROM dual
ORDER BY 1;


-- ===================================================================
-- SUMMARY 2: SCD2 INTEGRITY - every number must be 0
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  SCD2 INTEGRITY  (all must be 0)
PROMPT ============================================

-- (a) exactly one CURRENT row per natural key
SELECT 'branch_dim   >1 current' AS check_name, COUNT(*) AS bad FROM (
    SELECT br_ID FROM branch_dim WHERE is_current_flag='Y'
    GROUP BY br_ID HAVING COUNT(*) <> 1)
UNION ALL
SELECT 'supplier_dim >1 current', COUNT(*) FROM (
    SELECT sup_ID FROM supplier_dim WHERE is_current_flag='Y'
    GROUP BY sup_ID HAVING COUNT(*) <> 1)
UNION ALL
SELECT 'service_dim  >1 current', COUNT(*) FROM (
    SELECT serv_ID FROM service_dim WHERE is_current_flag='Y'
    GROUP BY serv_ID HAVING COUNT(*) <> 1)
UNION ALL
SELECT 'product_dim  >1 current', COUNT(*) FROM (
    SELECT product_ID FROM product_dim WHERE is_current_flag='Y'
    GROUP BY product_ID HAVING COUNT(*) <> 1)
UNION ALL
SELECT 'staff_dim    >1 current', COUNT(*) FROM (
    SELECT st_ID FROM staff_dim WHERE is_current_flag='Y'
    GROUP BY st_ID HAVING COUNT(*) <> 1)
UNION ALL
SELECT 'customer_dim >1 current', COUNT(*) FROM (
    SELECT cus_ID FROM customer_dim WHERE is_current_flag='Y'
    GROUP BY cus_ID HAVING COUNT(*) <> 1)
UNION ALL
-- (b) an expired row must never still claim 9999-12-31
SELECT 'branch_dim   bad end date', COUNT(*) FROM branch_dim
    WHERE is_current_flag='N' AND effective_end_date = DATE '9999-12-31'
UNION ALL
SELECT 'supplier_dim bad end date', COUNT(*) FROM supplier_dim
    WHERE is_current_flag='N' AND effective_end_date = DATE '9999-12-31'
UNION ALL
SELECT 'service_dim  bad end date', COUNT(*) FROM service_dim
    WHERE is_current_flag='N' AND effective_end_date = DATE '9999-12-31'
UNION ALL
SELECT 'product_dim  bad end date', COUNT(*) FROM product_dim
    WHERE is_current_flag='N' AND effective_end_date = DATE '9999-12-31'
UNION ALL
SELECT 'staff_dim    bad end date', COUNT(*) FROM staff_dim
    WHERE is_current_flag='N' AND effective_end_date = DATE '9999-12-31'
UNION ALL
SELECT 'customer_dim bad end date', COUNT(*) FROM customer_dim
    WHERE is_current_flag='N' AND effective_end_date = DATE '9999-12-31'
UNION ALL
-- (c) a version must never end before it started. Only reachable by
--     back-dating p_effective_date past the version's own start.
SELECT 'branch_dim   inverted range', COUNT(*) FROM branch_dim
    WHERE effective_end_date < effective_start_date
UNION ALL
SELECT 'supplier_dim inverted range', COUNT(*) FROM supplier_dim
    WHERE effective_end_date < effective_start_date
UNION ALL
SELECT 'service_dim  inverted range', COUNT(*) FROM service_dim
    WHERE effective_end_date < effective_start_date
UNION ALL
SELECT 'product_dim  inverted range', COUNT(*) FROM product_dim
    WHERE effective_end_date < effective_start_date
UNION ALL
SELECT 'staff_dim    inverted range', COUNT(*) FROM staff_dim
    WHERE effective_end_date < effective_start_date
UNION ALL
SELECT 'customer_dim inverted range', COUNT(*) FROM customer_dim
    WHERE effective_end_date < effective_start_date;


-- ===================================================================
-- SUMMARY 3: FACTS MUST NOT BE ORPHANED - every number must be 0
-- Expiring a row keeps the old surrogate key alive, so facts pointing
-- at it stay valid. That is exactly what Type 2 is for.
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
SELECT 'reservation_fact -> service_dim', COUNT(*)
FROM reservation_fact f WHERE NOT EXISTS (
    SELECT 1 FROM service_dim d WHERE d.service_key = f.service_key)
UNION ALL
SELECT 'reservation_fact -> staff_dim', COUNT(*)
FROM reservation_fact f WHERE NOT EXISTS (
    SELECT 1 FROM staff_dim d WHERE d.staff_key = f.staff_key);


-- ===================================================================
-- THE IDEMPOTENCY TEST
-- ===================================================================
-- Run this whole file a SECOND time immediately. Every procedure must
-- report 0 expired and 0 versions. If a count stays non-zero on repeat
-- runs, a change-detection comparison is matching something that moves
-- by itself - almost always a column derived from SYSDATE that should
-- have been left as Type 1.
-- ===================================================================
