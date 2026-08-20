-- ===================================================================
-- validate_initial_loading.sql
-- ALL verification queries for the INITIAL load (sales_data5\data19_23, 2019-2023).
-- Run AFTER initial_load_date_dim.sql + holiday_update.sql, the six
-- init_dimension scripts and the five init_fact scripts:
--
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\validate_initial_loading.sql
--
-- Every "expect 0" query is an integrity check - a non-zero result
-- means something is wrong. The other queries are eyeball checks
-- against the known shape of the data19_23 dataset.
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

-- Expect 1827 (1,826 days 2019-2023 + the Unknown member)
SELECT COUNT(*) AS total_rows FROM date_dim;

-- Expect 365 / 366 / 365 / 365 / 365 days; holidays > 0 on every year.
-- Zero holidays everywhere means holiday_update.sql never ran.
SELECT cal_year, COUNT(*) AS days,
       SUM(CASE WHEN holiday_ind = 'Y' THEN 1 ELSE 0 END) AS holidays
FROM   date_dim
WHERE  cal_year BETWEEN 2019 AND 2023
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
       13 AS expected FROM dual
UNION ALL SELECT 'supplier_dim',
       (SELECT COUNT(*) FROM supplier_dim),
       (SELECT COUNT(*) FROM supplier), 7               FROM dual
UNION ALL SELECT 'service_dim',
       (SELECT COUNT(*) FROM service_dim),
       (SELECT COUNT(*) FROM service), 18               FROM dual
UNION ALL SELECT 'product_dim',
       (SELECT COUNT(*) FROM product_dim),
       (SELECT COUNT(*) FROM product), 48               FROM dual
UNION ALL SELECT 'staff_dim',
       (SELECT COUNT(*) FROM staff_dim),
       (SELECT COUNT(*) FROM staff), 244                FROM dual
UNION ALL SELECT 'customer_dim',
       (SELECT COUNT(*) FROM customer_dim),
       (SELECT COUNT(*) FROM customer), 25866           FROM dual
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
;

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
-- (util_name lives on branch_utils_fact - there is no utilities dim)
SELECT 'utils unmapped' AS chk, COUNT(*) AS bad FROM branch_utils_fact
  WHERE util_name = 'Unknown'
UNION ALL
SELECT 'service uncategorised', COUNT(*) FROM service_dim
  WHERE serv_category = 'Uncategorised'
UNION ALL
SELECT 'product uncategorised', COUNT(*) FROM product_dim
  WHERE product_category = 'Uncategorised'
UNION ALL
SELECT 'customer unknown state', COUNT(*) FROM customer_dim
  WHERE cus_state = 'Unknown'
UNION ALL
SELECT 'customer unknown age group', COUNT(*) FROM customer_dim
  WHERE cus_age_group = 'Unknown'
UNION ALL
SELECT 'staff unknown position', COUNT(*) FROM staff_dim
  WHERE st_position IS NULL OR st_position = 'Unknown';


-- ###################################################################
-- 4. DIMENSION CONTENT  (eyeball checks)
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  4. DIMENSION CONTENT
PROMPT ##############################################

-- The 6 utility categories (Rent, Electricity, Water, ...) as carried
-- on the fact rows - 6 names, none 'Unknown'
SELECT util_name, COUNT(*) AS payments
FROM   branch_utils_fact GROUP BY util_name ORDER BY util_name;

-- 7 service categories (18 services); add-ons cheap, anti-aging dear
SELECT serv_category, COUNT(*) AS services,
       ROUND(AVG(serv_price), 2) AS avg_price
FROM   service_dim GROUP BY serv_category ORDER BY serv_category;

-- 10 product categories (48 products): Serum 7, Facial Cleanser / Face Cream / Face Mask 6,
-- Toner / Sunscreen 5, Eye Cream 4, Lip Care / Eye Mask / Essential Oil 3
SELECT product_category, COUNT(*) AS products,
       ROUND(AVG(product_unit_price), 2) AS avg_price
FROM   product_dim GROUP BY product_category ORDER BY products DESC;

-- Positions: Beauty Therapist 116, Sales Assistant 39, Cashier 29,
-- Senior Therapist 25, Receptionist 22, Branch Manager 13
SELECT st_position, COUNT(*) AS staff_count
FROM   staff_dim GROUP BY st_position ORDER BY staff_count DESC;

-- Every branch (13) has exactly 1 Branch Manager. staff_dim no longer
-- carries br_ID, so the branch comes from the OLTP staff row.
SELECT s.br_ID, COUNT(*) AS managers
FROM   staff_dim d
JOIN   staff s ON s.st_ID = d.st_ID
WHERE  d.st_position = 'Branch Manager'
GROUP BY s.br_ID ORDER BY s.br_ID;

-- Tiers: Bronze 14493, Silver 7066, Gold 3350, Platinum 1273
SELECT cus_loyalty_tier, COUNT(*) AS customers
FROM   customer_dim GROUP BY cus_loyalty_tier ORDER BY customers DESC;

-- Age groups populated ('Young Adult (18-24)' .. 'Senior (65+)'),
-- none 'Unknown'. Derived from cus_DOB against SYSDATE, so the mix
-- drifts with the calendar.
SELECT cus_age_group, COUNT(*) AS customers
FROM   customer_dim GROUP BY cus_age_group ORDER BY MIN(cus_age_group);


-- ###################################################################
-- 5. FACT ROW COUNTS  (fact must equal source)
-- order_fact is one row per (order, product) and reservation_fact one
-- row per (reservation, service, therapist), so the source side counts
-- DISTINCT groups, not OLTP detail lines: order_detail has 491,657
-- lines, 9,932 of which repeat a product inside the same order.
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  5. FACT ROW COUNTS
PROMPT ##############################################

SELECT 'order_fact' AS fact_table,
       (SELECT COUNT(*) FROM order_fact)   AS fact_rows,
       (SELECT COUNT(*) FROM (SELECT DISTINCT order_ID, product_ID FROM order_detail)) AS source_rows,
       481611 AS expected FROM dual
UNION ALL SELECT 'reservation_fact',
       (SELECT COUNT(*) FROM reservation_fact),
       (SELECT COUNT(*) FROM (SELECT DISTINCT res_ID, serv_ID, st_ID FROM reservation_detail)), 97596 FROM dual
UNION ALL SELECT 'purchase_fact',
       (SELECT COUNT(*) FROM purchase_fact),
       (SELECT COUNT(*) FROM purchase), 33430           FROM dual
UNION ALL SELECT 'salary_payment_fact',
       (SELECT COUNT(*) FROM salary_payment_fact),
       (SELECT COUNT(*) FROM salary_payment), 12103    FROM dual
UNION ALL SELECT 'branch_utils_fact',
       (SELECT COUNT(*) FROM branch_utils_fact),
       (SELECT COUNT(*) FROM branch_utils), 4680        FROM dual
ORDER BY 1;


-- ###################################################################
-- 6. FACT INTEGRITY  (every count must be 0)
-- If a fact loaded short, these say WHICH dimension lookup failed.
-- ###################################################################
PROMPT
PROMPT ##############################################
PROMPT #  6. FACT INTEGRITY - all must be 0
PROMPT ##############################################

-- Rows the staging views themselves rejected (NULL keys in the source).
-- The order / reservation views aggregate lines, so compare the OLTP
-- line count with the SUM of the lines each view row folded in.
SELECT 'order rejected_by_view' AS chk,
       (SELECT COUNT(*) FROM order_detail)
     - (SELECT NVL(SUM(line_count), 0) FROM order_fact_staging_v) AS bad FROM dual
UNION ALL SELECT 'reservation rejected_by_view',
       (SELECT COUNT(*) FROM reservation_detail)
     - (SELECT NVL(SUM(line_count), 0) FROM reservation_fact_staging_v) FROM dual
UNION ALL SELECT 'purchase rejected_by_view',
       (SELECT COUNT(*) FROM purchase)
     - (SELECT COUNT(*) FROM purchase_fact_staging_v) FROM dual
UNION ALL SELECT 'salary rejected_by_view',
       (SELECT COUNT(*) FROM salary_payment)
     - (SELECT COUNT(*) FROM salary_payment_fact_staging_v) FROM dual
UNION ALL SELECT 'utils rejected_by_view',
       (SELECT COUNT(*) FROM branch_utils)
     - (SELECT COUNT(*) FROM branch_utils_fact_staging_v) FROM dual;

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
UNION ALL SELECT 'utils no_date', COUNT(*)
  FROM branch_utils_fact_staging_v ls
  WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                    WHERE d.cal_date = ls.payment_date);

-- No duplicate grain keys in the facts (no UNIQUE constraints exist -
-- the composite PK covers it; the check documents the grain)
SELECT 'order_fact dup (order_ID, product_key)' AS chk, COUNT(*) AS bad FROM (
    SELECT order_ID, product_key FROM order_fact
    GROUP BY order_ID, product_key HAVING COUNT(*) > 1)
UNION ALL SELECT 'reservation_fact dup (res_ID, service_key, staff_key)', COUNT(*) FROM (
    SELECT res_ID, service_key, staff_key FROM reservation_fact
    GROUP BY res_ID, service_key, staff_key HAVING COUNT(*) > 1)
UNION ALL SELECT 'branch_utils_fact dup br_exp_ID', COUNT(*) FROM (
    SELECT br_exp_ID FROM branch_utils_fact
    GROUP BY br_exp_ID HAVING COUNT(*) > 1);

-- Measures reconcile. The fact stores no unit price: the row's price
-- is product_dim.product_unit_price of the version the fact points at,
-- so total = qty * price - discount + tax must hold through that join
-- (qty / discount / tax are already summed over the folded lines).
-- Likewise a service row's price is service_dim.serv_price - the
-- reservation check below holds because every (reservation, service,
-- therapist) group in the data is a single detail line.
SELECT 'order qty*price-disc+tax=total' AS chk, COUNT(*) AS bad
  FROM order_fact f
  JOIN product_dim p ON p.product_key = f.product_key
  WHERE ABS(ROUND(f.order_qty * p.product_unit_price
                  - f.order_discount_amt + f.order_tax_amt, 2)
            - f.order_total_amt) > 0.01
UNION ALL
SELECT 'reservation price-disc+tax=total', COUNT(*)
  FROM reservation_fact f
  JOIN service_dim s ON s.service_key = f.service_key
  WHERE ABS(ROUND(s.serv_price - f.serv_discount_amt + f.serv_tax_amt, 2)
            - f.serv_total_amt) > 0.01
UNION ALL
SELECT 'salary base+bonus-deduct=total', COUNT(*)
  FROM salary_payment_fact
  WHERE ABS(base_amount + bonus_amount - deduction_amount
            - total_amount) > 0.01;

-- Derived reservation columns: start hours 10-19 (from start_time),
-- no negative durations
SELECT MIN(TO_CHAR(start_time, 'HH24')) AS min_hr,
       MAX(TO_CHAR(start_time, 'HH24')) AS max_hr,
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

-- COVID: salons were closed during MCO 1.0 (18 Mar - 3 May 2020) and
-- FMCO (Jun-Aug 2021), so this must return NO ROWS.
SELECT d.cal_year, d.cal_quarter, COUNT(*) AS completed_services
FROM   reservation_fact f
JOIN   date_dim d ON d.date_key = f.date_key
WHERE  f.res_status = 'Completed'
  AND ( (d.cal_date BETWEEN DATE '2020-03-18' AND DATE '2020-05-03')
     OR (d.cal_date BETWEEN DATE '2021-06-01' AND DATE '2021-08-31') )
GROUP BY d.cal_year, d.cal_quarter
ORDER BY 1, 2;

-- Product revenue by year 2019-2023: ~11.04m / 8.43m / 7.27m / 15.69m / 16.69m
-- (the 2022 jump is the e-commerce launch)
-- (revenue = total - tax = qty * price - discount, tax excluded)
SELECT d.cal_year,
       ROUND(SUM(f.order_total_amt - f.order_tax_amt), 2) AS net_revenue,
       COUNT(*) AS order_product_rows
FROM   order_fact f
JOIN   date_dim d ON d.date_key = f.date_key
WHERE  f.order_status = 'Completed'
GROUP BY d.cal_year ORDER BY d.cal_year;

-- Service revenue by year 2019-2023: ~2.43m / 1.53m / 1.13m / 2.77m / 3.08m
-- (revenue = total - tax = price - discount, tax excluded)
SELECT d.cal_year,
       ROUND(SUM(f.serv_total_amt - f.serv_tax_amt), 2) AS net_revenue
FROM   reservation_fact f
JOIN   date_dim d ON d.date_key = f.date_key
WHERE  f.res_status = 'Completed'
GROUP BY d.cal_year ORDER BY d.cal_year;

-- Branch ranking: Petaling Jaya top, Kuala Lumpur second, Ipoh and
-- Melaka at the bottom (Selangor is the biggest state: PJ + Shah Alam +
-- Puchong + Klang + Selayang)
SELECT b.br_city,
       ROUND(SUM(f.order_total_amt - f.order_tax_amt), 2) AS net_revenue
FROM   order_fact f
JOIN   branch_dim b ON b.branch_key = f.branch_key
WHERE  f.order_status = 'Completed'
GROUP BY b.br_city ORDER BY net_revenue DESC;

-- MCO pay cuts: avg base dips in 2020 (and no increment in 2021);
-- bonuses spike (13th month, Raya) but are halved in 2020-2021
SELECT SUBSTR(pay_period, 1, 4) AS yr,
       ROUND(AVG(base_amount), 2)  AS avg_base,
       ROUND(SUM(bonus_amount), 2) AS total_bonus
FROM   salary_payment_fact
GROUP BY SUBSTR(pay_period, 1, 4) ORDER BY yr;

-- Rent rebates: 2020 and 2021 rent dip below the +3 %/yr trend
SELECT SUBSTR(f.billing_period, 1, 4) AS yr,
       ROUND(SUM(f.payment_amount), 2) AS total_rent
FROM   branch_utils_fact f
WHERE  f.util_name = 'Rent'
GROUP BY SUBSTR(f.billing_period, 1, 4) ORDER BY yr;
