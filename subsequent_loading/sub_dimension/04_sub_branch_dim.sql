-- ===================================================================
-- 04_sub_branch_dim.sql     BRANCH_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses branch_staging_v
--   SECTION 2: no new sequence - reuses seq_branch_key
--   SECTION 3: PROCEDURE - insert new records only
--   SECTION 4: run + verification
--
-- SCOPE: NEW RECORDS ONLY - a newly opened branch is added.
-- A branch that changes its name, city or email is NOT updated here;
-- that is the maintain-SCD2 step.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - reuses branch_staging_v from
--   initial_loading\init_dimension\01_init_branch_dim.sql
--
-- SECTION 2: SEQUENCE - reuses seq_branch_key, continuing from
-- wherever the last load left it.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_branch_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
BEGIN
    INSERT INTO branch_dim (
        branch_key, br_ID, br_name, br_city, br_state, br_email,
        br_open_date, effective_start_date, effective_end_date,
        is_current_flag
    )
    SELECT
        seq_branch_key.NEXTVAL,
        s.br_ID, s.clean_br_name, s.clean_br_city, s.clean_br_state,
        s.clean_br_email, s.clean_br_open_date,
        DATE '2019-01-01',   -- first version: start of recorded history
        DATE '9999-12-31',
        'Y'
    FROM   branch_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM branch_dim d
                       WHERE d.br_ID = s.br_ID);

    v_new := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_total FROM branch_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New branches inserted  : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Already present        : '
        || (v_total - v_new));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in BRANCH_DIM subsequent load: '
            || SQLERRM);
        RAISE;
END;
/
