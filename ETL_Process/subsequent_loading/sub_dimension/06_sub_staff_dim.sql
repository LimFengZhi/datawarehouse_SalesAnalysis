-- ===================================================================
-- 06_sub_staff_dim.sql      STAFF_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses staff_staging_v
--   SECTION 2: no new sequence - reuses seq_staff_key
--   SECTION 3: PROCEDURE - cursor FOR-loop inserts new records only
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: NEW RECORDS ONLY - a new hire is added, with st_name built
-- from first + last by the view.
--
-- Promotions (st_position), resignations (st_status), name and email
-- changes on EXISTING staff are NOT handled here - those are the SCD
-- Type 2 changes that belong to the maintain step.
--
-- staff_dim no longer carries br_ID, city, state, gender, age, hire
-- date or salary; the branch of a transaction comes from the fact's
-- own OLTP row (orders / reservation / staff.br_ID for salary).
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_staff_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
    -- The NOT EXISTS anti-join lives INSIDE the cursor query, so a
    -- second run fetches nothing - that is what keeps this idempotent.
    -- Cursor FOR-loop is the deliberate idiom for the small dimension
    -- loads; set-based DML stays where volume demands it (the facts).
    CURSOR new_staff_cursor IS
        SELECT s.*
        FROM   staff_staging_v s
        WHERE  NOT EXISTS (SELECT 1 FROM staff_dim d
                           WHERE d.st_ID = s.st_ID);
BEGIN
    FOR rec IN new_staff_cursor LOOP
        INSERT INTO staff_dim (
            staff_key, st_ID, st_name, st_email, st_position, st_status,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_staff_key.NEXTVAL,
            rec.st_ID, rec.clean_st_name, rec.clean_st_email,
            rec.clean_st_position, rec.clean_st_status,
            DATE '2019-01-01',
            DATE '9999-12-31',
            'Y'
        );
        v_new := v_new + 1;
    END LOOP;

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
