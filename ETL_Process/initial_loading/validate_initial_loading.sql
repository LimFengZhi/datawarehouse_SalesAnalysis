-- ===================================================================
-- validate_initial_loading.sql
-- ALL verification queries for the INITIAL load (data\, 2019-2022).
-- Run AFTER initial_load_date_dim.sql + holiday_update.sql, the seven
-- init_dimension scripts and the five init_fact scripts:
--
--   @c:\Users\laoli\Downloads\datawarehouseAnalysis\ETL_Process\initial_loading\validate_initial_loading.sql
--
-- Every "expect 0" query is an integrity check - a non-zero result
-- means something is wrong. The other queries are eyeball checks
-- against the known shape of the data\ dataset.
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

-- Expect 1462 (1,461 days 2019-2022 + the Unknown member)
SELECT COUNT(*) AS total_rows FROM date_dim;

-- Expect 365 / 366 / 365 / 365 days; holidays > 0 on every year.
-- Zero holidays everywhere means holiday_update.sql never ran.
SELECT cal_year, COUNT(*) AS days,
       SUM(CASE WHEN holiday_ind = 'Y' THEN 1 ELSE 0 END) AS holidays
FROM   date_dim
WHERE  cal_year BETWEEN 2019 AND 2022
GROUP BY cal_year
ORDER BY cal_year;

-- The festive days the dataset models. Each should return >= 1 day.
SELECT holiday_name, COUNT(*) AS days
FROM   date_dim
WHERE  holiday_name IN ('Chinese New Year', 'Hari Raya Aidilfitri',
                        'Deepavali', 'Christmas Day')
GROUP BY holiday_name
ORDER BY holiday_name;

-- No duplicate calendar dates. Must return no rows.
SELECT cal_date, COUNT(*) AS dupes
FROM   date_dim WHERE date_key <> 0
GROUP BY cal_date HAVING COUNT(*) > 1;


-- ###################################################################
-- 2. DIMENSION ROW COUNTS  (all in one result)
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  2. DIMENSION ROW COUNTS
PROMPT ##############################################

-- dim_rows must equal source_rows AND the expected count on every line.
SELECT 'branch_dim' AS dimension,
       (SELECT COUNT(*) FROM branch_dim)   AS dim_rows,
       (SELECT COUNT(*) FROM branch)       AS source_rows,
       5 AS expected FROM dual
UNION ALL SELECT 'branch_utils_dim',
       (SELECT COUNT(*) FROM branch_utils_dim),
       (SELECT COUNT(*) FROM branch_utils_category), 6  FROM dual
UNION ALL SELECT 'supplier_dim',
       (SELECT COUNT(*) FROM supplier_dim),
       (SELECT COUNT(*) FROM supplier), 6               FROM dual
UNION ALL SELECT 'service_dim',
       (SELECT COUNT(*) FROM service_dim),
       (SELECT COUNT(*) FROM service), 16               FROM dual
UNION ALL SELECT 'product_dim',
       (SELECT COUNT(*) FROM product_dim),
       (SELECT COUNT(*) FROM product), 43               FROM dual
UNION ALL SELECT 'staff_dim',
       (SELECT COUNT(*) FROM staff_dim),
       (SELECT COUNT(*) FROM staff), 96                 FROM dual
UNION ALL SELECT 'customer_dim',
       (SELECT COUNT(*) FROM customer_dim),
       (SELECT COUNT(*) FROM customer), 26000           FROM dual
ORDER BY 1;


-- ###################################################################
-- 3. DIMENSION INTEGRITY  (every count must be 0)
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  3. DIMENSION INTEGRITY - all must be 0
PROMPT ##############################################

-- No dimension row without its OLTP source (orphans)
SELECT 'branch_dim orphans' AS chk, COUNT(*) AS bad FROM branch_dim d
  WHERE NOT EXISTS (SELECT 1 FROM branch b WHERE b.br_ID = d.br_ID)
UNION ALL
SELECT 'supplier_dim orphans', COUNT(*) FROM supplier_dim d
  WHERE NOT EXISTS (SELECT 1 FROM supplier s WHERE s.sup_ID = d.sup_ID)
UNION ALL
SELECT 'service_dim orphans', COUNT(*) FROM service_dim d
  WHERE NOT EXISTS (SELECT 1 FROM service s WHERE s.serv_ID = d.serv_ID)
UNION ALL
SELECT 'product_dim orphans', COUNT(*) FROM product_dim d
  WHERE NOT EXISTS (SELECT 1 FROM product p
                    WHERE p.product_ID = d.product_ID)
UNION ALL
SELECT 'staff_dim orphans', COUNT(*) FROM staff_dim d
  WHERE NOT EXISTS (SELECT 1 FROM staff s WHERE s.st_ID = d.st_ID)
UNION ALL
SELECT 'customer_dim orphans', COUNT(*) FROM customer_dim d
  WHERE NOT EXISTS (SELECT 1 FROM customer c WHERE c.cus_ID = d.cus_ID)
UNION ALL
SELECT 'branch_utils_dim orphans', COUNT(*) FROM branch_utils_dim d
  WHERE NOT EXISTS (SELECT 1 FROM branch_utils_category u
                    WHERE u.br_utils_ID = d.br_utils_ID);

-- No duplicate natural keys (initial load = exactly one row per key)
SELECT 'branch dup NK' AS chk, COUNT(*) AS bad FROM (
    SELECT br_ID FROM branch_dim GROUP BY br_ID HAVING COUNT(*) > 1)
UNION ALL SELECT 'supplier dup NK', COUNT(*) FROM (
    SELECT sup_ID FROM supplier_dim GROUP BY sup_ID HAVING COUNT(*) > 1)
UNION ALL SELECT 'service dup NK', COUNT(*) FROM (
    SELECT serv_ID FROM service_dim GROUP BY serv_ID HAVING COUNT(*) > 1)
UNION ALL SELECT 'product dup NK', COUNT(*) FROM (
    SELECT product_ID FROM product_dim
    GROUP BY product_ID HAVING COUNT(*) > 1)
UNION ALL SELECT 'staff dup NK', COUNT(*) FROM (
    SELECT st_ID FROM staff_dim GROUP BY st_ID HAVING COUNT(*) > 1)
UNION ALL SELECT 'customer dup NK', COUNT(*) FROM (
    SELECT cus_ID FROM customer_dim GROUP BY cus_ID HAVING COUNT(*) > 1);

-- Nothing left 'Unknown' / 'Uncategorised' by the cleansing
SELECT 'utils unmapped' AS chk, COUNT(*) AS bad FROM branch_utils_dim
  WHERE util_category = 'Unknown' OR util_name = 'Unknown'
UNION ALL
SELECT 'service uncategorised', COUNT(*) FROM service_dim
  WHERE serv_category = 'Uncategorised'
UNION ALL
SELECT 'product uncategorised', COUNT(*) FROM product_dim
  WHERE product_category = 'Uncategorised' OR product_brand = 'Unbranded'
UNION ALL
SELECT 'customer unknown state', COUNT(*) FROM customer_dim
  WHERE cus_state = 'Unknown'
UNION ALL
SELECT 'staff unknown gender', COUNT(*) FROM staff_dim
  WHERE st_gender = 'Unknown';


-- ###################################################################
-- 4. DIMENSION CONTENT  (eyeball checks)
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  4. DIMENSION CONTENT
PROMPT ##############################################

-- Fixed/Variable split of the 6 utility categories
SELECT branch_utils_key, br_utils_ID, util_name, util_category
FROM   branch_utils_dim ORDER BY branch_utils_key;

-- 7 service categories; add-ons short, anti-aging long
SELECT serv_category, COUNT(*) AS services,
       ROUND(AVG(serv_duration)) AS avg_mins
FROM   service_dim GROUP BY serv_category ORDER BY serv_category;

-- 10 product categories / 7 brands
SELECT product_category, COUNT(*) AS products,
       ROUND(AVG(product_unit_price), 2) AS avg_price
FROM   product_dim GROUP BY product_category ORDER BY products DESC;

-- Roles: Beauty Therapist 36, Sales Assistant 18, Senior Therapist 16,
-- Receptionist 12, Cashier 9, Branch Manager 5
SELECT st_role, COUNT(*) AS staff_count
FROM   staff_dim GROUP BY st_role ORDER BY staff_count DESC;

-- Every branch has exactly 1 Branch Manager
SELECT br_ID, COUNT(*) AS managers
FROM   staff_dim WHERE st_role = 'Branch Manager'
GROUP BY br_ID ORDER BY br_ID;

-- Tiers: Bronze 14332, Silver 6936, Gold 3384, Platinum 1348
SELECT cus_loyalty_tier, COUNT(*) AS customers
FROM   customer_dim GROUP BY cus_loyalty_tier ORDER BY customers DESC;

-- Age bands populated, ages 18-61, none 'Unknown'
SELECT cus_age_band, COUNT(*) AS customers,
       MIN(cus_age) AS min_age, MAX(cus_age) AS max_age
FROM   customer_dim GROUP BY cus_age_band ORDER BY cus_age_band;


-- ###################################################################
-- 5. FACT ROW COUNTS  (fact must equal source)
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  5. FACT ROW COUNTS
PROMPT ##############################################

SELECT 'order_fact' AS fact_table,
       (SELECT COUNT(*) FROM order_fact)   AS fact_rows,
       (SELECT COUNT(*) FROM order_detail) AS source_rows,
       349396 AS expected FROM dual
UNION ALL SELECT 'reservation_fact',
       (SELECT COUNT(*) FROM reservation_fact),
       (SELECT COUNT(*) FROM reservation_detail), 88790 FROM dual
UNION ALL SELECT 'purchase_fact',
       (SELECT COUNT(*) FROM purchase_fact),
       (SELECT COUNT(*) FROM purchase), 10615           FROM dual
UNION ALL SELECT 'salary_payment_fact',
       (SELECT COUNT(*) FROM salary_payment_fact),
       (SELECT COUNT(*) FROM salary_payment), 3135      FROM dual
UNION ALL SELECT 'branch_expense_fact',
       (SELECT COUNT(*) FROM branch_expense_fact),
       (SELECT COUNT(*) FROM branch_expense), 1440      FROM dual
ORDER BY 1;


-- ###################################################################
-- 6. FACT INTEGRITY  (every count must be 0)
-- If a fact loaded short, these say WHICH dimension lookup failed.
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  6. FACT INTEGRITY - all must be 0
PROMPT ##############################################

-- Rows the staging views themselves rejected (NULL keys in the source)
SELECT 'order rejected_by_view' AS chk,
       (SELECT COUNT(*) FROM order_detail)
     - (SELECT COUNT(*) FROM order_fact_staging_v) AS bad FROM dual
UNION ALL SELECT 'reservation rejected_by_view',
       (SELECT COUNT(*) FROM reservation_detail)
     - (SELECT COUNT(*) FROM reservation_fact_staging_v) FROM dual
UNION ALL SELECT 'purchase rejected_by_view',
       (SELECT COUNT(*) FROM purchase)
     - (SELECT COUNT(*) FROM purchase_fact_staging_v) FROM dual
UNION ALL SELECT 'salary rejected_by_view',
       (SELECT COUNT(*) FROM salary_payment)
     - (SELECT COUNT(*) FROM salary_payment_fact_staging_v) FROM dual
UNION ALL SELECT 'expense rejected_by_view',
       (SELECT COUNT(*) FROM branch_expense)
     - (SELECT COUNT(*) FROM branch_expense_fact_staging_v) FROM dual;

-- Failed dimension lookups per staging view. SCD2 lookups use the same
-- date-range predicate as the load procedures: the version in force on
-- the transaction date.
SELECT 'order no_date' AS chk, COUNT(*) AS bad FROM order_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                    WHERE d.cal_date = ls.order_date)
UNION ALL SELECT 'order no_product', COUNT(*) FROM order_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM product_dim p
                    WHERE p.product_ID = ls.product_ID
                      AND ls.order_date BETWEEN p.effective_start_date
                                            AND p.effective_end_date)
UNION ALL SELECT 'order no_customer', COUNT(*) FROM order_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM customer_dim c
                    WHERE c.cus_ID = ls.cus_ID
                      AND ls.order_date BETWEEN c.effective_start_date
                                            AND c.effective_end_date)
UNION ALL SELECT 'order no_staff', COUNT(*) FROM order_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM staff_dim s
                    WHERE s.st_ID = ls.st_ID
                      AND ls.order_date BETWEEN s.effective_start_date
                                            AND s.effective_end_date)
UNION ALL SELECT 'order no_branch', COUNT(*) FROM order_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM branch_dim b
                    WHERE b.br_ID = ls.br_ID
                      AND ls.order_date BETWEEN b.effective_start_date
                                            AND b.effective_end_date)
UNION ALL SELECT 'reservation no_date', COUNT(*)
  FROM reservation_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                    WHERE d.cal_date = ls.res_date)
UNION ALL SELECT 'reservation no_service', COUNT(*)
  FROM reservation_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM service_dim v
                    WHERE v.serv_ID = ls.serv_ID
                      AND ls.res_date BETWEEN v.effective_start_date
                                          AND v.effective_end_date)
UNION ALL SELECT 'purchase no_date', COUNT(*) FROM purchase_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                    WHERE d.cal_date = ls.purchase_date)
UNION ALL SELECT 'purchase no_supplier', COUNT(*)
  FROM purchase_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM supplier_dim u
                    WHERE u.sup_ID = ls.sup_ID
                      AND ls.purchase_date BETWEEN u.effective_start_date
                                               AND u.effective_end_date)
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

-- Measures reconcile
SELECT 'order gross-disc+tax=total' AS chk, COUNT(*) AS bad
  FROM order_fact
  WHERE ABS(order_gross_amt - order_discount_amt + order_tax_amt
            - order_total_amt) > 0.01
UNION ALL
SELECT 'salary gross-deduct=net', COUNT(*)
  FROM salary_payment_fact
  WHERE ABS(gross_amount - deduction_amount - net_amount) > 0.01;

-- Derived reservation columns: hours 10-19, no negative durations
SELECT MIN(start_hour)   AS min_hr,   MAX(start_hour)   AS max_hr,
       MIN(res_duration) AS min_mins, MAX(res_duration) AS max_mins,
       COUNT(*) - COUNT(res_duration) AS null_durations
FROM   reservation_fact;


-- ###################################################################
-- 7. BUSINESS-PATTERN CHECKS  (the dataset's story)
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  7. BUSINESS PATTERNS
PROMPT ##############################################

-- COVID: services were banned during MCO 1.0 (Apr 2020) and FMCO
-- (Jun-Aug 2021), so this must return NO ROWS.
SELECT d.cal_year, d.cal_quarter, COUNT(*) AS completed_services
FROM   reservation_fact f
JOIN   date_dim d ON d.date_key = f.date_key
WHERE  f.res_status = 'Completed'
  AND ( (d.cal_date BETWEEN DATE '2020-04-01' AND DATE '2020-04-30')
     OR (d.cal_date BETWEEN DATE '2021-06-01' AND DATE '2021-08-31') )
GROUP BY d.cal_year, d.cal_quarter
ORDER BY 1, 2;

-- Product revenue by year: ~5.48m / 4.57m / 4.14m / 7.47m
SELECT d.cal_year,
       ROUND(SUM(f.order_gross_amt - f.order_discount_amt), 2) AS net_revenue,
       COUNT(*) AS order_lines
FROM   order_fact f
JOIN   date_dim d ON d.date_key = f.date_key
WHERE  f.order_status = 'Completed'
GROUP BY d.cal_year ORDER BY d.cal_year;

-- Service revenue by year: ~2.48m / 1.66m / 1.18m / 3.52m
SELECT d.cal_year,
       ROUND(SUM(f.serv_price - f.serv_discount_amt), 2) AS net_revenue
FROM   reservation_fact f
JOIN   date_dim d ON d.date_key = f.date_key
WHERE  f.res_status = 'Completed'
GROUP BY d.cal_year ORDER BY d.cal_year;

-- Branch ranking: Kuala Lumpur top, Melaka last
SELECT b.br_city,
       ROUND(SUM(f.order_gross_amt - f.order_discount_amt), 2) AS net_revenue
FROM   order_fact f
JOIN   branch_dim b ON b.branch_key = f.branch_key
WHERE  f.order_status = 'Completed'
GROUP BY b.br_city ORDER BY net_revenue DESC;

-- MCO pay cuts: avg base dips in 2020; bonuses spike (13th month, Raya)
SELECT SUBSTR(pay_period, 1, 4) AS yr,
       ROUND(AVG(base_amount), 2)  AS avg_base,
       ROUND(SUM(bonus_amount), 2) AS total_bonus
FROM   salary_payment_fact
GROUP BY SUBSTR(pay_period, 1, 4) ORDER BY yr;

-- Rent rebates: 2020 rent dips below 2019 and 2021
SELECT SUBSTR(f.billing_period, 1, 4) AS yr,
       ROUND(SUM(f.payment_amount), 2) AS total_rent
FROM   branch_expense_fact f
JOIN   branch_utils_dim u ON u.branch_utils_key = f.branch_utils_key
WHERE  u.util_name = 'Rent'
GROUP BY SUBSTR(f.billing_period, 1, 4) ORDER BY yr;
