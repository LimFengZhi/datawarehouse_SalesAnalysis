-- ===================================================================
-- 07_sub_customer_dim.sql   CUSTOMER_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses customer_staging_v
--   SECTION 2: no new sequence - reuses seq_customer_key
--   SECTION 3: PROCEDURE - two cursor FOR-loops: insert new records,
--              Type 1 overwrite of untracked-attribute corrections
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: STEP 1 inserts customers who registered since the last load
-- (cus_name built from first + last, cus_age_group derived from
-- cus_DOB by the view); STEP 2 overwrites name/email/gender
-- corrections in place on every version (Type 1).
--
-- A LOYALTY-TIER UPGRADE OR A HOME MOVE IS NOT HANDLED HERE. Those
-- are the SCD Type 2 cases: when someone moves Silver -> Gold (or
-- moves house), orders placed BEFORE the change must still report
-- under the old tier and the old home city, or the tier and hotspot
-- analyses are meaningless. They belong to the maintain-SCD2 step.
--
-- cus_age_group drifts every birthday, so in that step it must be
-- Type 1 (overwrite in place) and kept OUT of Type 2 change
-- detection - otherwise 26,000 customers gain a version every year.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_customer_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
    v_updated NUMBER := 0;
    -- The NOT EXISTS anti-join lives INSIDE the cursor query, so a
    -- second run fetches nothing - that is what keeps this idempotent.
    -- Cursor FOR-loop is the deliberate idiom for the small dimension
    -- loads; set-based DML stays where volume demands it (the facts).
    CURSOR new_customers_cursor IS
        SELECT s.*
        FROM   customer_staging_v s
        WHERE  NOT EXISTS (SELECT 1 FROM customer_dim d
                           WHERE d.cus_ID = s.cus_ID);
    -- STEP 2's cursor: natural keys where ANY version still carries an
    -- UNTRACKED attribute (name/email/gender) that differs from the staging
    -- view - corrections, not history. The tracked attributes belong
    -- to the maintain-SCD2 step and are NOT touched here.
    CURSOR changed_customers_cursor IS
        SELECT s.cus_ID, s.clean_cus_name, s.clean_cus_email,
               s.clean_cus_gender
        FROM   customer_staging_v s
        WHERE  EXISTS (SELECT 1 FROM customer_dim d
                       WHERE  d.cus_ID = s.cus_ID
                       AND (  NVL(d.cus_name, '~')
                                <> NVL(s.clean_cus_name, '~')
                           OR NVL(d.cus_email, '~')
                                <> NVL(s.clean_cus_email, '~')
                           OR NVL(d.cus_gender, '~')
                                <> NVL(s.clean_cus_gender, '~')));
BEGIN
    FOR rec IN new_customers_cursor LOOP
        INSERT INTO customer_dim (
            customer_key, cus_ID, cus_name, cus_email, cus_gender, cus_city,
            cus_state, cus_age_group, cus_loyalty_tier,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_customer_key.NEXTVAL,
            rec.cus_ID, rec.clean_cus_name, rec.clean_cus_email,
            rec.clean_cus_gender, rec.clean_cus_city, rec.clean_cus_state,
            rec.derived_cus_age_group, rec.clean_cus_loyalty_tier,
            DATE '2019-01-01',
            DATE '9999-12-31',
            'Y'
        );
        v_new := v_new + 1;
    END LOOP;

    -- ---------------------------------------------------------------
    -- STEP 2: TYPE 1 corrections - name/email/gender overwritten on ALL
    -- VERSIONS of the key (no is_current filter), so a corrected
    -- label never splits one natural key's history into two lines.
    -- ---------------------------------------------------------------
    FOR rec IN changed_customers_cursor LOOP
        UPDATE customer_dim
        SET    cus_name   = rec.clean_cus_name,
               cus_email  = rec.clean_cus_email,
               cus_gender = rec.clean_cus_gender
        WHERE  cus_ID = rec.cus_ID;
        v_updated := v_updated + 1;
    END LOOP;

    SELECT COUNT(*) INTO v_total FROM customer_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('CUSTOMER_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New customers inserted : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Type 1 corrections    : ' || v_updated);
    DBMS_OUTPUT.PUT_LINE(' - Already present        : '
        || (v_total - v_new));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in CUSTOMER_DIM subsequent load: '
            || SQLERRM);
        RAISE;
END;
/
