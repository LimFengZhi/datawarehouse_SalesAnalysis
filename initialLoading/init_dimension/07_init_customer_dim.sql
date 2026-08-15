-- ===================================================================
-- 07_init_customer_dim.sql      CUSTOMER_DIM  (SCD Type 2)
-- Source: CUSTOMER (OLTP, 26,000 rows) - the largest dimension
-- NOTE: cus_name is DERIVED (first + last).
--       cus_age_band is DERIVED from cus_age.
--       cus_age is cross-checked against cus_DOB: if the stored age
--       disagrees with the birth date, the birth date wins.
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

    -- Age: trust the birth date over the stored age where possible.
    -- Falls back to cus_age, then to NULL. Anything outside 1..120 is
    -- treated as bad data.
    CASE
        WHEN c.cus_DOB IS NOT NULL
             AND c.cus_DOB <= SYSDATE
             AND c.cus_DOB >= DATE '1900-01-01'
            THEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB) / 12)
        WHEN c.cus_age BETWEEN 1 AND 120
            THEN c.cus_age
        ELSE NULL
    END                                            AS clean_cus_age,

    -- DERIVED age band, from the same cleaned age
    CASE
        WHEN c.cus_DOB IS NOT NULL AND c.cus_DOB <= SYSDATE
             AND c.cus_DOB >= DATE '1900-01-01'
        THEN
            CASE
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) < 18
                    THEN 'Under 18'
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) <= 24
                    THEN '18-24'
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) <= 34
                    THEN '25-34'
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) <= 44
                    THEN '35-44'
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) <= 54
                    THEN '45-54'
                WHEN FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12) <= 64
                    THEN '55-64'
                ELSE '65+'
            END
        WHEN c.cus_age BETWEEN 1 AND 17   THEN 'Under 18'
        WHEN c.cus_age BETWEEN 18 AND 24  THEN '18-24'
        WHEN c.cus_age BETWEEN 25 AND 34  THEN '25-34'
        WHEN c.cus_age BETWEEN 35 AND 44  THEN '35-44'
        WHEN c.cus_age BETWEEN 45 AND 54  THEN '45-54'
        WHEN c.cus_age BETWEEN 55 AND 64  THEN '55-64'
        WHEN c.cus_age BETWEEN 65 AND 120 THEN '65+'
        ELSE 'Unknown'
    END                                            AS derived_cus_age_band,

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

    -- State: source uses 'Wilayah Persekutuan' for KL
    CASE
        WHEN UPPER(TRIM(c.cus_state)) IN ('WILAYAH PERSEKUTUAN','WP','W.P.',
                                          'WP KUALA LUMPUR','KUALA LUMPUR',
                                          'KL','FEDERAL TERRITORY')
            THEN 'Wilayah Persekutuan'
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

    -- Registration date: no future dates, nothing before the business
    -- existed. Source range is 2018-01-01 .. 2022-12-30.
    CASE
        WHEN c.cus_reg_date IS NULL OR c.cus_reg_date > SYSDATE
            THEN DATE '2018-01-01'
        WHEN c.cus_reg_date < DATE '2000-01-01'
            THEN DATE '2018-01-01'
        ELSE c.cus_reg_date
    END                                            AS clean_cus_reg_date,

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
    CASE WHEN UPPER(TRIM(NVL(c.cus_gender,'X'))) NOT IN ('MALE','FEMALE')
         THEN 'Y' ELSE 'N' END                     AS gender_defaulted,
    -- stored age disagrees with the birth date by more than 1 year
    CASE WHEN c.cus_DOB IS NOT NULL AND c.cus_age IS NOT NULL
           AND ABS(FLOOR(MONTHS_BETWEEN(SYSDATE, c.cus_DOB)/12)
                   - c.cus_age) > 1
         THEN 'Y' ELSE 'N' END                     AS age_recalculated,
    CASE WHEN UPPER(TRIM(NVL(c.cus_loyalty_tier,'X')))
              NOT IN ('BRONZE','SILVER','GOLD','PLATINUM')
         THEN 'Y' ELSE 'N' END                     AS tier_defaulted,
    CASE WHEN c.cus_reg_date IS NULL OR c.cus_reg_date > SYSDATE
           OR c.cus_reg_date < DATE '2000-01-01'
         THEN 'Y' ELSE 'N' END                     AS date_corrected
FROM customer c
WHERE c.cus_ID IS NOT NULL;

-- ===================================================================
-- SECTION 2: CREATE SEQUENCE  (20000 range - 26,000 customers)
-- ===================================================================
-- DROP SEQUENCE seq_customer_key;
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
        customer_key, cus_ID, cus_name, cus_email, cus_gender,
        cus_age, cus_age_band, cus_city, cus_state,
        cus_loyalty_tier, cus_reg_date,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_customer_key.NEXTVAL,
        cus_ID, clean_cus_name, clean_cus_email, clean_cus_gender,
        clean_cus_age, derived_cus_age_band, clean_cus_city,
        clean_cus_state, clean_cus_loyalty_tier, clean_cus_reg_date,
        SYSDATE,
        DATE '9999-12-31',
        'Y'
    FROM customer_staging_v;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM customer_staging_v
    WHERE name_cleaned = 'Y' OR email_generated = 'Y'
       OR gender_defaulted = 'Y' OR age_recalculated = 'Y'
       OR tier_defaulted = 'Y' OR date_corrected = 'Y';

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
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_customer_dim_initial;

-- Expect 26000
SELECT COUNT(*) AS total_rows FROM customer_dim;

-- Expect Bronze 14332, Silver 6936, Gold 3384, Platinum 1348
SELECT cus_loyalty_tier, COUNT(*) AS customers
FROM customer_dim
GROUP BY cus_loyalty_tier
ORDER BY customers DESC;

-- Expect 5 states, none 'Unknown'
SELECT cus_state, COUNT(*) AS customers
FROM customer_dim
GROUP BY cus_state
ORDER BY customers DESC;

-- Age bands should be populated, none 'Unknown'
SELECT cus_age_band, COUNT(*) AS customers,
       MIN(cus_age) AS min_age, MAX(cus_age) AS max_age
FROM customer_dim
GROUP BY cus_age_band
ORDER BY cus_age_band;

-- No orphans, no duplicate natural key
SELECT COUNT(*) AS orphan_rows FROM customer_dim d
WHERE NOT EXISTS (SELECT 1 FROM customer c WHERE c.cus_ID = d.cus_ID);

SELECT COUNT(*) AS duplicated_nk FROM (
    SELECT cus_ID FROM customer_dim
    GROUP BY cus_ID HAVING COUNT(*) > 1
);
