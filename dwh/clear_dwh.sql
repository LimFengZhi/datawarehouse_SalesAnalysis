-- ===================================================================
-- clear_dwh.sql             RESET THE WAREHOUSE BACK TO EMPTY
--
-- *******************************************************************
-- *  THIS DELETES ALL WAREHOUSE DATA. There is no undo after the    *
-- *  COMMIT. Only run it when you intend to reload from scratch.    *
-- *******************************************************************
--
-- Usage:
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\dwh\clear_dwh.sql
--
-- WHAT IT CLEARS
--   - all 5 fact tables
--   - all 8 dimension tables
--   - all 8 surrogate-key sequences (dropped, so the init scripts can
--     CREATE them again cleanly)
--
-- WHAT IT DOES **NOT** TOUCH
--   - the 14 OLTP tables. Those hold 700,000 rows that took SQL*Loader
--     to load; wiping them would mean re-running load_all.bat. The
--     OLTP reset is at the bottom of this file, commented out.
--   - the tables themselves. Only the DATA goes. For a full DDL
--     rebuild run create_dwh.sql instead, which drops and recreates
--     every table.
--   - views and procedures. Every script uses CREATE OR REPLACE, so
--     they are overwritten on the next run anyway.
--
-- WHY DELETE AND NOT TRUNCATE ON THE DIMENSIONS
--   Oracle refuses TRUNCATE on a parent table while an enabled foreign
--   key references it - even when the child table is already empty
--   (ORA-02266). The facts have FKs to every dimension, so dimensions
--   must use DELETE. Facts have no children, so TRUNCATE works there
--   and is much faster for the 349,396-row order_fact.
-- ===================================================================

SET SERVEROUTPUT ON

PROMPT ============================================
PROMPT  CLEARING WAREHOUSE - facts first
PROMPT ============================================

-- ---------- FACTS (no children, so TRUNCATE is safe and fast) ------
TRUNCATE TABLE order_fact;
TRUNCATE TABLE reservation_fact;
TRUNCATE TABLE purchase_fact;
TRUNCATE TABLE salary_payment_fact;
TRUNCATE TABLE branch_expense_fact;

PROMPT ============================================
PROMPT  CLEARING WAREHOUSE - dimensions
PROMPT ============================================

-- ---------- DIMENSIONS (facts reference these, so DELETE) ----------
DELETE FROM customer_dim;
DELETE FROM staff_dim;
DELETE FROM product_dim;
DELETE FROM service_dim;
DELETE FROM supplier_dim;
DELETE FROM branch_utils_dim;
DELETE FROM branch_dim;
DELETE FROM date_dim;
COMMIT;

PROMPT ============================================
PROMPT  DROPPING SEQUENCES
PROMPT ============================================

-- Dropped, NOT recreated. Each init script owns its own
-- CREATE SEQUENCE, and a plain CREATE would fail with ORA-00955 if the
-- sequence still existed. Emptying a table does not reset its
-- sequence, and Oracle 11.2 has no ALTER SEQUENCE ... RESTART - so
-- without this the next load would carry on from the old numbers.
BEGIN
    FOR s IN (SELECT sequence_name FROM user_sequences
              WHERE sequence_name IN ('SEQ_BRANCH_KEY',
                                      'SEQ_BRANCH_UTILS_KEY',
                                      'SEQ_SUPPLIER_KEY',
                                      'SEQ_SERVICE_KEY',
                                      'SEQ_PRODUCT_KEY',
                                      'SEQ_STAFF_KEY',
                                      'SEQ_CUSTOMER_KEY',
                                      'DATE_DIM_SEQ'))
    LOOP
        EXECUTE IMMEDIATE 'DROP SEQUENCE ' || s.sequence_name;
        DBMS_OUTPUT.PUT_LINE('  dropped ' || s.sequence_name);
    END LOOP;
END;
/

-- ===================================================================
-- VERIFY - every count must be 0, and no sequences must remain
-- ===================================================================
PROMPT
PROMPT ============================================
PROMPT  VERIFY  (all counts must be 0)
PROMPT ============================================

SELECT 'order_fact'          AS table_name, COUNT(*) AS rows_left FROM order_fact
UNION ALL SELECT 'reservation_fact',    COUNT(*) FROM reservation_fact
UNION ALL SELECT 'purchase_fact',       COUNT(*) FROM purchase_fact
UNION ALL SELECT 'salary_payment_fact', COUNT(*) FROM salary_payment_fact
UNION ALL SELECT 'branch_expense_fact', COUNT(*) FROM branch_expense_fact
UNION ALL SELECT 'date_dim',            COUNT(*) FROM date_dim
UNION ALL SELECT 'branch_dim',          COUNT(*) FROM branch_dim
UNION ALL SELECT 'branch_utils_dim',    COUNT(*) FROM branch_utils_dim
UNION ALL SELECT 'supplier_dim',        COUNT(*) FROM supplier_dim
UNION ALL SELECT 'service_dim',         COUNT(*) FROM service_dim
UNION ALL SELECT 'product_dim',         COUNT(*) FROM product_dim
UNION ALL SELECT 'staff_dim',           COUNT(*) FROM staff_dim
UNION ALL SELECT 'customer_dim',        COUNT(*) FROM customer_dim
ORDER BY 1;

-- Must return NO ROWS
SELECT sequence_name, last_number FROM user_sequences
WHERE  sequence_name IN ('SEQ_BRANCH_KEY','SEQ_BRANCH_UTILS_KEY',
                         'SEQ_SUPPLIER_KEY','SEQ_SERVICE_KEY',
                         'SEQ_PRODUCT_KEY','SEQ_STAFF_KEY',
                         'SEQ_CUSTOMER_KEY','DATE_DIM_SEQ');

-- The OLTP is untouched. These must still show the full source data.
SELECT 'customer'     AS oltp_table, COUNT(*) AS rows_kept FROM customer
UNION ALL SELECT 'orders',       COUNT(*) FROM orders
UNION ALL SELECT 'order_detail', COUNT(*) FROM order_detail
ORDER BY 1;
-- expect 14632 / 116067 / 256137  (sales_data2\data18_21 loaded)


-- ===================================================================
-- OPTIONAL: ALSO CLEAR THE OLTP  (normally you do NOT want this)
-- ===================================================================
-- Only if you intend to re-run SQL*Loader from the CSVs. Child tables
-- first, or the foreign keys reject the delete.
--
-- TRUNCATE TABLE order_detail;
-- TRUNCATE TABLE orders;
-- TRUNCATE TABLE reservation_detail;
-- TRUNCATE TABLE reservation;
-- TRUNCATE TABLE purchase;
-- TRUNCATE TABLE salary_payment;
-- TRUNCATE TABLE branch_expense;
-- TRUNCATE TABLE staff;
-- TRUNCATE TABLE customer;
-- TRUNCATE TABLE service;
-- TRUNCATE TABLE product;
-- TRUNCATE TABLE supplier;
-- TRUNCATE TABLE branch_utils_category;
-- TRUNCATE TABLE branch;
--
-- Then reload:
--   cd operational_DB\sqlloader_control_files
--   load_all.bat dwh <password> XE
-- ===================================================================
