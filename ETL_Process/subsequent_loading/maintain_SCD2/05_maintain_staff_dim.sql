-- ===================================================================
-- 05_maintain_staff_dim.sql      STAFF_DIM - MAINTAIN SCD 2
--
--   SECTION 1: no new view - reuses staff_staging_v
--   SECTION 2: no new sequence - reuses seq_staff_key
--   SECTION 3: PROCEDURE - cursor FOR-loop: expire + version (Type 2)
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: CHANGED RECORDS ONLY. New hires belong to
--   sub_dimension\06_sub_staff_dim.sql
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
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_staff_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff      DATE   := TRUNC(p_effective_date);
    v_expired  NUMBER := 0;
    v_versions NUMBER := 0;
    -- ---------------------------------------------------------------
    -- ONE cursor drives both steps: each fetched row is a staff member
    -- whose CURRENT version differs from the staging view. The change
    -- test lives INSIDE the cursor query, so a second run fetches
    -- nothing - that is what keeps this idempotent. The surrogate key
    -- rides along so STEP 1 can expire exactly that row. A brand-new
    -- st_ID has no current row to join, so it is naturally excluded -
    -- inserting it is sub_dimension's job.
    --
    -- NVL on BOTH sides: NULL <> 'x' is UNKNOWN, not TRUE, so a bare
    -- <> would silently miss changes involving NULL.
    -- ---------------------------------------------------------------
    CURSOR changed_staff_cursor IS
        SELECT d.staff_key AS old_key,
               s.st_ID, s.clean_st_name, s.clean_st_email,
               s.clean_st_position, s.clean_st_status
        FROM   staff_staging_v s
        JOIN   staff_dim d ON d.st_ID = s.st_ID
                      AND d.is_current_flag = 'Y'
        -- Never version BACKWARDS: expiring a version that starts on
        -- or after the effective date would corrupt the timeline
        -- (overlapping ranges). A backdated call fetches nothing and
        -- becomes a safe no-op.
        WHERE  d.effective_start_date < v_eff
        AND   (   NVL(s.clean_st_name, '~')     <> NVL(d.st_name, '~')
               OR NVL(s.clean_st_email, '~')    <> NVL(d.st_email, '~')
               OR NVL(s.clean_st_position, '~') <> NVL(d.st_position, '~')
               OR NVL(s.clean_st_status, '~')   <> NVL(d.st_status, '~') );
BEGIN
    FOR rec IN changed_staff_cursor LOOP
        -- -----------------------------------------------------------
        -- STEP 1: expire the old current version (ends yesterday,
        -- never before its own start date).
        -- -----------------------------------------------------------
        UPDATE staff_dim
        SET    effective_end_date = GREATEST(v_eff - 1,
                                             effective_start_date),
               is_current_flag    = 'N'
        WHERE  staff_key = rec.old_key;
        v_expired := v_expired + 1;

        -- -----------------------------------------------------------
        -- STEP 2: insert the replacement version, current from v_eff.
        -- Both statements sit in ONE loop pass, so every expired row
        -- gets its replacement - the two counts cannot drift apart.
        -- -----------------------------------------------------------
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
