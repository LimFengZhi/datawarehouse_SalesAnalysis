-- ===================================================================
-- 04_init_service_dim.sql       SERVICE_DIM  (SCD Type 2)
-- Source: SERVICE (OLTP, 16 rows)
-- Attributes: serv_name, serv_category, serv_price (all SCD2-tracked).
-- The actual slot length of each booking lives on RESERVATION_FACT
-- (res_duration), not on this dimension.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW service_staging_v AS
SELECT
    s.serv_ID,

    -- Name: trim, collapse repeated spaces, title case
    CASE
        WHEN s.serv_name IS NULL OR LENGTH(TRIM(s.serv_name)) < 2
            THEN 'Unknown Service'
        ELSE INITCAP(REGEXP_REPLACE(TRIM(s.serv_name), '\s+', ' '))
    END                                            AS clean_serv_name,

    -- Category: canonical spelling for the 7 real categories
    CASE
        WHEN UPPER(TRIM(s.serv_category)) IN ('ANTI AGING','ANTI-AGING',
                                              'ANTIAGING','ANTI AGEING')
            THEN 'Anti Aging'
        WHEN UPPER(TRIM(s.serv_category)) IN ('ADD ON','ADD-ON','ADDON',
                                              'ADDITIONAL')
            THEN 'Add On'
        WHEN UPPER(TRIM(s.serv_category)) IN ('ACNE TREATMENT','ACNE')
            THEN 'Acne Treatment'
        WHEN UPPER(TRIM(s.serv_category)) IN ('BASIC FACIAL','BASIC','FACIAL')
            THEN 'Basic Facial'
        WHEN UPPER(TRIM(s.serv_category)) IN ('BRIGHTENING','WHITENING')
            THEN 'Brightening'
        WHEN UPPER(TRIM(s.serv_category)) IN ('DEEP CLEANSING','DEEP CLEAN',
                                              'CLEANSING')
            THEN 'Deep Cleansing'
        WHEN UPPER(TRIM(s.serv_category)) IN ('HYDRATING','HYDRATION',
                                              'MOISTURISING')
            THEN 'Hydrating'
        WHEN s.serv_category IS NULL OR LENGTH(TRIM(s.serv_category)) = 0
            THEN 'Uncategorised'
        ELSE INITCAP(TRIM(s.serv_category))
    END                                            AS clean_serv_category,

    -- Price: never negative, never NULL
    CASE
        WHEN s.serv_price IS NULL OR s.serv_price < 0
            THEN 0
        ELSE s.serv_price
    END                                            AS clean_serv_price,

    -- ---------- data quality flags ----------
    CASE WHEN s.serv_name IS NULL OR LENGTH(TRIM(s.serv_name)) < 2
         THEN 'Y' ELSE 'N' END                     AS name_cleaned,
    CASE WHEN s.serv_category IS NULL
           OR LENGTH(TRIM(s.serv_category)) = 0
         THEN 'Y' ELSE 'N' END                     AS category_defaulted,
    CASE WHEN s.serv_price IS NULL OR s.serv_price < 0
         THEN 'Y' ELSE 'N' END                     AS price_corrected
FROM service s
WHERE s.serv_ID IS NOT NULL;

-- ===================================================================
-- SECTION 2: CREATE SEQUENCE  (1000 range - 16 services)
-- ===================================================================
-- DROP SEQUENCE seq_service_key;
CREATE SEQUENCE seq_service_key
    START WITH 1000
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_service_dim_initial AS
    v_count  NUMBER;
    v_errors NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM service_dim;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('SERVICE_DIM already contains data. '
            || 'Delete it first if you intend to reload.');
        RETURN;
    END IF;

    INSERT INTO service_dim (
        service_key, serv_ID, serv_name, serv_category, serv_price,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_service_key.NEXTVAL,
        serv_ID, clean_serv_name, clean_serv_category, clean_serv_price,
        DATE '2018-01-01',   -- first version: start of recorded history
        DATE '9999-12-31',
        'Y'
    FROM service_staging_v;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM service_staging_v
    WHERE name_cleaned = 'Y' OR category_defaulted = 'Y'
       OR price_corrected = 'Y';

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SERVICE_DIM initial load completed: '
        || v_count || ' records inserted.');
    DBMS_OUTPUT.PUT_LINE('Data quality corrections applied: '
        || v_errors || ' records had issues corrected.');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in SERVICE_DIM initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN
-- Verification queries live in ..\validate_initial_loading.sql
-- ===================================================================
EXEC load_service_dim_initial;
