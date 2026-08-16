-- ===================================================================
-- validate_subsequent_loading.sql
-- ALL verification queries for the SUBSEQUENT loads. Run after
-- execute_sub_procedure.sql (data2, 2023-2024) or execute_sub2.sql
-- (data3, 2025):
--
--   @c:\Users\laoli\Downloads\datawarehouseAnalysis\subsequent_loading\validate_subsequent_loading.sql
--
-- The checks compare the warehouse against the OLTP, so the same file
-- works after ANY load - no hard-coded row counts except where a
-- comment says what each generation should show.
-- ===================================================================

SET SERVEROUTPUT ON
SET DEFINE OFF


-- ###################################################################
-- 1. DATE_DIM
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  1. DATE_DIM
PROMPT ##############################################

-- Days per year: 365, except 366 in 2020 and 2024.
-- holidays = 0 on a NEW year means holiday_update.sql was not re-run
-- after extending the calendar.
SELECT cal_year, COUNT(*) AS days,
       SUM(CASE WHEN holiday_ind = 'Y' THEN 1 ELSE 0 END) AS holidays
FROM   date_dim
WHERE  date_key <> 0
GROUP BY cal_year
ORDER BY cal_year;

-- Surrogate keys unique: total_rows must equal distinct_keys
SELECT COUNT(*)                 AS total_rows,
       COUNT(DISTINCT date_key) AS distinct_keys,
       MIN(date_key)            AS min_key,
       MAX(date_key)            AS max_key
FROM   date_dim;

-- No duplicate dates, no gaps in the run of days. Both must be 0.
SELECT 'duplicate dates' AS chk, COUNT(*) AS bad FROM (
    SELECT cal_date FROM date_dim WHERE date_key <> 0
    GROUP BY cal_date HAVING COUNT(*) > 1)
UNION ALL
SELECT 'missing days', COUNT(*) FROM (
    SELECT cal_date,
           LEAD(cal_date) OVER (ORDER BY cal_date) AS next_date
    FROM   date_dim WHERE date_key <> 0)
 WHERE next_date IS NOT NULL AND next_date <> cal_date + 1;


-- ###################################################################
-- 2. DIMENSION COVERAGE  (every OLTP key is represented; must be 0)
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  2. DIMENSION COVERAGE - all must be 0
PROMPT ##############################################

SELECT 'branch missing_from_dim' AS chk, COUNT(*) AS bad FROM branch b
  WHERE NOT EXISTS (SELECT 1 FROM branch_dim d WHERE d.br_ID = b.br_ID)
UNION ALL
SELECT 'supplier missing_from_dim', COUNT(*) FROM supplier s
  WHERE NOT EXISTS (SELECT 1 FROM supplier_dim d
                    WHERE d.sup_ID = s.sup_ID)
UNION ALL
SELECT 'product missing_from_dim', COUNT(*) FROM product p
  WHERE NOT EXISTS (SELECT 1 FROM product_dim d
                    WHERE d.product_ID = p.product_ID)
UNION ALL
SELECT 'service missing_from_dim', COUNT(*) FROM service s
  WHERE NOT EXISTS (SELECT 1 FROM service_dim d
                    WHERE d.serv_ID = s.serv_ID)
UNION ALL
SELECT 'staff missing_from_dim', COUNT(*) FROM staff s
  WHERE NOT EXISTS (SELECT 1 FROM staff_dim d WHERE d.st_ID = s.st_ID)
UNION ALL
SELECT 'customer missing_from_dim', COUNT(*) FROM customer c
  WHERE NOT EXISTS (SELECT 1 FROM customer_dim d
                    WHERE d.cus_ID = c.cus_ID)
UNION ALL
SELECT 'utils missing_from_dim', COUNT(*) FROM branch_utils_category u
  WHERE NOT EXISTS (SELECT 1 FROM branch_utils_dim d
                    WHERE d.br_utils_ID = u.br_utils_ID);


-- ###################################################################
-- 3. SCD2 INTEGRITY  (every count must be 0)
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  3. SCD2 INTEGRITY - all must be 0
PROMPT ##############################################

-- Exactly ONE current row per natural key
SELECT 'branch current<>1' AS chk, COUNT(*) AS bad FROM (
    SELECT br_ID FROM branch_dim WHERE is_current_flag = 'Y'
    GROUP BY br_ID HAVING COUNT(*) <> 1)
UNION ALL SELECT 'supplier current<>1', COUNT(*) FROM (
    SELECT sup_ID FROM supplier_dim WHERE is_current_flag = 'Y'
    GROUP BY sup_ID HAVING COUNT(*) <> 1)
UNION ALL SELECT 'product current<>1', COUNT(*) FROM (
    SELECT product_ID FROM product_dim WHERE is_current_flag = 'Y'
    GROUP BY product_ID HAVING COUNT(*) <> 1)
UNION ALL SELECT 'service current<>1', COUNT(*) FROM (
    SELECT serv_ID FROM service_dim WHERE is_current_flag = 'Y'
    GROUP BY serv_ID HAVING COUNT(*) <> 1)
UNION ALL SELECT 'staff current<>1', COUNT(*) FROM (
    SELECT st_ID FROM staff_dim WHERE is_current_flag = 'Y'
    GROUP BY st_ID HAVING COUNT(*) <> 1)
UNION ALL SELECT 'customer current<>1', COUNT(*) FROM (
    SELECT cus_ID FROM customer_dim WHERE is_current_flag = 'Y'
    GROUP BY cus_ID HAVING COUNT(*) <> 1);

-- No expired row may still claim 9999-12-31
SELECT 'branch bad_end_dates' AS chk, COUNT(*) AS bad FROM branch_dim
  WHERE is_current_flag = 'N'
    AND effective_end_date = DATE '9999-12-31'
UNION ALL SELECT 'supplier bad_end_dates', COUNT(*) FROM supplier_dim
  WHERE is_current_flag = 'N'
    AND effective_end_date = DATE '9999-12-31'
UNION ALL SELECT 'product bad_end_dates', COUNT(*) FROM product_dim
  WHERE is_current_flag = 'N'
    AND effective_end_date = DATE '9999-12-31'
UNION ALL SELECT 'service bad_end_dates', COUNT(*) FROM service_dim
  WHERE is_current_flag = 'N'
    AND effective_end_date = DATE '9999-12-31'
UNION ALL SELECT 'staff bad_end_dates', COUNT(*) FROM staff_dim
  WHERE is_current_flag = 'N'
    AND effective_end_date = DATE '9999-12-31'
UNION ALL SELECT 'customer bad_end_dates', COUNT(*) FROM customer_dim
  WHERE is_current_flag = 'N'
    AND effective_end_date = DATE '9999-12-31';

-- Versioning must never orphan a fact: old surrogate keys stay valid
SELECT 'order->product orphans' AS chk, COUNT(*) AS bad FROM order_fact f
  WHERE NOT EXISTS (SELECT 1 FROM product_dim d
                    WHERE d.product_key = f.product_key)
UNION ALL SELECT 'order->customer orphans', COUNT(*) FROM order_fact f
  WHERE NOT EXISTS (SELECT 1 FROM customer_dim d
                    WHERE d.customer_key = f.customer_key)
UNION ALL SELECT 'order->staff orphans', COUNT(*) FROM order_fact f
  WHERE NOT EXISTS (SELECT 1 FROM staff_dim d
                    WHERE d.staff_key = f.staff_key)
UNION ALL SELECT 'reservation->service orphans', COUNT(*)
  FROM reservation_fact f
  WHERE NOT EXISTS (SELECT 1 FROM service_dim d
                    WHERE d.service_key = f.service_key)
UNION ALL SELECT 'purchase->supplier orphans', COUNT(*)
  FROM purchase_fact f
  WHERE NOT EXISTS (SELECT 1 FROM supplier_dim d
                    WHERE d.supplier_key = f.supplier_key);


-- ###################################################################
-- 4. VERSION HISTORY  (the SCD2 payoff)
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  4. VERSION HISTORY
PROMPT ##############################################

-- After data2: product 55 total / 48 current.
-- After data3 (incl. 99_price_change_2025.sql): product 63 / 48,
-- service 24 / 18.
SELECT 'product_dim' AS dimension, COUNT(*) AS total_rows,
       SUM(CASE WHEN is_current_flag = 'Y' THEN 1 ELSE 0 END) AS current_rows
FROM   product_dim
UNION ALL
SELECT 'service_dim', COUNT(*),
       SUM(CASE WHEN is_current_flag = 'Y' THEN 1 ELSE 0 END)
FROM   service_dim;

-- Price history of every product that ever changed
SELECT product_key, product_ID, product_name, product_unit_price,
       effective_start_date, effective_end_date, is_current_flag
FROM   product_dim
WHERE  product_ID IN (SELECT product_ID FROM product_dim
                      GROUP BY product_ID HAVING COUNT(*) > 1)
ORDER BY product_ID, product_key;

-- Service history (first appears after the 2025 run)
SELECT service_key, serv_ID, serv_name, serv_price,
       effective_start_date, effective_end_date, is_current_flag
FROM   service_dim
WHERE  serv_ID IN (SELECT serv_ID FROM service_dim
                   GROUP BY serv_ID HAVING COUNT(*) > 1)
ORDER BY serv_ID, service_key;

-- Each price version carries exactly the order lines that paid it.
-- Product 16 (Peptide Firming Serum) rose in 2023 AND 2025:
-- after data3 expect three rows - 120 / 135 / 149.
SELECT p.product_unit_price, p.is_current_flag,
       p.effective_start_date, p.effective_end_date,
       MIN(d.cal_date) AS first_sold, MAX(d.cal_date) AS last_sold,
       COUNT(*)        AS order_lines
FROM   order_fact  f
JOIN   product_dim p ON p.product_key = f.product_key
JOIN   date_dim    d ON d.date_key    = f.date_key
WHERE  p.product_ID = 16
GROUP BY p.product_unit_price, p.is_current_flag,
         p.effective_start_date, p.effective_end_date
ORDER BY first_sold;


-- ###################################################################
-- 5. FACT COMPLETENESS  (fact must equal source)
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  5. FACT COMPLETENESS
PROMPT ##############################################

-- fact_rows must equal source_rows on every line.
-- After data2: 635,340 / 156,888 / 16,937 / 5,781 / 2,292
-- After data3: 800,092 / 196,515 / 20,163 / 7,113 / 2,724
SELECT 'order_fact' AS fact_table,
       (SELECT COUNT(*) FROM order_fact)   AS fact_rows,
       (SELECT COUNT(*) FROM order_detail) AS source_rows FROM dual
UNION ALL SELECT 'reservation_fact',
       (SELECT COUNT(*) FROM reservation_fact),
       (SELECT COUNT(*) FROM reservation_detail) FROM dual
UNION ALL SELECT 'purchase_fact',
       (SELECT COUNT(*) FROM purchase_fact),
       (SELECT COUNT(*) FROM purchase) FROM dual
UNION ALL SELECT 'salary_payment_fact',
       (SELECT COUNT(*) FROM salary_payment_fact),
       (SELECT COUNT(*) FROM salary_payment) FROM dual
UNION ALL SELECT 'branch_expense_fact',
       (SELECT COUNT(*) FROM branch_expense_fact),
       (SELECT COUNT(*) FROM branch_expense) FROM dual
ORDER BY 1;

-- If a fact is short, these say WHICH lookup dropped rows. All 0.
-- 'no_date' non-zero usually means date_dim was not extended:
--     EXEC load_date_dim_incremental(<year>);
SELECT 'order no_date' AS chk, COUNT(*) AS bad FROM order_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                    WHERE d.cal_date = ls.order_date)
UNION ALL SELECT 'order no_product', COUNT(*) FROM order_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM product_dim p
                    WHERE p.product_ID = ls.product_ID
                      AND p.is_current_flag = 'Y')
UNION ALL SELECT 'order no_customer', COUNT(*) FROM order_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM customer_dim c
                    WHERE c.cus_ID = ls.cus_ID
                      AND c.is_current_flag = 'Y')
UNION ALL SELECT 'order no_staff', COUNT(*) FROM order_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM staff_dim s
                    WHERE s.st_ID = ls.st_ID AND s.is_current_flag = 'Y')
UNION ALL SELECT 'order no_branch', COUNT(*) FROM order_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM branch_dim b
                    WHERE b.br_ID = ls.br_ID AND b.is_current_flag = 'Y')
UNION ALL SELECT 'reservation no_date', COUNT(*)
  FROM reservation_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                    WHERE d.cal_date = ls.res_date)
UNION ALL SELECT 'reservation no_service', COUNT(*)
  FROM reservation_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM service_dim v
                    WHERE v.serv_ID = ls.serv_ID
                      AND v.is_current_flag = 'Y')
UNION ALL SELECT 'purchase no_date', COUNT(*)
  FROM purchase_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                    WHERE d.cal_date = ls.purchase_date)
UNION ALL SELECT 'purchase no_supplier', COUNT(*)
  FROM purchase_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM supplier_dim u
                    WHERE u.sup_ID = ls.sup_ID
                      AND u.is_current_flag = 'Y')
UNION ALL SELECT 'salary no_date', COUNT(*)
  FROM salary_payment_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                    WHERE d.cal_date = ls.payment_date)
UNION ALL SELECT 'expense no_date', COUNT(*)
  FROM branch_expense_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                    WHERE d.cal_date = ls.payment_date)
UNION ALL SELECT 'expense no_utils', COUNT(*)
  FROM branch_expense_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM branch_utils_dim u
                    WHERE u.br_utils_ID = ls.br_utils_ID);

-- Measures still reconcile. Both must be 0.
SELECT 'order gross-disc+tax=total' AS chk, COUNT(*) AS bad
  FROM order_fact
  WHERE ABS(order_gross_amt - order_discount_amt + order_tax_amt
            - order_total_amt) > 0.01
UNION ALL
SELECT 'salary gross-deduct=net', COUNT(*)
  FROM salary_payment_fact
  WHERE ABS(gross_amount - deduction_amount - net_amount) > 0.01;


-- ###################################################################
-- 6. BUSINESS-PATTERN CHECKS
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  6. BUSINESS PATTERNS
PROMPT ##############################################

-- Revenue by year: one row per loaded year. Fewer rows than years
-- means date_dim did not reach far enough. 2020-2021 dip (lockdowns),
-- 2022 recovers, 2023 onward grows.
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

-- Branch first sale: Ipoh appears from 2023-03-01 (data2's new branch)
SELECT b.br_city, MIN(d.cal_date) AS first_sale, COUNT(*) AS lines
FROM   order_fact f
JOIN   branch_dim b ON b.branch_key = f.branch_key
JOIN   date_dim   d ON d.date_key   = f.date_key
GROUP BY b.br_city
ORDER BY first_sale;

-- Reservation status mix per year: lockdown gaps still visible,
-- healthy no-show rate in the new years
SELECT d.cal_year, f.res_status, COUNT(*) AS bookings
FROM   reservation_fact f
JOIN   date_dim d ON d.date_key = f.date_key
GROUP BY d.cal_year, f.res_status
ORDER BY d.cal_year, f.res_status;

-- Payroll by year and branch: Ipoh team joins from 2023-02
SELECT SUBSTR(f.pay_period, 1, 4) AS yr, b.br_city,
       ROUND(SUM(f.net_amount), 2) AS payroll,
       COUNT(DISTINCT f.staff_key) AS headcount
FROM   salary_payment_fact f
JOIN   branch_dim b ON b.branch_key = f.branch_key
GROUP BY SUBSTR(f.pay_period, 1, 4), b.br_city
ORDER BY yr, b.br_city;


-- ===================================================================
-- FINALLY: re-run the execute file. Every procedure must report
-- 0 inserted, 0 expired, 0 updated - proof the load is idempotent.
-- ===================================================================
