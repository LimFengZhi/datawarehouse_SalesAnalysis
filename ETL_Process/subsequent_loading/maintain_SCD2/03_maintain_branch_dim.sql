-- ===================================================================
-- 03_maintain_branch_dim.sql     BRANCH_DIM - MAINTAIN SCD TYPE 2
--
--   SECTION 1: no new view - reuses branch_staging_v
--   SECTION 2: no new sequence - reuses seq_branch_key
--   SECTION 3: PROCEDURE - cursor FOR-loop: expire changed rows,
--              insert new versions
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: CHANGED RECORDS ONLY - a branch renamed, relocated, or given
-- a new email. Newly opened branches belong to
--   sub_dimension\04_sub_branch_dim.sql
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - reuses branch_staging_v from
--   ETL_Process\initial_loading\init_dimension\01_init_branch_dim.sql
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
    -- ---------------------------------------------------------------
    -- ONE cursor drives both steps: each fetched row is a branch
    -- whose CURRENT version differs from the staging view. The change
    -- test lives INSIDE the cursor query, so a second run fetches
    -- nothing - that is what keeps this idempotent. The surrogate key
    -- rides along so STEP 1 can expire exactly that row. A brand-new
    -- br_ID has no current row to join, so it is naturally excluded -
    -- inserting it is sub_dimension's job.
    --
    -- NVL on BOTH sides: NULL <> 'x' is UNKNOWN, not TRUE, so a bare
    -- <> would silently miss changes involving NULL.
    -- ---------------------------------------------------------------
    CURSOR changed_branches_cursor IS
        SELECT d.branch_key AS old_key,
               s.br_ID, s.clean_br_name, s.clean_br_city,
               s.clean_br_state, s.clean_br_email
        FROM   branch_staging_v s
        JOIN   branch_dim d ON d.br_ID = s.br_ID
                      AND d.is_current_flag = 'Y'
        -- Never version BACKWARDS: expiring a version that starts on
        -- or after the effective date would corrupt the timeline
        -- (overlapping ranges). A backdated call fetches nothing and
        -- becomes a safe no-op.
        WHERE  d.effective_start_date < v_eff
        AND   (   NVL(s.clean_br_name, '~')  <> NVL(d.br_name, '~')
               OR NVL(s.clean_br_city, '~')  <> NVL(d.br_city, '~')
               OR NVL(s.clean_br_state, '~') <> NVL(d.br_state, '~')
               OR NVL(s.clean_br_email, '~') <> NVL(d.br_email, '~') );
BEGIN
    FOR rec IN changed_branches_cursor LOOP
        -- -----------------------------------------------------------
        -- STEP 1: expire the old current version (ends yesterday,
        -- never before its own start date).
        -- -----------------------------------------------------------
        UPDATE branch_dim
        SET    effective_end_date = GREATEST(v_eff - 1,
                                             effective_start_date),
               is_current_flag    = 'N'
        WHERE  branch_key = rec.old_key;
        v_expired := v_expired + 1;

        -- -----------------------------------------------------------
        -- STEP 2: insert the replacement version, current from v_eff.
        -- Both statements sit in ONE loop pass, so every expired row
        -- gets its replacement - the two counts cannot drift apart.
        -- -----------------------------------------------------------
        INSERT INTO branch_dim (
            branch_key, br_ID, br_name, br_city, br_state, br_email,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_branch_key.NEXTVAL,
            rec.br_ID, rec.clean_br_name, rec.clean_br_city,
            rec.clean_br_state, rec.clean_br_email,
            v_eff,
            DATE '9999-12-31',
            'Y'
        );
        v_versions := v_versions + 1;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in BRANCH_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/
