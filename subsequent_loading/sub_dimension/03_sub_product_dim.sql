-- ===================================================================
-- 03_sub_product_dim.sql    PRODUCT_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses product_staging_v
--   SECTION 2: no new sequence - reuses seq_product_key
--   SECTION 3: PROCEDURE - insert new records only
--   SECTION 4: run + verification
--
-- SCOPE: NEW RECORDS ONLY. A product launched since the last load gets
-- a surrogate key and is added, automatically.
--
-- A PRICE CHANGE ON AN EXISTING PRODUCT IS NOT PICKED UP HERE. That is
-- SCD Type 2 and belongs to the separate maintain-SCD2 step, which is
-- where the effective_start_date / effective_end_date /
-- is_current_flag columns start doing real work. This script just
-- populates them with sensible defaults on insert.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - REUSED, NOT RECREATED
-- product_staging_v is defined in
--   initialLoading\init_dimension\05_init_product_dim.sql
-- It canonicalises the 7 brands and 10 categories and floors negative
-- prices at 0.
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - REUSED, NOT RECREATED
-- seq_product_key already issued keys 2000..2042. It continues at 2043.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_product_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
BEGIN
    INSERT INTO product_dim (
        product_key, product_ID, product_name, product_brand,
        product_category, product_unit_price,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_product_key.NEXTVAL,
        s.product_ID, s.clean_product_name, s.clean_product_brand,
        s.clean_product_category, s.clean_product_price,
        DATE '2019-01-01',   -- first version: start of recorded history
        DATE '9999-12-31',
        'Y'
    FROM   product_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM product_dim d
                       WHERE d.product_ID = s.product_ID);

    v_new := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_total FROM product_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('PRODUCT_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New products inserted  : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Already present        : '
        || (v_total - v_new));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in PRODUCT_DIM subsequent load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
-- Procedure created above. The EXEC now lives in the folder runner
--   00_run_all_sub_dimensions.sql
-- so every call and its arguments sit in ONE place.
--   EXEC load_product_dim_incremental;

-- One row per natural key. Must return no rows.
SELECT product_ID, COUNT(*) AS rows_per_key
FROM   product_dim
GROUP BY product_ID HAVING COUNT(*) > 1;

-- Category mix should still show 10 categories, none 'Uncategorised'
SELECT product_category, COUNT(*) AS products
FROM   product_dim
GROUP BY product_category
ORDER BY products DESC;

-- Every OLTP product is represented
SELECT COUNT(*) AS missing_from_dim
FROM   product p
WHERE  NOT EXISTS (SELECT 1 FROM product_dim d
                   WHERE d.product_ID = p.product_ID);
-- expect 0

-- Facts must still resolve
SELECT COUNT(*) AS orphaned_facts
FROM   order_fact f
WHERE  NOT EXISTS (SELECT 1 FROM product_dim d
                   WHERE d.product_key = f.product_key);
-- expect 0

-- ---------- END-TO-END TEST (optional, run by hand) ----------
-- 1. add a product, then run the procedure: expect 1 inserted
--
-- INSERT INTO product (product_ID, product_name, product_brand,
--                      product_category, product_unit_price)
-- VALUES (9001, 'Test Serum', 'PureGlow', 'Serum', 99.00);
-- COMMIT;
-- EXEC load_product_dim_incremental;
-- SELECT product_key, product_name FROM product_dim WHERE product_ID = 9001;
--
-- 2. change its price and run again. Expect 0 inserted and the price
--    in the dimension STILL 99.00 - by design. Handling that change is
--    the maintain-SCD2 step's job, not this one.
--
-- UPDATE product SET product_unit_price = 120.00 WHERE product_ID = 9001;
-- COMMIT;
-- EXEC load_product_dim_incremental;
-- SELECT product_unit_price FROM product_dim WHERE product_ID = 9001;
--
-- 3. clean up
-- DELETE FROM product_dim WHERE product_ID = 9001;
-- DELETE FROM product     WHERE product_ID = 9001;
-- COMMIT;
