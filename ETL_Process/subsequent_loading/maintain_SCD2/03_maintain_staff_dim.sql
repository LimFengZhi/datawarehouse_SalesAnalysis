-- ===================================================================
-- 03_maintain_staff_dim.sql      STAFF_DIM - MAINTAIN SCD 2
--
--   SECTION 1: no new view - reuses staff_staging_v
--   SECTION 2: no new sequence - reuses seq_staff_key
--   SECTION 3: PROCEDURE - cursor FOR-loop: expire + version (Type 2)
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: CHANGED RECORDS ONLY. New hires belong to
--   sub_dimension\06_sub_staff_dim.sql
--
-- TRACKED (TYPE 2): st_position and st_status ONLY - promotion and
-- resignation. Each shows up as a dated version so "who was a Senior
-- Therapist in 2021" stays answerable. A name or email correction is
-- not history - sub_dimension's STEP 2 overwrites it in place
-- (Type 1). This procedure versions position/status and nothing else.
--
-- staff_dim has NO Type 1 attribute any more: st_age (which used to be
-- refreshed in place) is no longer part of the dimension, so there is
-- no STEP 3 in this procedure.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_staff_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff      DATE   := TRUNC(p_effective_date);
    v_expired  NUMBER := 0;
    v_versions NUMBER := 0;

    CURSOR changed_staff_cursor IS
        SELECT d.staff_key AS old_key,
               s.st_ID, s.clean_st_name, s.clean_st_email,
               s.clean_st_position, s.clean_st_status
        FROM   staff_staging_v s
        JOIN   staff_dim d ON d.st_ID = s.st_ID
                      AND d.is_current_flag = 'Y'
        WHERE  d.effective_start_date < v_eff
        AND   (   NVL(s.clean_st_position, '~') <> NVL(d.st_position, '~')
               OR NVL(s.clean_st_status, '~')   <> NVL(d.st_status, '~') );
BEGIN
    FOR rec IN changed_staff_cursor LOOP
        UPDATE staff_dim
        SET    effective_end_date = GREATEST(v_eff - 1,
                                             effective_start_date),
               is_current_flag    = 'N'
        WHERE  staff_key = rec.old_key;
        v_expired := v_expired + 1;

        INSERT INTO staff_dim (
            staff_key, st_ID, st_name, st_email, st_position, st_status,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_staff_key.NEXTVAL,
            rec.st_ID, rec.clean_st_name, rec.clean_st_email,
            rec.clean_st_position, rec.clean_st_status,
            v_eff,
            DATE '9999-12-31',
            'Y'
        );
        v_versions := v_versions + 1;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('STAFF_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in STAFF_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/
