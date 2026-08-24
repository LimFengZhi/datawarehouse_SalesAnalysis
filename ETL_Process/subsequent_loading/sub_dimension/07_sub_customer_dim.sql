-- ===================================================================
-- 07_sub_customer_dim.sql   CUSTOMER_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses customer_staging_v
--   SECTION 2: no new sequence - reuses seq_customer_key
--   SECTION 3: PROCEDURE - insert new records only
--   SECTION 4: run + verification
--
-- SCOPE: NEW RECORDS ONLY - customers who registered since the last
-- load are added, with cus_name built from first + last and
-- cus_age_group derived from cus_DOB by the view.
--
-- A LOYALTY-TIER UPGRADE ON AN EXISTING CUSTOMER IS NOT HANDLED HERE.
-- That is the single most important SCD Type 2 case in this warehouse:
-- when someone moves Silver -> Gold, orders placed BEFORE the upgrade
-- must still report as Silver, or the tier analysis is meaningless.
-- It belongs to the maintain-SCD2 step.
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
BEGIN
    INSERT INTO customer_dim (
        customer_key, cus_ID, cus_name, cus_email, cus_gender, cus_city,
        cus_state, cus_age_group, cus_loyalty_tier,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_customer_key.NEXTVAL,
        s.cus_ID, s.clean_cus_name, s.clean_cus_email, s.clean_cus_gender,
        s.clean_cus_city, s.clean_cus_state,
        s.derived_cus_age_group, s.clean_cus_loyalty_tier,
        DATE '2019-01-01',   -- first version: the first sales year (facts start 2019-01-01)
        DATE '9999-12-31',
        'Y'
    FROM   customer_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM customer_dim d
                       WHERE d.cus_ID = s.cus_ID);

    v_new := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_total FROM customer_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('CUSTOMER_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New customers inserted : ' || v_new);
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
