-- ===================================================================
-- 04_init_product_dim.sql       PRODUCT_DIM  (SCD Type 2)
-- Source: PRODUCT (OLTP, 43 rows)
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW product_staging_v AS
SELECT
    p.product_ID,

    -- Name: trim, collapse repeated spaces. Keep source casing for
    -- product names (they contain brand styling), just tidy whitespace.
    -- (The OLTP brand column is not carried into the dimension.)
    CASE
        WHEN p.product_name IS NULL OR LENGTH(TRIM(p.product_name)) < 2
            THEN 'Unknown Product'
        ELSE REGEXP_REPLACE(TRIM(p.product_name), '\s+', ' ')
    END                                            AS clean_product_name,

    -- Category: canonical spelling for the 10 real categories
    CASE
        WHEN UPPER(TRIM(p.product_category)) IN ('CLEANSER','CLEANSERS',
                                                 'FACE WASH')
            THEN 'Cleanser'
        WHEN UPPER(TRIM(p.product_category)) IN ('SERUM','SERUMS','AMPOULE')
            THEN 'Serum'
        WHEN UPPER(TRIM(p.product_category)) IN ('FACE MASK','MASK','MASKS',
                                                 'SHEET MASK')
            THEN 'Face Mask'
        WHEN UPPER(TRIM(p.product_category)) IN ('MOISTURIZER','MOISTURISER',
                                                 'CREAM')
            THEN 'Moisturizer'
        WHEN UPPER(TRIM(p.product_category)) IN ('TONER','TONERS','TONIC')
            THEN 'Toner'
        WHEN UPPER(TRIM(p.product_category)) IN ('SUNSCREEN','SUN SCREEN',
                                                 'SPF','SUNBLOCK')
            THEN 'Sunscreen'
        WHEN UPPER(TRIM(p.product_category)) IN ('EXFOLIATOR','EXFOLIANT',
                                                 'SCRUB')
            THEN 'Exfoliator'
        WHEN UPPER(TRIM(p.product_category)) IN ('EYE CREAM','EYE',
                                                 'EYE TREATMENT')
            THEN 'Eye Cream'
        WHEN UPPER(TRIM(p.product_category)) IN ('FACIAL OIL/ESSENCE',
                                                 'FACIAL OIL','ESSENCE',
                                                 'OIL')
            THEN 'Facial Oil/Essence'
        WHEN UPPER(TRIM(p.product_category)) IN ('SPOT TREATMENT','SPOT',
                                                 'ACNE SPOT')
            THEN 'Spot Treatment'
        WHEN p.product_category IS NULL
          OR LENGTH(TRIM(p.product_category)) = 0
            THEN 'Uncategorised'
        ELSE INITCAP(TRIM(p.product_category))
    END                                            AS clean_product_category,

    -- Price: never negative, never NULL
    CASE
        WHEN p.product_unit_price IS NULL OR p.product_unit_price < 0
            THEN 0
        ELSE p.product_unit_price
    END                                            AS clean_product_price,

    -- ---------- data quality flags ----------
    CASE WHEN p.product_name IS NULL
           OR LENGTH(TRIM(p.product_name)) < 2
         THEN 'Y' ELSE 'N' END                     AS name_cleaned,
    CASE WHEN p.product_category IS NULL
           OR LENGTH(TRIM(p.product_category)) = 0
         THEN 'Y' ELSE 'N' END                     AS category_defaulted,
    CASE WHEN p.product_unit_price IS NULL OR p.product_unit_price < 0
         THEN 'Y' ELSE 'N' END                     AS price_corrected
FROM product p
WHERE p.product_ID IS NOT NULL;

-- ===================================================================
-- SECTION 2: CREATE SEQUENCE
-- ===================================================================
CREATE SEQUENCE seq_product_key
    START WITH 2000
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_product_dim_initial AS
    v_count  NUMBER;
    v_errors NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM product_dim;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('PRODUCT_DIM already contains data. '
            || 'Delete it first if you intend to reload.');
        RETURN;
    END IF;

    INSERT INTO product_dim (
        product_key, product_ID, product_name,
        product_category, product_unit_price,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_product_key.NEXTVAL,
        product_ID, clean_product_name,
        clean_product_category, clean_product_price,
        DATE '2018-01-01',   -- first version: start of recorded history
        DATE '9999-12-31',
        'Y'
    FROM product_staging_v;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM product_staging_v
    WHERE name_cleaned = 'Y'
       OR category_defaulted = 'Y' OR price_corrected = 'Y';

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('PRODUCT_DIM initial load completed: '
        || v_count || ' records inserted.');
    DBMS_OUTPUT.PUT_LINE('Data quality corrections applied: '
        || v_errors || ' records had issues corrected.');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in PRODUCT_DIM initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN
-- ===================================================================
EXEC load_product_dim_initial;
