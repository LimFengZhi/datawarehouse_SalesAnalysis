-- ===================================================================
-- 99_price_change_2025.sql   (sales_data5)
-- Eight product prices and six service prices change on 1 January 2025.
--
-- WHY THIS SCRIPT EXISTS
--   Same job as data24\99_price_increase_2024.sql, but this time it also
--   moves SERVICE prices - the first time those have changed.
--
--   Run it, then run the SCD2 maintenance dated 2025-01-01 and both
--   product_dim and service_dim gain a new version per changed row:
--       the old price, flagged 'N', ending 2024-12-31
--       the new price, flagged 'Y', starting 2025-01-01
--
--   data25 was generated with these new prices already applied from
--   2025-01-01, so the fact data and the dimensions agree. The eight
--   launch products (49-56, shipped in data25) are new rows, not price
--   changes - load_product_dim_incremental picks them up.
--
-- TWO PRODUCTS RISE FOR THE SECOND TIME
--   4  Salicylic Acid Acne Cleanser   42 -> 48 (2024) -> 54 (2025)
--   16 Peptide Firming Serum         120 -> 135 (2024) -> 149 (2025)
--   Those two end up with THREE rows in product_dim. Orders from
--   2019-2023 still report 42 and 120, 2024 orders report 48 and 135,
--   and 2025 orders report 54 and 149 - each against the rows that
--   actually paid it. That is the whole argument for Type 2.
--
-- WHEN TO RUN IT
--   AFTER loading data25 and BEFORE the SCD2 maintenance run:
--       1. load_all.bat dwh <pw> XE "...\sales_data5\data25"
--       2. @sales_data5\data25\99_price_change_2025.sql      <- you are here
--       3. the subsequent-load execute script for data25
--          (maintain_product_dim_scd2 AND maintain_service_dim_scd2 dated 2025-01-01)
--
-- The numbers below equal PRICE_RISE_2025 / SERVICE_RISE_2025 in gen_sales_data5.py.
-- ===================================================================

SET SERVEROUTPUT ON

-- ---------- before ----------
SELECT product_ID, product_name, product_unit_price AS price_before
FROM   product
WHERE  product_ID IN (4, 13, 16, 20, 26, 31, 43, 46)
ORDER  BY product_ID;
-- expect 48 / 75 / 135 / 78 / 62 / 45 / 52 / 38

SELECT serv_ID, serv_name, serv_price AS price_before
FROM   service
WHERE  serv_ID IN (5, 6, 7, 10, 12, 17)
ORDER  BY serv_ID;
-- expect 330 / 247.50 / 420 / 225 / 195 / 570

-- ---------- products ----------
-- 4  Salicylic Acid Acne Cleanser     48 -> 54   (+12.5 %)  second rise
UPDATE product SET product_unit_price = 54.00 WHERE product_ID = 4;
-- 13 Hyaluronic Acid Serum            75 -> 84   (+12.0 %)
UPDATE product SET product_unit_price = 84.00 WHERE product_ID = 13;
-- 16 Peptide Firming Serum           135 -> 149  (+10.4 %)  second rise
UPDATE product SET product_unit_price = 149.00 WHERE product_ID = 16;
-- 20 Ceramide Barrier Cream           78 -> 88   (+12.8 %)
UPDATE product SET product_unit_price = 88.00 WHERE product_ID = 20;
-- 26 Tinted Sunscreen SPF45           62 -> 69   (+11.3 %)
UPDATE product SET product_unit_price = 69.00 WHERE product_ID = 26;
-- 31 Collagen Sheet Mask (Box of 5)   45 -> 50   (+11.1 %)
UPDATE product SET product_unit_price = 50.00 WHERE product_ID = 31;
-- 43 Collagen Eye Mask (Box of 10)    52 -> 58   (+11.5 %)
UPDATE product SET product_unit_price = 58.00 WHERE product_ID = 43;
-- 46 Tea Tree Essential Oil           38 -> 42   (+10.5 %)
UPDATE product SET product_unit_price = 42.00 WHERE product_ID = 46;

-- ---------- services ----------
-- 5  HydraFacial                     330 -> 367.50  (+11.4 %)
UPDATE service SET serv_price = 367.50 WHERE serv_ID = 5;
-- 6  Hydrating Glow Facial        247.50 -> 277.50  (+12.1 %)
UPDATE service SET serv_price = 277.50 WHERE serv_ID = 6;
-- 7  Anti Aging Collagen Facial      420 -> 465.00  (+10.7 %)
UPDATE service SET serv_price = 465.00 WHERE serv_ID = 7;
-- 10 Vitamin C Brightening Facial    225 -> 252.00  (+12.0 %)
UPDATE service SET serv_price = 252.00 WHERE serv_ID = 10;
-- 12 Acne Clear Facial               195 -> 217.50  (+11.5 %)
UPDATE service SET serv_price = 217.50 WHERE serv_ID = 12;
-- 17 Microneedling Rejuvenation      570 -> 630.00  (+10.5 %)
UPDATE service SET serv_price = 630.00 WHERE serv_ID = 17;

COMMIT;

-- ---------- after ----------
SELECT product_ID, product_name, product_unit_price AS price_after
FROM   product
WHERE  product_ID IN (4, 13, 16, 20, 26, 31, 43, 46)
ORDER  BY product_ID;
-- expect 54 / 84 / 149 / 88 / 69 / 50 / 58 / 42

SELECT serv_ID, serv_name, serv_price AS price_after
FROM   service
WHERE  serv_ID IN (5, 6, 7, 10, 12, 17)
ORDER  BY serv_ID;
-- expect 367.50 / 277.50 / 465 / 252 / 217.50 / 630


-- ===================================================================
-- NEXT: turn the change into dimension history
-- ===================================================================
-- The data25 execute script must carry the 2025 dates:
--
--   EXEC load_date_dim_incremental(2025);
--   EXEC load_supplier_dim_incremental;             -- supplier 8 (HIM Care Labs)
--   EXEC load_product_dim_incremental;              -- products 49-56 (men's line + 2 masks)
--   EXEC maintain_product_dim_scd2(DATE '2025-01-01');
--   EXEC maintain_service_dim_scd2(DATE '2025-01-01');
--   EXEC load_order_fact_incremental(DATE '2025-01-01');
--   ... and the other facts from DATE '2025-01-01'
--
-- Then confirm the versions landed on the right dates:
--
-- SELECT product_key, product_ID, product_name, product_unit_price,
--        effective_start_date, effective_end_date, is_current_flag
-- FROM   product_dim
-- WHERE  product_ID IN (4, 16)
-- ORDER  BY product_ID, product_key;
-- -- expect 3 rows each:
-- --   42.00 / 120.00  flagged 'N', ending 2023-12-31
-- --   48.00 / 135.00  flagged 'N', 2024-01-01 to 2024-12-31
-- --   54.00 / 149.00  flagged 'Y', from 2025-01-01
-- -- end state: product_dim 72 rows = 56 current + 16 expired,
-- --            service_dim  24 rows = 18 current + 6 expired
--
-- And the payoff - one product, three prices, each against the order
-- rows that actually paid it:
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
