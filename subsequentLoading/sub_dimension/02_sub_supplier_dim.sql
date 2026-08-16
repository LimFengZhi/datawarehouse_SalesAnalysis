-- ===================================================================
-- 02_sub_supplier_dim.sql   SUPPLIER_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses supplier_staging_v
--   SECTION 2: no new sequence - reuses seq_supplier_key
--   SECTION 3: PROCEDURE - insert new records only
--   SECTION 4: run + verification
--
-- SCOPE: NEW RECORDS ONLY. A supplier that exists in the OLTP but not
-- in the dimension gets a surrogate key and is added. Nothing is ever
-- updated or expired here.
--
-- Changed attributes (a supplier renamed, a new phone number) are NOT
-- picked up by this script - that is SCD Type 2 and belongs to the
-- separate maintain-SCD2 step. effective_start_date / end_date /
-- is_current_flag are still populated on insert so that step has a
-- clean starting point.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - REUSED, NOT RECREATED
-- supplier_staging_v is defined in
--   initialLoading\init_dimension\03_init_supplier_dim.sql
-- It already does the TRIM / name / phone / email cleansing, so this
-- must NOT duplicate that logic - if a rule changes it changes once
-- and both loads follow.
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - REUSED, NOT RECREATED
-- seq_supplier_key already issued keys 500..505. It continues at 506.
-- Recreating it would restart at 500 and violate the primary key.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_supplier_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
BEGIN
    -- The anti-join is what makes this safe to re-run: a supplier that
    -- already has a row is skipped, so a second run inserts nothing.
    INSERT INTO supplier_dim (
        supplier_key, sup_ID, sup_name, sup_phone, sup_email,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_supplier_key.NEXTVAL,
        s.sup_ID, s.clean_sup_name, s.clean_sup_phone, s.clean_sup_email,
        DATE '2019-01-01',   -- first version: start of recorded history
        DATE '9999-12-31',
        'Y'
    FROM   supplier_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM supplier_dim d
                       WHERE d.sup_ID = s.sup_ID);

    v_new := SQL%ROWCOUNT;

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

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
-- Procedure created above. The EXEC now lives in the folder runner
--   00_run_all_sub_dimensions.sql
-- so every call and its arguments sit in ONE place.
--   EXEC load_supplier_dim_incremental;

-- One row per natural key. Must return no rows.
SELECT sup_ID, COUNT(*) AS rows_per_key
FROM   supplier_dim
GROUP BY sup_ID HAVING COUNT(*) > 1;

SELECT supplier_key, sup_ID, sup_name, sup_phone, sup_email,
       effective_start_date, is_current_flag
FROM   supplier_dim
ORDER BY supplier_key;

-- Every OLTP supplier is represented
SELECT COUNT(*) AS missing_from_dim
FROM   supplier s
WHERE  NOT EXISTS (SELECT 1 FROM supplier_dim d
                   WHERE d.sup_ID = s.sup_ID);
-- expect 0

-- Re-run the EXEC above: must report 0 new suppliers inserted.
