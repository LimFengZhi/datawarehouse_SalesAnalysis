-- ===================================================================
-- 01_maintain_supplier_dim.sql   SUPPLIER_DIM - MAINTAIN SCD TYPE 2
--
--   SECTION 1: no new view - reuses supplier_staging_v
--   SECTION 2: no new sequence - reuses seq_supplier_key
--   SECTION 3: PROCEDURE - cursor FOR-loop: expire changed rows,
--              insert new versions
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: CHANGED RECORDS ONLY.
--   STEP 1  expire the current row of any supplier whose attributes
--           changed  (effective_end_date = yesterday, flag = 'N')
--   STEP 2  insert a new current version for exactly those suppliers
--
-- BRAND-NEW suppliers are NOT inserted here - that is the job of
-- sub_dimension\02_sub_supplier_dim.sql. The two steps are orthogonal:
--     sub_dimension  -> natural keys that do not exist yet
--     maintain_SCD2  -> natural keys that exist and changed
-- Run sub_dimension FIRST, then this.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_supplier_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff      DATE   := TRUNC(p_effective_date);
    v_expired  NUMBER := 0;
    v_versions NUMBER := 0;
    -- ---------------------------------------------------------------
    -- ONE cursor drives both steps: each fetched row is a supplier
    -- whose CURRENT version differs from the staging view. The change
    -- test lives INSIDE the cursor query, so a second run fetches
    -- nothing - that is what keeps this idempotent. The surrogate key
    -- rides along so STEP 1 can expire exactly that row. A brand-new
    -- sup_ID has no current row to join, so it is naturally excluded -
    -- inserting it is sub_dimension's job.
    --
    -- NVL on BOTH sides: NULL <> 'x' is UNKNOWN, not TRUE, so a bare
    -- <> would silently miss changes involving NULL.
    -- ---------------------------------------------------------------
    CURSOR changed_suppliers_cursor IS
        SELECT d.supplier_key AS old_key,
               s.sup_ID, s.clean_sup_name, s.clean_sup_phone,
               s.clean_sup_email
        FROM   supplier_staging_v s
        JOIN   supplier_dim d ON d.sup_ID = s.sup_ID
                      AND d.is_current_flag = 'Y'
        -- Never version BACKWARDS: expiring a version that starts on
        -- or after the effective date would corrupt the timeline
        -- (overlapping ranges). A backdated call fetches nothing and
        -- becomes a safe no-op.
        WHERE  d.effective_start_date < v_eff
        AND   (   NVL(s.clean_sup_name, '~')  <> NVL(d.sup_name, '~')
               OR NVL(s.clean_sup_phone, '~') <> NVL(d.sup_phone, '~')
               OR NVL(s.clean_sup_email, '~') <> NVL(d.sup_email, '~') );
BEGIN
    FOR rec IN changed_suppliers_cursor LOOP
        -- -----------------------------------------------------------
        -- STEP 1: expire the old current version (ends yesterday,
        -- never before its own start date).
        -- -----------------------------------------------------------
        UPDATE supplier_dim
        SET    effective_end_date = GREATEST(v_eff - 1,
                                             effective_start_date),
               is_current_flag    = 'N'
        WHERE  supplier_key = rec.old_key;
        v_expired := v_expired + 1;

        -- -----------------------------------------------------------
        -- STEP 2: insert the replacement version, current from v_eff.
        -- Both statements sit in ONE loop pass, so every expired row
        -- gets its replacement - the two counts cannot drift apart.
        -- -----------------------------------------------------------
        INSERT INTO supplier_dim (
            supplier_key, sup_ID, sup_name, sup_phone, sup_email,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_supplier_key.NEXTVAL,
            rec.sup_ID, rec.clean_sup_name, rec.clean_sup_phone,
            rec.clean_sup_email,
            v_eff,
            DATE '9999-12-31',
            'Y'
        );
        v_versions := v_versions + 1;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUPPLIER_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in SUPPLIER_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/
