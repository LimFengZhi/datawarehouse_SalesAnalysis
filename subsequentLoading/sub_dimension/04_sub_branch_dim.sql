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
-- SECTION 1: STAGING VIEW - REUSED, NOT RECREATED
-- branch_staging_v is defined in
--   initialLoading\init_dimension\01_init_branch_dim.sql
-- It normalises the 5 cities and 5 Malaysian states.
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - REUSED, NOT RECREATED
-- seq_branch_key already issued keys 1..5. It continues at 6.
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
        TRUNC(SYSDATE),
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

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_branch_dim_incremental;

-- One row per natural key. Must return no rows.
SELECT br_ID, COUNT(*) AS rows_per_key
FROM   branch_dim
GROUP BY br_ID HAVING COUNT(*) > 1;

SELECT branch_key, br_ID, br_name, br_city, br_state,
       effective_start_date, is_current_flag
FROM   branch_dim
ORDER BY branch_key;

-- Every OLTP branch is represented
SELECT COUNT(*) AS missing_from_dim
FROM   branch b
WHERE  NOT EXISTS (SELECT 1 FROM branch_dim d
                   WHERE d.br_ID = b.br_ID);
-- expect 0

-- Re-run the EXEC above: must report 0 new branches inserted.
