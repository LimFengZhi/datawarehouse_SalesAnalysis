-- ===================================================================
-- 02_init_branch_utils_dim.sql   BRANCH_UTILS_DIM  (SCD Type 1 lookup)
-- Source: BRANCH_UTILS_CATEGORY (OLTP, 6 rows)
-- NOTE: this dimension has NO effective dates / is_current_flag -
--       it is a Type 1 lookup, so the load is simpler than the others.
--       util_category is DERIVED (Fixed vs Variable cost).
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW branch_utils_staging_v AS
SELECT
    u.br_utils_ID,

    -- Name: trim, collapse spaces, canonical spelling
    CASE
        WHEN UPPER(TRIM(u.util_name)) IN ('RENT','RENTAL')
            THEN 'Rent'
        WHEN UPPER(TRIM(u.util_name)) IN ('ELECTRICITY','ELECTRIC','POWER',
                                          'TNB')
            THEN 'Electricity'
        WHEN UPPER(TRIM(u.util_name)) IN ('WATER','WATER SUPPLY')
            THEN 'Water'
        WHEN UPPER(TRIM(u.util_name)) IN ('INTERNET','BROADBAND','WIFI')
            THEN 'Internet'
        WHEN UPPER(TRIM(u.util_name)) IN ('MAINTENANCE','MAINTENENCE',
                                          'UPKEEP','REPAIR')
            THEN 'Maintenance'
        WHEN UPPER(TRIM(u.util_name)) IN ('WASTE MANAGEMENT','WASTE',
                                          'GARBAGE','RUBBISH')
            THEN 'Waste Management'
        WHEN u.util_name IS NULL OR LENGTH(TRIM(u.util_name)) = 0
            THEN 'Unknown'
        ELSE INITCAP(REGEXP_REPLACE(TRIM(u.util_name), '\s+', ' '))
    END                                            AS clean_util_name,

    -- DERIVED: does this cost change with activity, or is it a flat bill?
    -- Used to split fixed vs variable overhead in branch profitability.
    CASE
        WHEN UPPER(TRIM(u.util_name)) IN ('RENT','RENTAL','INTERNET',
                                          'BROADBAND','WIFI',
                                          'WASTE MANAGEMENT','WASTE')
            THEN 'Fixed'
        WHEN UPPER(TRIM(u.util_name)) IN ('ELECTRICITY','ELECTRIC','POWER',
                                          'WATER','MAINTENANCE','UPKEEP',
                                          'REPAIR')
            THEN 'Variable'
        ELSE 'Unknown'
    END                                            AS derived_util_category,

    -- ---------- data quality flags ----------
    CASE WHEN u.util_name IS NULL OR LENGTH(TRIM(u.util_name)) = 0
         THEN 'Y' ELSE 'N' END                     AS name_defaulted
FROM branch_utils_category u
WHERE u.br_utils_ID IS NOT NULL;

-- ===================================================================
-- SECTION 2: CREATE SEQUENCE  (100..999 range - 6 categories)
-- ===================================================================
-- DROP SEQUENCE seq_branch_utils_key;
CREATE SEQUENCE seq_branch_utils_key
    START WITH 100
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_branch_utils_dim_initial AS
    v_count  NUMBER;
    v_errors NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM branch_utils_dim;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('BRANCH_UTILS_DIM already contains data. '
            || 'Delete it first if you intend to reload.');
        RETURN;
    END IF;

    INSERT INTO branch_utils_dim (
        branch_utils_key, br_utils_ID, util_name, util_category
    )
    SELECT
        seq_branch_utils_key.NEXTVAL,
        br_utils_ID, clean_util_name, derived_util_category
    FROM branch_utils_staging_v;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM branch_utils_staging_v
    WHERE name_defaulted = 'Y';

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_UTILS_DIM initial load completed: '
        || v_count || ' records inserted.');
    DBMS_OUTPUT.PUT_LINE('Data quality corrections applied: '
        || v_errors || ' records had issues corrected.');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in BRANCH_UTILS_DIM initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN
-- Verification queries live in ..\validate_initial_loading.sql
-- ===================================================================
EXEC load_branch_utils_dim_initial;
