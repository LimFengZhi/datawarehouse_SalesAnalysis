-- ===================================================================
-- 02_maintain_product_dim.sql    PRODUCT_DIM - MAINTAIN SCD TYPE 2
--
--   SECTION 1: no new view - reuses product_staging_v
--   SECTION 2: no new sequence - reuses seq_product_key
--   SECTION 3: PROCEDURE - cursor FOR-loop: expire changed rows,
--              insert new versions
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: CHANGED RECORDS ONLY. New products belong to
--   sub_dimension\03_sub_product_dim.sql
--
-- WHY THIS MATTERS HERE MORE THAN ANYWHERE ELSE:
-- when a price changes, orders placed BEFORE the change keep pointing
-- at the old product_key and therefore the old price. Type 1 would
-- overwrite the price and retroactively rewrite the value of every
-- historical order line.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_product_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff      DATE   := TRUNC(p_effective_date);
    v_expired  NUMBER := 0;
    v_versions NUMBER := 0;
    -- ---------------------------------------------------------------
    -- ONE cursor drives both steps: each fetched row is a product
    -- whose CURRENT version differs from the staging view. The change
    -- test lives INSIDE the cursor query, so a second run fetches
    -- nothing - that is what keeps this idempotent. The surrogate key
    -- rides along so STEP 1 can expire exactly that row. A brand-new
    -- product_ID has no current row to join, so it is naturally excluded -
    -- inserting it is sub_dimension's job.
    --
    -- NVL on BOTH sides: NULL <> 'x' is UNKNOWN, not TRUE, so a bare
    -- <> would silently miss changes involving NULL.
    -- Price uses NVL(...,-1): it is a NUMBER, and a string sentinel in
    -- a numeric comparison would raise ORA-01722.
    -- ---------------------------------------------------------------
    CURSOR changed_products_cursor IS
        SELECT d.product_key AS old_key,
               s.product_ID, s.clean_product_name,
               s.clean_product_category, s.clean_product_price
        FROM   product_staging_v s
        JOIN   product_dim d ON d.product_ID = s.product_ID
                      AND d.is_current_flag = 'Y'
        -- Never version BACKWARDS: expiring a version that starts on
        -- or after the effective date would corrupt the timeline
        -- (overlapping ranges). A backdated call fetches nothing and
        -- becomes a safe no-op.
        WHERE  d.effective_start_date < v_eff
        AND   (   NVL(s.clean_product_name, '~')
                    <> NVL(d.product_name, '~')
               OR NVL(s.clean_product_category, '~')
                    <> NVL(d.product_category, '~')
               OR NVL(s.clean_product_price, -1)
                    <> NVL(d.product_unit_price, -1) );
BEGIN
    FOR rec IN changed_products_cursor LOOP
        -- -----------------------------------------------------------
        -- STEP 1: expire the old current version (ends yesterday,
        -- never before its own start date).
        -- -----------------------------------------------------------
        UPDATE product_dim
        SET    effective_end_date = GREATEST(v_eff - 1,
                                             effective_start_date),
               is_current_flag    = 'N'
        WHERE  product_key = rec.old_key;
        v_expired := v_expired + 1;

        -- -----------------------------------------------------------
        -- STEP 2: insert the replacement version, current from v_eff.
        -- Both statements sit in ONE loop pass, so every expired row
        -- gets its replacement - the two counts cannot drift apart.
        -- -----------------------------------------------------------
        INSERT INTO product_dim (
            product_key, product_ID, product_name,
            product_category, product_unit_price,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_product_key.NEXTVAL,
            rec.product_ID, rec.clean_product_name,
            rec.clean_product_category, rec.clean_product_price,
            v_eff,
            DATE '9999-12-31',
            'Y'
        );
        v_versions := v_versions + 1;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('PRODUCT_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in PRODUCT_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/
