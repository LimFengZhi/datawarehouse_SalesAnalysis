-- ===================================================================
-- 04_sub_branch_dim.sql     BRANCH_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses branch_staging_v
--   SECTION 2: no new sequence - reuses seq_branch_key
--   SECTION 3: PROCEDURE - two cursor FOR-loops: insert new records,
--              Type 1 overwrite changed ones
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: the COMPLETE sync for a non-SCD dimension. STEP 1 inserts
-- newly opened branches; STEP 2 overwrites IN PLACE any whose
-- attributes changed (Type 1). branch_dim keeps no history - one row
-- per branch, no effective dates, no current flag - so there is no
-- maintain step: this procedure is the whole story.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_branch_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
    v_updated NUMBER := 0;
    -- The NOT EXISTS anti-join lives INSIDE the cursor query, so a
    -- second run fetches nothing - that is what keeps this idempotent.
    -- Cursor FOR-loop is the deliberate idiom for the small dimension
    -- loads; set-based DML stays where volume demands it (the facts).
    CURSOR new_branches_cursor IS
        SELECT s.*
        FROM   branch_staging_v s
        WHERE  NOT EXISTS (SELECT 1 FROM branch_dim d
                           WHERE d.br_ID = s.br_ID);
    -- STEP 2's cursor: branches whose attributes drifted from the
    -- staging view - Type 1, overwritten in place (no history kept).
    CURSOR changed_branches_cursor IS
        SELECT s.br_ID, s.clean_br_name, s.clean_br_city,
               s.clean_br_state, s.clean_br_email
        FROM   branch_staging_v s
        WHERE  EXISTS (SELECT 1 FROM branch_dim d
                       WHERE  d.br_ID = s.br_ID
                       AND (  NVL(d.br_name, '~')
                                <> NVL(s.clean_br_name, '~')
                           OR NVL(d.br_city, '~')
                                <> NVL(s.clean_br_city, '~')
                           OR NVL(d.br_state, '~')
                                <> NVL(s.clean_br_state, '~')
                           OR NVL(d.br_email, '~')
                                <> NVL(s.clean_br_email, '~')));
BEGIN
    FOR rec IN new_branches_cursor LOOP
        INSERT INTO branch_dim (
            branch_key, br_ID, br_name, br_city, br_state, br_email
        ) VALUES (
            seq_branch_key.NEXTVAL,
            rec.br_ID, rec.clean_br_name, rec.clean_br_city,
            rec.clean_br_state, rec.clean_br_email
        );
        v_new := v_new + 1;
    END LOOP;

    -- ---------------------------------------------------------------
    -- STEP 2: Type 1 overwrite - name/city/state/email refreshed in place.
    -- ---------------------------------------------------------------
    FOR rec IN changed_branches_cursor LOOP
        UPDATE branch_dim
        SET    br_name  = rec.clean_br_name,
               br_city  = rec.clean_br_city,
               br_state = rec.clean_br_state,
               br_email = rec.clean_br_email
        WHERE  br_ID = rec.br_ID;
        v_updated := v_updated + 1;
    END LOOP;

    SELECT COUNT(*) INTO v_total FROM branch_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New branches inserted  : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Type 1 overwrites     : ' || v_updated);
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
