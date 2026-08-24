-- ===================================================================
-- 06_init_customer_dim.sql      CUSTOMER_DIM  (SCD Type 2)
-- Source: CUSTOMER (OLTP, 25,866 rows in data19_23) - the largest dimension
-- NOTE: cus_name is DERIVED (first + last).
--       cus_age_group is DERIVED from cus_DOB against SYSDATE; a NULL,
--       future or absurd birth date gives 'Unknown'.
--       customer_dim carries no age number and no cus_reg_date
--       (the OLTP has no cus_age column either - only the DOB). cus_gender is Type 2 tracked.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW customer_staging_v AS
SELECT
    c.cus_ID,

    -- Name: combine first + last, trim, collapse spaces, title case
    CASE
        WHEN (c.cus_first_name IS NULL OR LENGTH(TRIM(c.cus_first_name)) = 0)
         AND (c.cus_last_name  IS NULL OR LENGTH(TRIM(c.cus_last_name))  = 0)
            THEN 'Unknown Customer'
        ELSE INITCAP(REGEXP_REPLACE(
                 TRIM(TRIM(c.cus_first_name) || ' ' || TRIM(c.cus_last_name)),
                 '\s+', ' '))
    END                                            AS clean_cus_name,

    -- Email: validate, otherwise generate a deterministic address
    CASE
        WHEN c.cus_email IS NULL
          OR NOT REGEXP_LIKE(TRIM(c.cus_email),
                 '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
            THEN 'customer' || TO_CHAR(c.cus_ID) || '@noemail.local'
        ELSE LOWER(TRIM(c.cus_email))
    END                                            AS clean_cus_email,

    -- Gender
    CASE
        WHEN UPPER(TRIM(c.cus_gender)) IN ('FEMALE','F','WOMAN') THEN 'Female'
        WHEN UPPER(TRIM(c.cus_gender)) IN ('MALE','M','MAN')     THEN 'Male'
        ELSE 'Unknown'
    END                                            AS clean_cus_gender,

    -- DERIVED age group from the birth date against SYSDATE (the OLTP
    -- carries no age column - only cus_DOB). Each group is a NAME plus
    -- its range so reports read naturally. Guarded so a NULL / future /
    -- absurd DOB gives 'Unknown' rather than a negative or overflowing
    -- age.
    CASE
        WHEN c.cus_DOB IS NOT NULL AND c.cus_DOB <= SYSDATE
             AND c.cus_DOB >= DATE '1900-01-01'
        THEN
            CASE
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) < 18
                    THEN 'Teen (<18)'
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) <= 24
                    THEN 'Young Adult (18-24)'
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) <= 34
                    THEN 'Adult (25-34)'
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) <= 44
                    THEN 'Mid Adult (35-44)'
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) <= 54
                    THEN 'Mature (45-54)'
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) <= 64
                    THEN 'Pre-Senior (55-64)'
                ELSE 'Senior (65+)'
            END
        ELSE 'Unknown'
    END                                            AS derived_cus_age_group,

    -- City
    CASE
        WHEN UPPER(TRIM(c.cus_city)) IN ('KUALA LUMPUR','KL','K.L.')
            THEN 'Kuala Lumpur'
        WHEN UPPER(TRIM(c.cus_city)) IN ('PETALING JAYA','PJ','P.J.')
            THEN 'Petaling Jaya'
        WHEN UPPER(TRIM(c.cus_city)) IN ('JOHOR BAHRU','JOHOR BHARU','JB')
            THEN 'Johor Bahru'
        WHEN UPPER(TRIM(c.cus_city)) IN ('GEORGE TOWN','GEORGETOWN','PENANG')
            THEN 'George Town'
        WHEN UPPER(TRIM(c.cus_city)) IN ('MELAKA','MALACCA')
            THEN 'Melaka'
        WHEN c.cus_city IS NULL OR LENGTH(TRIM(c.cus_city)) = 0
            THEN 'Unknown'
        ELSE INITCAP(TRIM(c.cus_city))
    END                                            AS clean_cus_city,

    -- State: the Federal Territory is the canonical spelling; every
    -- legacy variant (the old 'Wilayah Persekutuan' included) folds
    -- into it, so reloading older CSVs still lands on one value.
    CASE
        WHEN UPPER(TRIM(c.cus_state)) IN ('WILAYAH PERSEKUTUAN','WP','W.P.',
                                          'WP KUALA LUMPUR','KUALA LUMPUR',
                                          'KL','FEDERAL TERRITORY',
                                          'FEDERAL TERRITORY OF KUALA LUMPUR',
                                          'FT','FT KUALA LUMPUR')
            THEN 'Federal Territory of Kuala Lumpur'
        WHEN UPPER(TRIM(c.cus_state)) IN ('SELANGOR','SGR','SEL')
            THEN 'Selangor'
        WHEN UPPER(TRIM(c.cus_state)) IN ('JOHOR','JOHORE','JHR',
                                          'JOHOR DARUL TAKZIM')
            THEN 'Johor'
        WHEN UPPER(TRIM(c.cus_state)) IN ('PULAU PINANG','PENANG',
                                          'P. PINANG','P.PINANG','PNG','PG')
            THEN 'Pulau Pinang'
        WHEN UPPER(TRIM(c.cus_state)) IN ('MELAKA','MALACCA','MLK')
            THEN 'Melaka'
        WHEN c.cus_state IS NULL OR LENGTH(TRIM(c.cus_state)) = 0
            THEN 'Unknown'
        ELSE INITCAP(TRIM(c.cus_state))
    END                                            AS clean_cus_state,

    -- Loyalty tier: 4 real tiers. Anything unrecognised -> Bronze
    -- (the entry tier), never NULL, so tier analysis has no gaps.
    CASE
        WHEN UPPER(TRIM(c.cus_loyalty_tier)) IN ('PLATINUM','PLAT')
            THEN 'Platinum'
        WHEN UPPER(TRIM(c.cus_loyalty_tier)) IN ('GOLD','GLD')
            THEN 'Gold'
        WHEN UPPER(TRIM(c.cus_loyalty_tier)) IN ('SILVER','SLV')
            THEN 'Silver'
        WHEN UPPER(TRIM(c.cus_loyalty_tier)) IN ('BRONZE','BRZ','BASIC')
            THEN 'Bronze'
        ELSE 'Bronze'
    END                                            AS clean_cus_loyalty_tier,

    -- ---------- data quality flags ----------
    CASE WHEN (c.cus_first_name IS NULL
               OR LENGTH(TRIM(c.cus_first_name)) = 0)
           OR (c.cus_last_name IS NULL
               OR LENGTH(TRIM(c.cus_last_name)) = 0)
         THEN 'Y' ELSE 'N' END                     AS name_cleaned,
    CASE WHEN c.cus_email IS NULL
           OR NOT REGEXP_LIKE(TRIM(c.cus_email),
                  '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
         THEN 'Y' ELSE 'N' END                     AS email_generated,
    -- birth date missing / future / absurd -> age group 'Unknown'
    CASE WHEN c.cus_DOB IS NULL OR c.cus_DOB > SYSDATE
           OR c.cus_DOB < DATE '1900-01-01'
         THEN 'Y' ELSE 'N' END                     AS age_group_unavailable,
    CASE WHEN UPPER(TRIM(NVL(c.cus_loyalty_tier,'X')))
              NOT IN ('BRONZE','SILVER','GOLD','PLATINUM')
         THEN 'Y' ELSE 'N' END                     AS tier_defaulted
FROM customer c
WHERE c.cus_ID IS NOT NULL;

-- ===================================================================
-- SECTION 2: CREATE SEQUENCE
-- ===================================================================
CREATE SEQUENCE seq_customer_key
    START WITH 20000
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_customer_dim_initial AS
    v_count  NUMBER;
    v_errors NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM customer_dim;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('CUSTOMER_DIM already contains data. '
            || 'Delete it first if you intend to reload.');
        RETURN;
    END IF;

    INSERT INTO customer_dim (
        customer_key, cus_ID, cus_name, cus_email, cus_gender, cus_city,
        cus_state, cus_age_group, cus_loyalty_tier,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_customer_key.NEXTVAL,
        cus_ID, clean_cus_name, clean_cus_email, clean_cus_gender,
        clean_cus_city, clean_cus_state, derived_cus_age_group,
        clean_cus_loyalty_tier,
        DATE '2019-01-01',   -- first version: the first sales year (facts start 2019-01-01)
        DATE '9999-12-31',
        'Y'
    FROM customer_staging_v;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM customer_staging_v
    WHERE name_cleaned = 'Y' OR email_generated = 'Y'
       OR age_group_unavailable = 'Y' OR tier_defaulted = 'Y';

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('CUSTOMER_DIM initial load completed: '
        || v_count || ' records inserted.');
    DBMS_OUTPUT.PUT_LINE('Data quality corrections applied: '
        || v_errors || ' records had issues corrected.');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in CUSTOMER_DIM initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN
-- ===================================================================
EXEC load_customer_dim_initial;
