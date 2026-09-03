-- ===================================================================
-- 04_maintain_customer_dim.sql   CUSTOMER_DIM - MAINTAIN SCD 2 + SCD 1
--
--   SECTION 1: no new view - reuses customer_staging_v
--   SECTION 2: no new sequence - reuses seq_customer_key
--   SECTION 3: PROCEDURE - cursor FOR-loops: expire + version
--              (Type 2), then refresh cus_age_group in place (Type 1)
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: CHANGED RECORDS ONLY. New customers belong to
--   sub_dimension\07_sub_customer_dim.sql
--
-- THE MOST IMPORTANT SCD2 CASE IN THIS WAREHOUSE: cus_loyalty_tier.
-- When a customer is upgraded Silver -> Gold, orders placed BEFORE the
-- upgrade must still report as Silver. Type 1 would retroactively make
-- every past order look like Gold and destroy the tier analysis - the
-- one showing Bronze customers spend RM 853 each against Platinum's
-- RM 733 once the loyalty discount is applied.
--
-- Type 2 tracked: cus_loyalty_tier, cus_city, cus_state. A MOVE is
-- history: the hotspot analysis attributes spend to the home city in
-- force when the money was spent, so the old versions must keep the
-- old address. Name / email / gender are corrections, not history -
-- sub_dimension's STEP 2 overwrites them in place (Type 1). This
-- procedure = Type 2 versioning + the age-group refresh only.
--
-- cus_age_group is EXCLUDED from Type 2. It is derived from cus_DOB
-- against SYSDATE, so versioning on it would add thousands of rows a
-- year for no business reason. It is refreshed in place as Type 1 in
-- STEP 3.
-- ===================================================================

SET SERVEROUTPUT ON


-- ===================================================================
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2 + TYPE 1)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_customer_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff      DATE   := TRUNC(p_effective_date);
    v_expired  NUMBER := 0;
    v_versions NUMBER := 0;
    v_ages     NUMBER := 0;

    CURSOR changed_customers_cursor IS
        SELECT d.customer_key AS old_key,
               s.cus_ID, s.clean_cus_name, s.clean_cus_email,
               s.clean_cus_gender, s.clean_cus_city, s.clean_cus_state,
               s.derived_cus_age_group, s.clean_cus_loyalty_tier
        FROM   customer_staging_v s
        JOIN   customer_dim d ON d.cus_ID = s.cus_ID
                      AND d.is_current_flag = 'Y'

        WHERE  d.effective_start_date < v_eff
        AND   (   NVL(s.clean_cus_loyalty_tier, '~')
                    <> NVL(d.cus_loyalty_tier, '~')
               OR NVL(s.clean_cus_city, '~')  <> NVL(d.cus_city, '~')
               OR NVL(s.clean_cus_state, '~') <> NVL(d.cus_state, '~') );
    -- STEP 3's cursor: current rows whose age group drifted (a
    -- birthday, not a business event - Type 1, overwrite in place).
    CURSOR aged_customers_cursor IS
        SELECT d.customer_key AS old_key, s.derived_cus_age_group
        FROM   customer_staging_v s
        JOIN   customer_dim d ON d.cus_ID = s.cus_ID
                             AND d.is_current_flag = 'Y'
        WHERE  NVL(s.derived_cus_age_group, '~')
                 <> NVL(d.cus_age_group, '~');
BEGIN
    FOR rec IN changed_customers_cursor LOOP
        -- -----------------------------------------------------------
        -- STEP 1: expire the old current version (ends yesterday,
        -- never before its own start date).
        -- -----------------------------------------------------------
        UPDATE customer_dim
        SET    effective_end_date = GREATEST(v_eff - 1,
                                             effective_start_date),
               is_current_flag    = 'N'
        WHERE  customer_key = rec.old_key;
        v_expired := v_expired + 1;

        -- -----------------------------------------------------------
        -- STEP 2: insert the replacement version, current from v_eff.
        -- Both statements sit in ONE loop pass, so every expired row
        -- gets its replacement - the two counts cannot drift apart.
        -- -----------------------------------------------------------
        INSERT INTO customer_dim (
            customer_key, cus_ID, cus_name, cus_email, cus_gender,
            cus_city, cus_state, cus_age_group, cus_loyalty_tier,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_customer_key.NEXTVAL,
            rec.cus_ID, rec.clean_cus_name, rec.clean_cus_email,
            rec.clean_cus_gender, rec.clean_cus_city, rec.clean_cus_state,
            rec.derived_cus_age_group, rec.clean_cus_loyalty_tier,
            v_eff,
            DATE '9999-12-31',
            'Y'
        );
        v_versions := v_versions + 1;
    END LOOP;

    -- ---------------------------------------------------------------
    -- STEP 3: TYPE 1 refresh of cus_age_group on CURRENT rows. Runs
    -- AFTER the Type 2 loop: versions inserted in STEP 2 already carry
    -- today's derived age group, so this cursor does not fetch them.
    -- ---------------------------------------------------------------
    FOR rec IN aged_customers_cursor LOOP
        UPDATE customer_dim
        SET    cus_age_group = rec.derived_cus_age_group
        WHERE  customer_key = rec.old_key;
        v_ages := v_ages + 1;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('CUSTOMER_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);
    DBMS_OUTPUT.PUT_LINE(' - Age groups refreshed: ' || v_ages
        || '  (Type 1, in place)');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in CUSTOMER_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/
