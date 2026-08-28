-- ===================================================================
-- 02_sub_supplier_dim.sql   SUPPLIER_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses supplier_staging_v
--   SECTION 2: no new sequence - reuses seq_supplier_key
--   SECTION 3: PROCEDURE - cursor FOR-loop inserts new records only
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: NEW RECORDS ONLY - a supplier signed up since the last load
-- is added. A supplier whose name / phone / email changed is NOT
-- updated here; that is the maintain-SCD2 step.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_supplier_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
    -- The NOT EXISTS anti-join lives INSIDE the cursor query, so a
    -- second run fetches nothing - that is what keeps this idempotent.
    -- Cursor FOR-loop is the deliberate idiom for the small dimension
    -- loads; set-based DML stays where volume demands it (the facts).
    CURSOR new_suppliers_cursor IS
        SELECT s.*
        FROM   supplier_staging_v s
        WHERE  NOT EXISTS (SELECT 1 FROM supplier_dim d
                           WHERE d.sup_ID = s.sup_ID);
BEGIN
    FOR rec IN new_suppliers_cursor LOOP
        INSERT INTO supplier_dim (
            supplier_key, sup_ID, sup_name, sup_phone, sup_email,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_supplier_key.NEXTVAL,
            rec.sup_ID, rec.clean_sup_name, rec.clean_sup_phone,
            rec.clean_sup_email,
            DATE '2019-01-01',
            DATE '9999-12-31',
            'Y'
        );
        v_new := v_new + 1;
    END LOOP;

    SELECT COUNT(*) INTO v_total FROM supplier_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUPPLIER_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New suppliers inserted : ' || v_new);
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