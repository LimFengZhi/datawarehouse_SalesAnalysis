-- ===================================================================
-- 06_maintain_customer_dim.sql   CUSTOMER_DIM - MAINTAIN SCD 2 + SCD 1
--
--   SECTION 1: no new view - reuses customer_staging_v
--   SECTION 2: no new sequence - reuses seq_customer_key
--   SECTION 3: PROCEDURE - expire + version (Type 2), then refresh
--              cus_age / cus_age_band in place (Type 1)
--   SECTION 4: run + verification
--
-- SCOPE: CHANGED RECORDS ONLY. New customers belong to
--   sub_dimension\08_sub_customer_dim.sql
--
-- THE MOST IMPORTANT SCD2 CASE IN THIS WAREHOUSE: cus_loyalty_tier.
-- When a customer is upgraded Silver -> Gold, orders placed BEFORE the
-- upgrade must still report as Silver. Type 1 would retroactively make
-- every past order look like Gold and destroy the tier analysis - the
-- one showing Bronze customers spend RM 853 each against Platinum's
-- RM 733 once the loyalty discount is applied.
--
-- cus_age and cus_age_band are EXCLUDED from Type 2. They are derived
-- from cus_DOB against SYSDATE, so versioning on them would add 26,000
-- rows a year. They are refreshed in place as Type 1 in STEP 3.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - reuses customer_staging_v from
--   initial_loading\init_dimension\07_init_customer_dim.sql
--
-- SECTION 2: SEQUENCE - reuses seq_customer_key, continuing from
-- wherever the last load left it.
-- ===================================================================

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
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: expire customers whose meaningful attributes changed.
    -- cus_age / cus_age_band deliberately EXCLUDED - header note.
    -- ---------------------------------------------------------------
    UPDATE customer_dim d
    SET    d.effective_end_date = GREATEST(v_eff - 1,
                                           d.effective_start_date),
           d.is_current_flag    = 'N'
    WHERE  d.is_current_flag = 'Y'
    -- Never version BACKWARDS: expiring a version that starts on or
    -- after the effective date would corrupt the timeline.
    AND    d.effective_start_date < v_eff
    AND EXISTS (
        SELECT 1
        FROM   customer_staging_v s
        WHERE  s.cus_ID = d.cus_ID
          AND (   NVL(s.clean_cus_name, '~')   <> NVL(d.cus_name, '~')
               OR NVL(s.clean_cus_email, '~')  <> NVL(d.cus_email, '~')
               OR NVL(s.clean_cus_gender, '~') <> NVL(d.cus_gender, '~')
               OR NVL(s.clean_cus_city, '~')   <> NVL(d.cus_city, '~')
               OR NVL(s.clean_cus_state, '~')  <> NVL(d.cus_state, '~')
               OR NVL(s.clean_cus_loyalty_tier, '~')
                    <> NVL(d.cus_loyalty_tier, '~')
               OR NVL(s.clean_cus_reg_date, DATE '1900-01-01')
                    <> NVL(d.cus_reg_date, DATE '1900-01-01') ));

    v_expired := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: new version for each customer STEP 1 expired.
    -- ---------------------------------------------------------------
    INSERT INTO customer_dim (
        customer_key, cus_ID, cus_name, cus_email, cus_gender,
        cus_age, cus_age_band, cus_city, cus_state,
        cus_loyalty_tier, cus_reg_date,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_customer_key.NEXTVAL,
        s.cus_ID, s.clean_cus_name, s.clean_cus_email,
        s.clean_cus_gender, s.clean_cus_age, s.derived_cus_age_band,
        s.clean_cus_city, s.clean_cus_state, s.clean_cus_loyalty_tier,
        s.clean_cus_reg_date,
        v_eff,
        DATE '9999-12-31',
        'Y'
    FROM   customer_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM customer_dim d
                       WHERE d.cus_ID = s.cus_ID
                         AND d.is_current_flag = 'Y')
    AND    EXISTS     (SELECT 1 FROM customer_dim d
                       WHERE d.cus_ID = s.cus_ID);

    v_versions := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 3: TYPE 1 refresh of age and age band on CURRENT rows.
    -- Getting a year older is not a business event.
    -- ---------------------------------------------------------------
    UPDATE customer_dim d
    SET   (d.cus_age, d.cus_age_band) =
          (SELECT s.clean_cus_age, s.derived_cus_age_band
           FROM   customer_staging_v s
           WHERE  s.cus_ID = d.cus_ID)
    WHERE  d.is_current_flag = 'Y'
    AND    EXISTS (SELECT 1 FROM customer_staging_v s
                   WHERE s.cus_ID = d.cus_ID
                     AND (   NVL(s.clean_cus_age, -1) <> NVL(d.cus_age, -1)
                          OR NVL(s.derived_cus_age_band, '~')
                               <> NVL(d.cus_age_band, '~') ));

    v_ages := SQL%ROWCOUNT;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('CUSTOMER_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);
    DBMS_OUTPUT.PUT_LINE(' - Ages refreshed     : ' || v_ages
        || '  (Type 1, in place)');

    IF v_expired <> v_versions THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: expired and inserted counts '
            || 'differ - run the integrity checks in SECTION 4.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in CUSTOMER_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION - moved out
-- EXECs live in execute_sub_procedure.sql / execute_sub2.sql.
-- Pass p_effective_date as the date the change ACTUALLY happened,
-- e.g. EXEC maintain_customer_dim_scd2(DATE '2025-01-01');
-- Verification queries live in ..\validate_subsequent_loading.sql
-- ===================================================================
