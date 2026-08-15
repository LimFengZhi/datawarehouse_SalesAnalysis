-- ===================================================================
-- 02_maintain_product_dim.sql    PRODUCT_DIM - MAINTAIN SCD TYPE 2
--
--   SECTION 1: no new view - reuses product_staging_v
--   SECTION 2: no new sequence - reuses seq_product_key
--   SECTION 3: PROCEDURE - expire changed rows, insert new versions
--   SECTION 4: run + verification
--
-- SCOPE: CHANGED RECORDS ONLY. New products belong to
--   subsequentLoading\sub_dimension\03_sub_product_dim.sql
--
-- WHY THIS MATTERS HERE MORE THAN ANYWHERE ELSE:
-- when a price changes, orders placed BEFORE the change keep pointing
-- at the old product_key and therefore the old price. Type 1 would
-- overwrite the price and retroactively rewrite the value of every
-- historical order line.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - REUSED, NOT RECREATED
-- product_staging_v is defined in
--   initialLoading\init_dimension\05_init_product_dim.sql
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - REUSED, NOT RECREATED
-- seq_product_key continues from wherever the last load left it.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_product_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff      DATE   := TRUNC(p_effective_date);
    v_expired  NUMBER := 0;
    v_versions NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: expire changed products.
    -- Price uses NVL(...,-1), not NVL(...,'~') - it is a NUMBER, and
    -- mixing a string default into a numeric comparison raises
    -- ORA-01722.
    -- ---------------------------------------------------------------
    UPDATE product_dim d
    SET    d.effective_end_date = GREATEST(v_eff - 1,
                                           d.effective_start_date),
           d.is_current_flag    = 'N'
    WHERE  d.is_current_flag = 'Y'
    AND EXISTS (
        SELECT 1
        FROM   product_staging_v s
        WHERE  s.product_ID = d.product_ID
          AND (   NVL(s.clean_product_name, '~')
                    <> NVL(d.product_name, '~')
               OR NVL(s.clean_product_brand, '~')
                    <> NVL(d.product_brand, '~')
               OR NVL(s.clean_product_category, '~')
                    <> NVL(d.product_category, '~')
               OR NVL(s.clean_product_price, -1)
                    <> NVL(d.product_unit_price, -1) ));

    v_expired := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: new version for each product STEP 1 expired.
    -- The EXISTS test keeps brand-new products out - they are
    -- sub_dimension's responsibility.
    -- ---------------------------------------------------------------
    INSERT INTO product_dim (
        product_key, product_ID, product_name, product_brand,
        product_category, product_unit_price,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_product_key.NEXTVAL,
        s.product_ID, s.clean_product_name, s.clean_product_brand,
        s.clean_product_category, s.clean_product_price,
        v_eff,
        DATE '9999-12-31',
        'Y'
    FROM   product_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM product_dim d
                       WHERE d.product_ID = s.product_ID
                         AND d.is_current_flag = 'Y')
    AND    EXISTS     (SELECT 1 FROM product_dim d
                       WHERE d.product_ID = s.product_ID);

    v_versions := SQL%ROWCOUNT;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('PRODUCT_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);

    IF v_expired <> v_versions THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: expired and inserted counts '
            || 'differ - run the integrity checks in SECTION 4.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in PRODUCT_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
-- No argument -> the change is dated TODAY (SYSDATE).
-- Procedure created above. The EXEC now lives in the folder runner
--   00_run_all_maintain_scd2.sql
-- so every call and its arguments sit in ONE place.
--   EXEC maintain_product_dim_scd2;

-- Or date it to when the change ACTUALLY happened. The old version is
-- closed the day before, the new one opens on that date:
--     EXEC maintain_product_dim_scd2(DATE '2024-07-01');

-- Exactly ONE current row per natural key. Must return no rows.
SELECT product_ID, COUNT(*) AS current_versions
FROM   product_dim
WHERE  is_current_flag = 'Y'
GROUP BY product_ID HAVING COUNT(*) <> 1;

-- Price history for anything that changed
SELECT product_key, product_ID, product_name, product_unit_price,
       effective_start_date, effective_end_date, is_current_flag
FROM   product_dim
WHERE  product_ID IN (SELECT product_ID FROM product_dim
                      GROUP BY product_ID HAVING COUNT(*) > 1)
ORDER BY product_ID, product_key;

-- No expired row may still claim 9999-12-31
SELECT COUNT(*) AS bad_end_dates FROM product_dim
WHERE  is_current_flag = 'N' AND effective_end_date = DATE '9999-12-31';
-- expect 0

-- Existing facts must NOT be orphaned: they keep pointing at the OLD
-- product_key, which still exists. That is the point of Type 2.
SELECT COUNT(*) AS orphaned_facts
FROM   order_fact f
WHERE  NOT EXISTS (SELECT 1 FROM product_dim d
                   WHERE d.product_key = f.product_key);
-- expect 0

-- ---------- END-TO-END TEST (optional, run by hand) ----------
-- Assumes product 9001 already exists in BOTH product and product_dim
-- (add it with sub_dimension\03_sub_product_dim.sql first).
--
-- UPDATE product SET product_unit_price = 120.00 WHERE product_ID = 9001;
-- COMMIT;
-- -- No argument -> the change is dated TODAY (SYSDATE).
--   EXEC maintain_product_dim_scd2;

-- Or date it to when the change ACTUALLY happened. The old version is
-- closed the day before, the new one opens on that date:
--     EXEC maintain_product_dim_scd2(DATE '2024-07-01');      -- expect 1 expired, 1 version
--
-- SELECT product_key, product_unit_price, effective_start_date,
--        effective_end_date, is_current_flag
-- FROM   product_dim WHERE product_ID = 9001 ORDER BY product_key;
-- -- expect 2 rows: 99.00 flagged 'N', 120.00 flagged 'Y'
