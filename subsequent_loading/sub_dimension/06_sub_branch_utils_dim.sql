-- ===================================================================
-- 06_sub_branch_utils_dim.sql   BRANCH_UTILS_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses branch_utils_staging_v
--   SECTION 2: no new sequence - reuses seq_branch_utils_key
--   SECTION 3: PROCEDURE - insert new records only
--   SECTION 4: run + verification
--
-- SCOPE: NEW RECORDS ONLY - a new utility category is added.
--
-- Note this dimension has no effective_start_date, effective_end_date
-- or is_current_flag at all (see create_dwh.sql, BRANCH UTILS CATEGORY
-- DIMENSION), so the INSERT is shorter than the others. It is a Type 1
-- lookup by design, and renaming an existing category is handled in
-- the maintain step.
--
-- Procedure name is load_br_utils_dim_incremental, not
-- load_branch_utils_dim_incremental - the latter is 33 characters and
-- Oracle 11.2 caps identifiers at 30 (ORA-00972).
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - reuses branch_utils_staging_v from
--   initial_loading\init_dimension\02_init_branch_utils_dim.sql
--
-- SECTION 2: SEQUENCE - reuses seq_branch_utils_key, continuing from
-- wherever the last load left it.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_br_utils_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
BEGIN
    INSERT INTO branch_utils_dim (
        branch_utils_key, br_utils_ID, util_name, util_category
    )
    SELECT
        seq_branch_utils_key.NEXTVAL,
        s.br_utils_ID, s.clean_util_name, s.derived_util_category
    FROM   branch_utils_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM branch_utils_dim d
                       WHERE d.br_utils_ID = s.br_utils_ID);

    v_new := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_total FROM branch_utils_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_UTILS_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New categories added   : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Already present        : '
        || (v_total - v_new));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in BRANCH_UTILS_DIM subsequent load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION - moved out
-- EXECs live in execute_sub_procedure.sql / execute_sub2.sql.
-- Verification queries live in ..\validate_subsequent_loading.sql
-- ===================================================================
