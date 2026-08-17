-- ===================================================================
-- 01_init_branch_dim.sql        BRANCH_DIM  (SCD Type 2)
-- Source: BRANCH (OLTP, 5 rows)
--   SECTION 1: staging VIEW  - all cleansing / transformation
--   SECTION 2: SEQUENCE      - surrogate key (1..999 range)
--   SECTION 3: PROCEDURE     - initial load
--   SECTION 4: run + verification
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW branch_staging_v AS
SELECT
    b.br_ID,

    -- Name: trim, collapse repeated spaces, title case
    CASE
        WHEN b.br_name IS NULL OR LENGTH(TRIM(b.br_name)) < 2
            THEN 'Unknown Branch'
        ELSE INITCAP(REGEXP_REPLACE(TRIM(b.br_name), '\s+', ' '))
    END                                            AS clean_br_name,

    -- City: map known spellings/abbreviations to one canonical value
    CASE
        WHEN UPPER(TRIM(b.br_city)) IN ('KUALA LUMPUR','KL','K.L.')
            THEN 'Kuala Lumpur'
        WHEN UPPER(TRIM(b.br_city)) IN ('PETALING JAYA','PJ','P.J.')
            THEN 'Petaling Jaya'
        WHEN UPPER(TRIM(b.br_city)) IN ('JOHOR BAHRU','JOHOR BHARU','JB')
            THEN 'Johor Bahru'
        WHEN UPPER(TRIM(b.br_city)) IN ('GEORGE TOWN','GEORGETOWN','PENANG')
            THEN 'George Town'
        WHEN UPPER(TRIM(b.br_city)) IN ('MELAKA','MALACCA')
            THEN 'Melaka'
        WHEN b.br_city IS NULL OR LENGTH(TRIM(b.br_city)) = 0
            THEN 'Unknown'
        ELSE INITCAP(TRIM(b.br_city))
    END                                            AS clean_br_city,

    -- State: same idea. Source uses 'Wilayah Persekutuan' for KL.
    CASE
        WHEN UPPER(TRIM(b.br_state)) IN ('WILAYAH PERSEKUTUAN','WP','W.P.',
                                         'WP KUALA LUMPUR','KUALA LUMPUR',
                                         'KL','FEDERAL TERRITORY')
            THEN 'Wilayah Persekutuan'
        WHEN UPPER(TRIM(b.br_state)) IN ('SELANGOR','SGR','SEL')
            THEN 'Selangor'
        WHEN UPPER(TRIM(b.br_state)) IN ('JOHOR','JOHORE','JHR',
                                         'JOHOR DARUL TAKZIM')
            THEN 'Johor'
        WHEN UPPER(TRIM(b.br_state)) IN ('PULAU PINANG','PENANG','P. PINANG',
                                         'P.PINANG','PNG','PG')
            THEN 'Pulau Pinang'
        WHEN UPPER(TRIM(b.br_state)) IN ('MELAKA','MALACCA','MLK')
            THEN 'Melaka'
        WHEN b.br_state IS NULL OR LENGTH(TRIM(b.br_state)) = 0
            THEN 'Unknown'
        ELSE INITCAP(TRIM(b.br_state))
    END                                            AS clean_br_state,

    -- Email: validate, otherwise generate a deterministic placeholder
    CASE
        WHEN b.br_email IS NULL
          OR NOT REGEXP_LIKE(TRIM(b.br_email),
                 '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
            THEN 'branch' || TO_CHAR(b.br_ID) || '@glowbeauty.com.my'
        ELSE LOWER(TRIM(b.br_email))
    END                                            AS clean_br_email,

    -- ---------- data quality flags ----------
    CASE WHEN b.br_name IS NULL OR LENGTH(TRIM(b.br_name)) < 2
         THEN 'Y' ELSE 'N' END                     AS name_cleaned,
    CASE WHEN b.br_email IS NULL
           OR NOT REGEXP_LIKE(TRIM(b.br_email),
                  '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
         THEN 'Y' ELSE 'N' END                     AS email_generated,
    CASE WHEN b.br_city IS NULL OR b.br_state IS NULL
         THEN 'Y' ELSE 'N' END                     AS location_defaulted
FROM branch b
WHERE b.br_ID IS NOT NULL;

-- ===================================================================
-- SECTION 2: CREATE SEQUENCE  (1..999 range - 5 branches)
-- ===================================================================
-- DROP SEQUENCE seq_branch_key;
CREATE SEQUENCE seq_branch_key
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_branch_dim_initial AS
    v_count  NUMBER;
    v_errors NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM branch_dim;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('BRANCH_DIM already contains data. '
            || 'Delete it first if you intend to reload.');
        RETURN;
    END IF;

    INSERT INTO branch_dim (
        branch_key, br_ID, br_name, br_city, br_state, br_email,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_branch_key.NEXTVAL,
        br_ID, clean_br_name, clean_br_city, clean_br_state,
        clean_br_email,
        DATE '2018-01-01',   -- first version: start of recorded history
        DATE '9999-12-31',
        'Y'                       -- CHECK constraint allows 'Y' or 'N'
    FROM branch_staging_v;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM branch_staging_v
    WHERE name_cleaned = 'Y' OR email_generated = 'Y'
       OR location_defaulted = 'Y';

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_DIM initial load completed: '
        || v_count || ' records inserted.');
    DBMS_OUTPUT.PUT_LINE('Data quality corrections applied: '
        || v_errors || ' records had issues corrected.');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in BRANCH_DIM initial load: ' || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN
-- Verification queries live in ..\validate_initial_loading.sql
-- ===================================================================
EXEC load_branch_dim_initial;
