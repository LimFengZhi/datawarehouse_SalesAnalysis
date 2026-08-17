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
-- SECTION 1: STAGING VIEW - reuses product_staging_v from
--   ETL_Process\initial_loading\init_dimension\05_init_product_dim.sql
--
-- SECTION 2: SEQUENCE - reuses seq_product_key, continuing from
-- wherever the last load left it.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_product_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
BEGIN
    INSERT INTO product_dim (
        product_key, product_ID, product_name,
        product_category, product_unit_price,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_product_key.NEXTVAL,
        s.product_ID, s.clean_product_name,
        s.clean_product_category, s.clean_product_price,
        DATE '2018-01-01',   -- first version: start of recorded history
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