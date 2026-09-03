-- ===================================================================
-- 02_sub_supplier_dim.sql   SUPPLIER_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses supplier_staging_v
--   SECTION 2: no new sequence - reuses seq_supplier_key
--   SECTION 3: PROCEDURE - two cursor FOR-loops: insert new records,
--              Type 1 overwrite changed ones
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: the COMPLETE sync for a non-SCD dimension. STEP 1 inserts
-- suppliers that do not exist yet; STEP 2 overwrites IN PLACE any
-- whose attributes changed (Type 1). supplier_dim keeps no history -
-- one row per supplier, no effective dates, no current flag - so
-- there is no maintain step: this procedure is the whole story.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_supplier_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
    v_updated NUMBER := 0;
    -- The NOT EXISTS anti-join lives INSIDE the cursor query, so a
    -- second run fetches nothing - that is what keeps this idempotent.
    -- Cursor FOR-loop is the deliberate idiom for the small dimension
    -- loads; set-based DML stays where volume demands it (the facts).
    CURSOR new_suppliers_cursor IS
        SELECT s.*
        FROM   supplier_staging_v s
        WHERE  NOT EXISTS (SELECT 1 FROM supplier_dim d
                           WHERE d.sup_ID = s.sup_ID);
    -- STEP 2's cursor: suppliers whose attributes drifted from the
    -- staging view - Type 1, overwritten in place (no history kept).
    CURSOR changed_suppliers_cursor IS
        SELECT s.sup_ID, s.clean_sup_name, s.clean_sup_phone, s.clean_sup_email
        FROM   supplier_staging_v s
        WHERE  EXISTS (SELECT 1 FROM supplier_dim d
                       WHERE  d.sup_ID = s.sup_ID
                       AND (  NVL(d.sup_name, '~')
                                <> NVL(s.clean_sup_name, '~')
                           OR NVL(d.sup_phone, '~')
                                <> NVL(s.clean_sup_phone, '~')
                           OR NVL(d.sup_email, '~')
                                <> NVL(s.clean_sup_email, '~')));
BEGIN
    FOR rec IN new_suppliers_cursor LOOP
        INSERT INTO supplier_dim (
            supplier_key, sup_ID, sup_name, sup_phone, sup_email
        ) VALUES (
            seq_supplier_key.NEXTVAL,
            rec.sup_ID, rec.clean_sup_name, rec.clean_sup_phone,
            rec.clean_sup_email
        );
        v_new := v_new + 1;
    END LOOP;

    -- ---------------------------------------------------------------
    -- STEP 2: Type 1 overwrite - name/phone/email refreshed in place.
    -- ---------------------------------------------------------------
    FOR rec IN changed_suppliers_cursor LOOP
        UPDATE supplier_dim
        SET    sup_name  = rec.clean_sup_name,
               sup_phone = rec.clean_sup_phone,
               sup_email = rec.clean_sup_email
        WHERE  sup_ID = rec.sup_ID;
        v_updated := v_updated + 1;
    END LOOP;

    SELECT COUNT(*) INTO v_total FROM supplier_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUPPLIER_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New suppliers inserted : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Type 1 overwrites     : ' || v_updated);
    DBMS_OUTPUT.PUT_LINE(' - Already present        : '
        || (v_total - v_new));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in SUPPLIER_DIM subsequent load: '
            || SQLERRM);
        RAISE;
END;
/