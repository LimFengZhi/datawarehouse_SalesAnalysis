-- ===================================================================
-- 99_price_increase_2023.sql
-- Seven products get a price rise effective 1 January 2023.
--
-- WHY THIS SCRIPT EXISTS
--   It is the trigger for SCD Type 2. Run it, then run
--   maintain_product_dim_scd2(DATE '2023-01-01') and product_dim ends
--   up with TWO rows for each of these seven products:
--       the old price, flagged 'N', ending 2022-12-31
--       the new price, flagged 'Y', starting 2023-01-01
--
--   Orders from 2018-2022 keep pointing at the OLD product_key and so
--   still report the old price. Orders from 2023 onward point at the
--   new one. That is the whole argument for Type 2 over Type 1 - with
--   Type 1 the price would be overwritten and five years of history
--   would silently change value.
--
--   data22_23 was generated with these new prices already applied from
--   2023-01-01, so the fact data and the dimension agree.
--
-- WHEN TO RUN IT
--   AFTER loading data22_23 (its 2023 lines carry the new prices, the
--   2022 lines the old ones), and BEFORE
--   the SCD2 maintenance run.
--
--       1. load_all.bat dwh <pw> XE "...\sales_data2\data22_23"
--       2. @sales_data2\data22_23\99_price_increase_2023.sql   <- you are here
--       3. @ETL_Process\subsequent_loading\execute_sub_procedure.sql
--          (its STEP 2 runs maintain_product_dim_scd2(DATE '2023-01-01'))
-- ===================================================================

SET SERVEROUTPUT ON

-- ---------- before ----------
SELECT product_ID, product_name, product_unit_price AS price_before
FROM   product
WHERE  product_ID IN (4, 12, 15, 16, 21, 23, 30)
ORDER BY product_ID;

-- ---------- the rise ----------
-- Chosen from the top sellers, so the effect shows up in the revenue
-- analysis rather than hiding in the tail.
UPDATE product SET product_unit_price =  48.00 WHERE product_ID =  4;  -- Salicylic Acid Acne Cleanser   42 -> 48  (+14.3%)
UPDATE product SET product_unit_price =  98.00 WHERE product_ID = 12;  -- Vitamin C Brightening Serum    89 -> 98  (+10.1%)
UPDATE product SET product_unit_price = 125.00 WHERE product_ID = 15;  -- Retinol Renewal Serum         110 -> 125 (+13.6%)
UPDATE product SET product_unit_price = 135.00 WHERE product_ID = 16;  -- Peptide Firming Serum         120 -> 135 (+12.5%)
UPDATE product SET product_unit_price = 108.00 WHERE product_ID = 21;  -- Collagen Youth Cream           95 -> 108 (+13.7%)
UPDATE product SET product_unit_price =  62.00 WHERE product_ID = 23;  -- SPF50 Daily Sunscreen Lotion   55 -> 62  (+12.7%)
UPDATE product SET product_unit_price =  82.00 WHERE product_ID = 30;  -- Hydrating Sleeping Mask (Jar)  72 -> 82  (+13.9%)

COMMIT;

-- ---------- after ----------
SELECT product_ID, product_name, product_unit_price AS price_after
FROM   product
WHERE  product_ID IN (4, 12, 15, 16, 21, 23, 30)
ORDER BY product_ID;
-- expect 48 / 98 / 125 / 135 / 108 / 62 / 82


-- ===================================================================
-- NEXT: turn the change into dimension history
-- ===================================================================
-- EXEC maintain_product_dim_scd2(DATE '2023-01-01');
--
-- Then confirm two versions per product, split on the right date:
--
-- SELECT product_key, product_ID, product_name, product_unit_price,
--        effective_start_date, effective_end_date, is_current_flag
-- FROM   product_dim
-- WHERE  product_ID IN (4, 12, 15, 16, 21, 23, 30)
-- ORDER  BY product_ID, product_key;
-- -- expect 14 rows: 7 flagged 'N' ending 2022-12-31,
-- --                 7 flagged 'Y' starting 2023-01-01
--
-- And the payoff - the same product reporting two prices, each against
-- the orders that actually paid it:
--
-- SELECT p.product_name, p.product_unit_price, p.is_current_flag,
--        MIN(d.cal_date) AS first_sold, MAX(d.cal_date) AS last_sold,
--        COUNT(*) AS order_lines
-- FROM   order_fact f
-- JOIN   product_dim p ON p.product_key = f.product_key
-- JOIN   date_dim    d ON d.date_key    = f.date_key
-- WHERE  p.product_ID = 16
-- GROUP  BY p.product_name, p.product_unit_price, p.is_current_flag
-- ORDER  BY first_sold;
-- -- expect the 120.00 version to stop at 2022-12-31 and the 135.00
-- -- version to start at 2023-01-01
-- ===================================================================
