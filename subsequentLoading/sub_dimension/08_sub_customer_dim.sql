-- ===================================================================
-- 08_sub_customer_dim.sql   CUSTOMER_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses customer_staging_v
--   SECTION 2: no new sequence - reuses seq_customer_key
--   SECTION 3: PROCEDURE - insert new records only
--   SECTION 4: run + verification
--
-- SCOPE: NEW RECORDS ONLY - customers who registered since the last
-- load are added, with cus_name built from first + last and
-- cus_age_band derived by the view.
--
-- A LOYALTY-TIER UPGRADE ON AN EXISTING CUSTOMER IS NOT HANDLED HERE.
-- That is the single most important SCD Type 2 case in this warehouse:
-- when someone moves Silver -> Gold, orders placed BEFORE the upgrade
-- must still report as Silver, or the tier analysis is meaningless.
-- It belongs to the maintain-SCD2 step.
--
-- cus_age and cus_age_band drift every birthday, so in that step they
-- must be Type 1 (overwrite in place) and kept OUT of Type 2 change
-- detection - otherwise 26,000 customers gain a version every year.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - REUSED, NOT RECREATED
-- customer_staging_v is defined in
--   initialLoading\init_dimension\07_init_customer_dim.sql
-- It combines first + last name, validates email, cross-checks age
-- against DOB, derives the 7 age bands and normalises state and tier.
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - REUSED, NOT RECREATED
-- seq_customer_key already issued keys 20000..45999. Continues at 46000.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_customer_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
BEGIN
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
        TRUNC(SYSDATE),
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

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_customer_dim_incremental;

-- One row per natural key. Must return 0.
SELECT COUNT(*) AS duplicated_natural_keys FROM (
    SELECT cus_ID FROM customer_dim
    GROUP BY cus_ID HAVING COUNT(*) > 1
);

-- Tier distribution.
-- Expect Bronze 14332, Silver 6936, Gold 3384, Platinum 1348.
SELECT cus_loyalty_tier, COUNT(*) AS customers
FROM   customer_dim
GROUP BY cus_loyalty_tier
ORDER BY customers DESC;

-- 5 states, none 'Unknown'
SELECT cus_state, COUNT(*) AS customers
FROM   customer_dim
GROUP BY cus_state
ORDER BY customers DESC;

-- Every OLTP customer is represented
SELECT COUNT(*) AS missing_from_dim
FROM   customer c
WHERE  NOT EXISTS (SELECT 1 FROM customer_dim d
                   WHERE d.cus_ID = c.cus_ID);
-- expect 0

-- Facts must still resolve
SELECT COUNT(*) AS orphaned_facts
FROM   order_fact f
WHERE  NOT EXISTS (SELECT 1 FROM customer_dim d
                   WHERE d.customer_key = f.customer_key);
-- expect 0

-- Re-run the EXEC above: must report 0 new customers inserted.
