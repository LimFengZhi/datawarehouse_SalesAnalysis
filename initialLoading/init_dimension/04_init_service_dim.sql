-- ===================================================================
-- 04_init_service_dim.sql       SERVICE_DIM  (SCD Type 2)
-- Source: SERVICE (OLTP, 16 rows)
-- NOTE: serv_duration does NOT exist in the OLTP source. It is
--       DERIVED from RESERVATION_DETAIL by averaging the actual
--       booked slot length (end_time - start_time) per service.
--       -> RESERVATION_DETAIL must be loaded before running this.
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

    -- DERIVED: typical slot length in minutes, from real bookings.
    -- Scalar subquery, rounded to the nearest 5 minutes. Falls back to
    -- 60 if this service has never been booked.
    NVL(
        (SELECT ROUND(AVG((rd.end_time - rd.start_time) * 24 * 60) / 5) * 5
         FROM   reservation_detail rd
         WHERE  rd.serv_ID = s.serv_ID
           AND  rd.end_time > rd.start_time),
        60
    )                                              AS derived_serv_duration,

    -- ---------- data quality flags ----------
    CASE WHEN s.serv_name IS NULL OR LENGTH(TRIM(s.serv_name)) < 2
         THEN 'Y' ELSE 'N' END                     AS name_cleaned,
    CASE WHEN s.serv_category IS NULL
           OR LENGTH(TRIM(s.serv_category)) = 0
         THEN 'Y' ELSE 'N' END                     AS category_defaulted,
    CASE WHEN s.serv_price IS NULL OR s.serv_price < 0
         THEN 'Y' ELSE 'N' END                     AS price_corrected,
    CASE WHEN NOT EXISTS (SELECT 1 FROM reservation_detail rd
                          WHERE rd.serv_ID = s.serv_ID)
         THEN 'Y' ELSE 'N' END                     AS duration_defaulted
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
        serv_duration, effective_start_date, effective_end_date,
        is_current_flag
    )
    SELECT
        seq_service_key.NEXTVAL,
        serv_ID, clean_serv_name, clean_serv_category, clean_serv_price,
        derived_serv_duration,
        DATE '2019-01-01',   -- first version: start of recorded history
        DATE '9999-12-31',
        'Y'
    FROM service_staging_v;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM service_staging_v
    WHERE name_cleaned = 'Y' OR category_defaulted = 'Y'
       OR price_corrected = 'Y' OR duration_defaulted = 'Y';

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
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_service_dim_initial;

-- Expect 16
SELECT COUNT(*) AS total_rows FROM service_dim;

-- Derived duration should look sensible (add-ons short, anti-aging long)
SELECT service_key, serv_name, serv_category, serv_price, serv_duration
FROM service_dim
ORDER BY serv_category, serv_price;

-- Expect 7 categories, none 'Uncategorised'
SELECT serv_category, COUNT(*) AS services, AVG(serv_duration) AS avg_mins
FROM service_dim
GROUP BY serv_category
ORDER BY serv_category;

-- No orphans, no duplicate natural key
SELECT COUNT(*) AS orphan_rows FROM service_dim d
WHERE NOT EXISTS (SELECT 1 FROM service s WHERE s.serv_ID = d.serv_ID);

SELECT serv_ID, COUNT(*) AS versions FROM service_dim
GROUP BY serv_ID HAVING COUNT(*) > 1;
