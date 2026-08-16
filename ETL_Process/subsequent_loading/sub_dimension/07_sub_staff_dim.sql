-- ===================================================================
-- 07_sub_staff_dim.sql      STAFF_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses staff_staging_v
--   SECTION 2: no new sequence - reuses seq_staff_key
--   SECTION 3: PROCEDURE - insert new records only
--   SECTION 4: run + verification
--
-- SCOPE: NEW RECORDS ONLY - a new hire is added, with st_name built
-- from first + last and st_age derived from st_DOB by the view.
--
-- Promotions, transfers, salary reviews and resignations on EXISTING
-- staff are NOT handled here - those are the SCD Type 2 changes that
-- belong to the maintain step. Age also drifts every birthday, which
-- is why it must be treated there as a Type 1 attribute (overwrite in
-- place) and kept OUT of Type 2 change detection - otherwise every
-- staff member gains a version once a year for no business reason.
--
-- br_ID is passed through UNCHANGED: staff_dim has a foreign key to
-- branch(br_ID), so it must stay a valid source value.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - reuses staff_staging_v from
--   ETL_Process\initial_loading\init_dimension\06_init_staff_dim.sql
--
-- SECTION 2: SEQUENCE - reuses seq_staff_key, continuing from
-- wherever the last load left it.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_staff_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
BEGIN
    INSERT INTO staff_dim (
        staff_key, st_ID, br_ID, st_name, st_role, st_position,
        st_city, st_state, st_gender, st_age, st_email,
        st_hire_date, st_salary, st_status,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_staff_key.NEXTVAL,
        s.st_ID, s.br_ID, s.clean_st_name, s.clean_st_role,
        s.clean_st_position, s.clean_st_city, s.clean_st_state,
        s.clean_st_gender, s.derived_st_age, s.clean_st_email,
        s.clean_st_hire_date, s.clean_st_salary, s.clean_st_status,
        DATE '2019-01-01',   -- first version: start of recorded history
        DATE '9999-12-31',
        'Y'
    FROM   staff_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM staff_dim d
                       WHERE d.st_ID = s.st_ID);

    v_new := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_total FROM staff_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('STAFF_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New staff inserted     : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Already present        : '
        || (v_total - v_new));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in STAFF_DIM subsequent load: '
            || SQLERRM);
        RAISE;
END;
/
