-- ===================================================================
-- 03_sub_product_dim.sql    PRODUCT_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses product_staging_v
--   SECTION 2: no new sequence - reuses seq_product_key
--   SECTION 3: PROCEDURE - cursor FOR-loop inserts new records only
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: NEW RECORDS ONLY - a product added to the range (e.g. the
-- 2025 men's line, products 49-56) is inserted. A price or category
-- change on an EXISTING product is NOT handled here - that is THE
-- SCD Type 2 case of this warehouse and belongs to the maintain step.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_product_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
    -- The NOT EXISTS anti-join lives INSIDE the cursor query, so a
    -- second run fetches nothing - that is what keeps this idempotent.
    -- Cursor FOR-loop is the deliberate idiom for the small dimension
    -- loads; set-based DML stays where volume demands it (the facts).
    CURSOR new_products_cursor IS
        SELECT s.*
        FROM   product_staging_v s
        WHERE  NOT EXISTS (SELECT 1 FROM product_dim d
                           WHERE d.product_ID = s.product_ID);
BEGIN
    FOR rec IN new_products_cursor LOOP
        INSERT INTO product_dim (
            product_key, product_ID, product_name,
            product_category, product_unit_price,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_product_key.NEXTVAL,
            rec.product_ID, rec.clean_product_name,
            rec.clean_product_category, rec.clean_product_price,
            DATE '2019-01-01',
            DATE '9999-12-31',
            'Y'
        );
        v_new := v_new + 1;
    END LOOP;

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