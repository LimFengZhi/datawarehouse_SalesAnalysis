-- ===================================================================
-- 05_maintain_staff_dim.sql      STAFF_DIM - MAINTAIN SCD 2
--
--   SECTION 1: no new view - reuses staff_staging_v
--   SECTION 2: no new sequence - reuses seq_staff_key
--   SECTION 3: PROCEDURE - expire + version (Type 2)
--   SECTION 4: run + verification
--
-- SCOPE: CHANGED RECORDS ONLY. New hires belong to
--   sub_dimension\07_sub_staff_dim.sql
--
-- THE TYPE 2 CHANGES THAT MATTER: promotion (st_position), resignation
-- (st_status), plus name / email corrections. Each of those should
-- show up as a dated version so "who was a Senior Therapist in 2021"
-- stays answerable.
--
-- staff_dim has NO Type 1 attribute any more: st_age (which used to be
-- refreshed in place) is no longer part of the dimension, so there is
-- no STEP 3 in this procedure.
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
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_staff_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff      DATE   := TRUNC(p_effective_date);
    v_expired  NUMBER := 0;
    v_versions NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: expire staff whose tracked attributes changed
    --         (st_name, st_email, st_position, st_status).
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
          AND (   NVL(s.clean_st_name, '~')     <> NVL(d.st_name, '~')
               OR NVL(s.clean_st_email, '~')    <> NVL(d.st_email, '~')
               OR NVL(s.clean_st_position, '~') <> NVL(d.st_position, '~')
               OR NVL(s.clean_st_status, '~')   <> NVL(d.st_status, '~') ));

    v_expired := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: new version for each staff member STEP 1 expired.
    -- ---------------------------------------------------------------
    INSERT INTO staff_dim (
        staff_key, st_ID, st_name, st_email, st_position, st_status,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_staff_key.NEXTVAL,
        s.st_ID, s.clean_st_name, s.clean_st_email,
        s.clean_st_position, s.clean_st_status,
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

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('STAFF_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);

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
