-- ===================================================================
-- 99_price_increase_2024.sql   (sales_data5)
-- Eight product prices rise on 1 January 2024 - the FIRST SCD2 test case
-- of revision 5.
--
-- WHY THIS SCRIPT EXISTS
--   The CSVs carry no unit price on an order line. Every line is priced
--   at the PRODUCT's price in force on the order date, i.e. the
--   product_dim version whose effective range contains orders.order_date.
--   The OLTP product table holds only the CURRENT price, so the change
--   has to be applied there and then turned into dimension history:
--       run this script, then run maintain_product_dim_scd2(DATE '2024-01-01')
--   and product_dim gains a new version per changed product:
--       the old price, flagged 'N', ending 2023-12-31
--       the new price, flagged 'Y', starting 2024-01-01
--
--   data24 was generated with these prices already applied from
--   2024-01-01 (and data19_23 with the old ones), so the fact data and
--   the dimensions agree. Products 4 and 16 rise AGAIN on 2025-01-01
--   (see data25\99_price_change_2025.sql) - three versions each.
--
-- WHEN TO RUN IT
--   AFTER loading data24 and BEFORE the SCD2 maintenance run:
--       1. load_all.bat dwh <pw> XE "...\sales_data5\data24"
--       2. @sales_data5\data24\99_price_increase_2024.sql    <- you are here
--       3. the subsequent-load execute script for data24
--          (its STEP 2 must call maintain_product_dim_scd2(DATE '2024-01-01'))
--
-- The numbers below equal PRICE_RISE_2024 in gen_sales_data5.py.
-- Written for plain SQL*Plus: one statement per line, comments above.
-- ===================================================================

SET SERVEROUTPUT ON

-- ---------- before ----------
SELECT product_ID, product_name, product_unit_price AS price_before
FROM   product
WHERE  product_ID IN (4, 12, 15, 16, 22, 25, 32, 36)
ORDER  BY product_ID;
-- expect 42 / 89 / 110 / 120 / 95 / 55 / 72 / 68

-- ---------- the rise (+10..15 % on eight of the best sellers) ----------
-- 4  Salicylic Acid Acne Cleanser     42 -> 48   (+14.3 %)
UPDATE product SET product_unit_price = 48.00 WHERE product_ID = 4;
-- 12 Vitamin C Brightening Serum      89 -> 98   (+10.1 %)
UPDATE product SET product_unit_price = 98.00 WHERE product_ID = 12;
-- 15 Retinol Renewal Serum           110 -> 125  (+13.6 %)
UPDATE product SET product_unit_price = 125.00 WHERE product_ID = 15;
-- 16 Peptide Firming Serum           120 -> 135  (+12.5 %)
UPDATE product SET product_unit_price = 135.00 WHERE product_ID = 16;
-- 22 Collagen Youth Cream             95 -> 108  (+13.7 %)
UPDATE product SET product_unit_price = 108.00 WHERE product_ID = 22;
-- 25 SPF50 Daily Sunscreen Lotion     55 -> 62   (+12.7 %)
UPDATE product SET product_unit_price = 62.00 WHERE product_ID = 25;
-- 32 Hydrating Sleeping Mask (Jar)    72 -> 82   (+13.9 %)
UPDATE product SET product_unit_price = 82.00 WHERE product_ID = 32;
-- 36 Collagen Eye Cream               68 -> 76   (+11.8 %)
UPDATE product SET product_unit_price = 76.00 WHERE product_ID = 36;

COMMIT;

-- ---------- after ----------
SELECT product_ID, product_name, product_unit_price AS price_after
FROM   product
WHERE  product_ID IN (4, 12, 15, 16, 22, 25, 32, 36)
ORDER  BY product_ID;
-- expect 48 / 98 / 125 / 135 / 108 / 62 / 82 / 76


-- ===================================================================
-- NEXT: turn the change into dimension history
-- ===================================================================
-- The data24 execute script must carry the 2024 dates (the facts
-- auto-detect their own START; the argument is only the window END):
--
--   EXEC load_date_dim_incremental(DATE '2024-12-31');
--   EXEC maintain_product_dim_scd2(DATE '2024-01-01');
--   EXEC load_order_fact_incremental(DATE '2024-12-31');
--   ... and the other facts, same end date
--
-- Then confirm the versions landed on the right date:
--
-- SELECT product_key, product_ID, product_name, product_unit_price,
--        effective_start_date, effective_end_date, is_current_flag
-- FROM   product_dim
-- WHERE  product_ID IN (4, 12, 15, 16, 22, 25, 32, 36)
-- ORDER  BY product_ID, product_key;
-- -- expect 16 rows: 8 flagged 'N' ending 2023-12-31 (the old price),
-- --                 8 flagged 'Y' starting 2024-01-01 (the new price)
--
-- And the payoff - one product, two prices, each against the order
-- lines that actually paid it:
--
-- SELECT p.product_unit_price, p.is_current_flag,
--        MIN(d.cal_date) AS first_sold, MAX(d.cal_date) AS last_sold,
--        COUNT(*) AS order_rows
-- FROM   order_fact  f
-- JOIN   product_dim p ON p.product_key = f.product_key
-- JOIN   date_dim    d ON d.date_key    = f.date_key
-- WHERE  p.product_ID = 16
-- GROUP  BY p.product_unit_price, p.is_current_flag
-- ORDER  BY first_sold;
