-- ===================================================================
-- 03_maintain_branch_dim.sql     BRANCH_DIM - MAINTAIN SCD TYPE 2
--
--   SECTION 1: no new view - reuses branch_staging_v
--   SECTION 2: no new sequence - reuses seq_branch_key
--   SECTION 3: PROCEDURE - expire changed rows, insert new versions
--   SECTION 4: run + verification
--
-- SCOPE: CHANGED RECORDS ONLY - a branch renamed, relocated, or given
-- a new email. Newly opened branches belong to
--   sub_dimension\04_sub_branch_dim.sql
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
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_branch_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff      DATE   := TRUNC(p_effective_date);
    v_expired  NUMBER := 0;
    v_versions NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: expire changed branches.
    -- br_open_date is a DATE, so its NVL default is a date sentinel.
    -- ---------------------------------------------------------------
    UPDATE branch_dim d
    SET    d.effective_end_date = GREATEST(v_eff - 1,
                                           d.effective_start_date),
           d.is_current_flag    = 'N'
    WHERE  d.is_current_flag = 'Y'
    -- Never version BACKWARDS: expiring a version that starts on or
    -- after the effective date would corrupt the timeline.
    AND    d.effective_start_date < v_eff
    AND EXISTS (
        SELECT 1
        FROM   branch_staging_v s
        WHERE  s.br_ID = d.br_ID
          AND (   NVL(s.clean_br_name, '~')  <> NVL(d.br_name, '~')
               OR NVL(s.clean_br_city, '~')  <> NVL(d.br_city, '~')
               OR NVL(s.clean_br_state, '~') <> NVL(d.br_state, '~')
               OR NVL(s.clean_br_email, '~') <> NVL(d.br_email, '~')
               OR NVL(s.clean_br_open_date, DATE '1900-01-01')
                    <> NVL(d.br_open_date, DATE '1900-01-01') ));

    v_expired := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: new version for each branch STEP 1 expired.
    -- ---------------------------------------------------------------
    INSERT INTO branch_dim (
        branch_key, br_ID, br_name, br_city, br_state, br_email,
        br_open_date, effective_start_date, effective_end_date,
        is_current_flag
    )
    SELECT
        seq_branch_key.NEXTVAL,
        s.br_ID, s.clean_br_name, s.clean_br_city, s.clean_br_state,
        s.clean_br_email, s.clean_br_open_date,
        v_eff,
        DATE '9999-12-31',
        'Y'
    FROM   branch_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM branch_dim d
                       WHERE d.br_ID = s.br_ID
                         AND d.is_current_flag = 'Y')
    AND    EXISTS     (SELECT 1 FROM branch_dim d
                       WHERE d.br_ID = s.br_ID);

    v_versions := SQL%ROWCOUNT;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);

    IF v_expired <> v_versions THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: expired and inserted counts '
            || 'differ - run the integrity checks in SECTION 4.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in BRANCH_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION - moved out
-- EXECs live in execute_sub_procedure.sql / execute_sub2.sql.
-- Pass p_effective_date as the date the change ACTUALLY happened,
-- e.g. EXEC maintain_branch_dim_scd2(DATE '2025-01-01');
-- Verification queries live in ..\validate_subsequent_loading.sql
-- ===================================================================
