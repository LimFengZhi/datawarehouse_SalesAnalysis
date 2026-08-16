-- ===================================================================
-- 05_maintain_staff_dim.sql      STAFF_DIM - MAINTAIN SCD 2 + SCD 1
--
--   SECTION 1: no new view - reuses staff_staging_v
--   SECTION 2: no new sequence - reuses seq_staff_key
--   SECTION 3: PROCEDURE - expire + version (Type 2), then refresh
--              st_age in place (Type 1)
--   SECTION 4: run + verification
--
-- SCOPE: CHANGED RECORDS ONLY. New hires belong to
--   sub_dimension\07_sub_staff_dim.sql
--
-- THE TYPE 2 CHANGES THAT MATTER: promotion (st_role, st_position),
-- transfer between branches (br_ID), salary review, resignation
-- (st_status). Each of those should show up as a dated version so
-- "who was a Senior Therapist in 2021" stays answerable.
--
-- st_age IS DELIBERATELY EXCLUDED from Type 2. It is derived from
-- st_DOB against SYSDATE, so it ticks up on every birthday - roughly
-- 96 spurious versions a year for no business reason. It is refreshed
-- in place as Type 1 in STEP 3.
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
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2 + TYPE 1)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_staff_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff      DATE   := TRUNC(p_effective_date);
    v_expired  NUMBER := 0;
    v_versions NUMBER := 0;
    v_ages     NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: expire staff whose meaningful attributes changed.
    -- st_age is deliberately EXCLUDED - see the header note.
    -- ---------------------------------------------------------------
    UPDATE staff_dim d
    SET    d.effective_end_date = GREATEST(v_eff - 1,
                                           d.effective_start_date),
           d.is_current_flag    = 'N'
    WHERE  d.is_current_flag = 'Y'
    -- Never version BACKWARDS: expiring a version that starts on or
    -- after the effective date would corrupt the timeline.
    AND    d.effective_start_date < v_eff
    AND EXISTS (
        SELECT 1
        FROM   staff_staging_v s
        WHERE  s.st_ID = d.st_ID
          AND (   NVL(s.br_ID, -1)              <> NVL(d.br_ID, -1)
               OR NVL(s.clean_st_name, '~')     <> NVL(d.st_name, '~')
               OR NVL(s.clean_st_role, '~')     <> NVL(d.st_role, '~')
               OR NVL(s.clean_st_position, '~') <> NVL(d.st_position, '~')
               OR NVL(s.clean_st_city, '~')     <> NVL(d.st_city, '~')
               OR NVL(s.clean_st_state, '~')    <> NVL(d.st_state, '~')
               OR NVL(s.clean_st_gender, '~')   <> NVL(d.st_gender, '~')
               OR NVL(s.clean_st_email, '~')    <> NVL(d.st_email, '~')
               OR NVL(s.clean_st_salary, -1)    <> NVL(d.st_salary, -1)
               OR NVL(s.clean_st_status, '~')   <> NVL(d.st_status, '~')
               OR NVL(s.clean_st_hire_date, DATE '1900-01-01')
                    <> NVL(d.st_hire_date, DATE '1900-01-01') ));

    v_expired := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: new version for each staff member STEP 1 expired.
    -- ---------------------------------------------------------------
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
        v_eff,
        DATE '9999-12-31',
        'Y'
    FROM   staff_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM staff_dim d
                       WHERE d.st_ID = s.st_ID
                         AND d.is_current_flag = 'Y')
    AND    EXISTS     (SELECT 1 FROM staff_dim d
                       WHERE d.st_ID = s.st_ID);

    v_versions := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 3: TYPE 1 refresh of age on CURRENT rows only.
    -- Ageing is not a business event, so it overwrites without history.
    -- ---------------------------------------------------------------
    UPDATE staff_dim d
    SET    d.st_age = (SELECT s.derived_st_age
                       FROM   staff_staging_v s
                       WHERE  s.st_ID = d.st_ID)
    WHERE  d.is_current_flag = 'Y'
    AND    EXISTS (SELECT 1 FROM staff_staging_v s
                   WHERE s.st_ID = d.st_ID
                     AND NVL(s.derived_st_age, -1) <> NVL(d.st_age, -1));

    v_ages := SQL%ROWCOUNT;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('STAFF_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);
    DBMS_OUTPUT.PUT_LINE(' - Ages refreshed     : ' || v_ages
        || '  (Type 1, in place)');

    IF v_expired <> v_versions THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: expired and inserted counts '
            || 'differ - run the integrity checks in SECTION 4.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in STAFF_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION - moved out
-- EXECs live in execute_sub_procedure.sql / execute_sub2.sql.
-- Pass p_effective_date as the date the change ACTUALLY happened,
-- e.g. EXEC maintain_staff_dim_scd2(DATE '2025-01-01');
-- Verification queries live in ..\validate_subsequent_loading.sql
-- ===================================================================
