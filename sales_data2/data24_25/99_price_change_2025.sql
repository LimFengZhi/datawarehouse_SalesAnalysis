-- ===================================================================
-- 99_price_change_2025.sql
-- Eight product prices and six service prices change on 1 January 2025.
--
-- WHY THIS SCRIPT EXISTS
--   Same job as data22_23\99_price_increase_2023.sql, but this time it
--   also moves SERVICE prices - the first time those have changed.
--
--   Run it, then run the SCD2 maintenance dated 2025-01-01 and both
--   product_dim and service_dim gain a new version per changed row:
--       the old price, flagged 'N', ending 2024-12-31
--       the new price, flagged 'Y', starting 2025-01-01
--
--   data24_25 was generated with these new prices already applied from
--   2025-01-01, so the fact data and the dimensions agree.
--
-- TWO PRODUCTS RISE FOR THE SECOND TIME
--   4  Salicylic Acid Acne Cleanser   42 -> 48 (2023) -> 54 (2025)
--   16 Peptide Firming Serum         120 -> 135 (2023) -> 149 (2025)
--   Those two end up with THREE rows in product_dim. Orders from
--   2018-2022 still report 42 and 120, orders from 2023-2024 report
--   48 and 135, and 2025 orders report 54 and 149 - each against the
--   lines that actually paid it. That is the whole argument for Type 2.
--
-- WHEN TO RUN IT
--   AFTER loading data24_25 (its 2025 lines carry the new prices, the
--   2024 lines the old ones), and BEFORE
--   the SCD2 maintenance run.
--
--       1. load_all.bat dwh <pw> XE "...\sales_data2\data24_25"
--       2. @sales_data2\data24_25\99_price_change_2025.sql     <- you are here
--       3. @ETL_Process\subsequent_loading\execute_sub2.sql
--          (already set to 2025 - see the bottom of this file)
-- ===================================================================

SET SERVEROUTPUT ON

-- ---------- before ----------
SELECT product_ID, product_name, product_unit_price AS price_before
FROM   product
WHERE  product_ID IN (4, 13, 16, 19, 24, 28, 36, 45)
ORDER  BY product_ID;

SELECT serv_ID, serv_name, serv_price AS price_before
FROM   service
WHERE  serv_ID IN (5, 6, 7, 10, 12, 17)
ORDER  BY serv_ID;


-- ---------- products ----------
UPDATE product SET product_unit_price =  54.00 WHERE product_ID =  4;  -- Salicylic Acid Acne Cleanser   48 ->  54  (+12.5%)  2nd rise
UPDATE product SET product_unit_price =  84.00 WHERE product_ID = 13;  -- Hyaluronic Acid Serum          75 ->  84  (+12.0%)
UPDATE product SET product_unit_price = 149.00 WHERE product_ID = 16;  -- Peptide Firming Serum         135 -> 149  (+10.4%)  2nd rise
UPDATE product SET product_unit_price =  88.00 WHERE product_ID = 19;  -- Ceramide Barrier Cream         78 ->  88  (+12.8%)
UPDATE product SET product_unit_price =  69.00 WHERE product_ID = 24;  -- Tinted Sunscreen SPF45         62 ->  69  (+11.3%)
UPDATE product SET product_unit_price =  50.00 WHERE product_ID = 28;  -- Collagen Sheet Mask (Box of 5) 45 ->  50  (+11.1%)
UPDATE product SET product_unit_price =  72.00 WHERE product_ID = 36;  -- AHA/BHA Exfoliating Solution   65 ->  72  (+10.8%)
UPDATE product SET product_unit_price = 105.00 WHERE product_ID = 45;  -- Azelaic Acid Clarifying Serum  95 -> 105  (+10.5%)  launched 2023

-- ---------- services ----------
UPDATE service SET serv_price = 245.00 WHERE serv_ID =  5;  -- HydraFacial                  220 -> 245  (+11.4%)
UPDATE service SET serv_price = 185.00 WHERE serv_ID =  6;  -- Hydrating Glow Facial        165 -> 185  (+12.1%)
UPDATE service SET serv_price = 310.00 WHERE serv_ID =  7;  -- Anti Aging Collagen Facial   280 -> 310  (+10.7%)
UPDATE service SET serv_price = 168.00 WHERE serv_ID = 10;  -- Vitamin C Brightening Facial 150 -> 168  (+12.0%)
UPDATE service SET serv_price = 145.00 WHERE serv_ID = 12;  -- Acne Clear Facial            130 -> 145  (+11.5%)
UPDATE service SET serv_price = 420.00 WHERE serv_ID = 17;  -- Microneedling Rejuvenation   380 -> 420  (+10.5%)  launched 2023

COMMIT;


-- ---------- after ----------
SELECT product_ID, product_name, product_unit_price AS price_after
FROM   product
WHERE  product_ID IN (4, 13, 16, 19, 24, 28, 36, 45)
ORDER  BY product_ID;
-- expect 54 / 84 / 149 / 88 / 69 / 50 / 72 / 105

SELECT serv_ID, serv_name, serv_price AS price_after
FROM   service
WHERE  serv_ID IN (5, 6, 7, 10, 12, 17)
ORDER  BY serv_ID;
-- expect 245 / 185 / 310 / 168 / 145 / 420


-- ===================================================================
-- NEXT: turn the change into dimension history
-- ===================================================================
-- Run ETL_Process\subsequent_loading\execute_sub2.sql - it carries the
-- 2025 dates:
--
--   EXEC load_date_dim_incremental(2025);
--   EXEC maintain_product_dim_scd2(DATE '2025-01-01');
--   EXEC maintain_service_dim_scd2(DATE '2025-01-01');
--   EXEC load_order_fact_incremental(DATE '2025-01-01');
--   ... and the other facts
--
-- Then confirm the versions landed on the right dates:
--
-- SELECT product_key, product_ID, product_name, product_unit_price,
--        effective_start_date, effective_end_date, is_current_flag
-- FROM   product_dim
-- WHERE  product_ID IN (4, 16)
-- ORDER  BY product_ID, product_key;
-- -- expect 3 rows each:
-- --   42.00 / 120.00  flagged 'N', ending 2022-12-31
-- --   48.00 / 135.00  flagged 'N', 2023-01-01 to 2024-12-31
-- --   54.00 / 149.00  flagged 'Y', from 2025-01-01
--
-- And the payoff - one product, three prices, each against the order
-- lines that actually paid it:
--
-- SELECT p.product_unit_price, p.is_current_flag,
--        MIN(d.cal_date) AS first_sold, MAX(d.cal_date) AS last_sold,
--        COUNT(*) AS order_lines
-- FROM   order_fact  f
-- JOIN   product_dim p ON p.product_key = f.product_key
-- JOIN   date_dim    d ON d.date_key    = f.date_key
-- WHERE  p.product_ID = 16
-- GROUP  BY p.product_unit_price, p.is_current_flag
-- ORDER  BY first_sold;
-- ===================================================================
