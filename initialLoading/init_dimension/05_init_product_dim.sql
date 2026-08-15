-- ===================================================================
-- 05_init_product_dim.sql       PRODUCT_DIM  (SCD Type 2)
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
    CASE
        WHEN p.product_name IS NULL OR LENGTH(TRIM(p.product_name)) < 2
            THEN 'Unknown Product'
        ELSE REGEXP_REPLACE(TRIM(p.product_name), '\s+', ' ')
    END                                            AS clean_product_name,

    -- Brand: 7 real brands, mixed-case names kept exactly as branded
    CASE
        WHEN UPPER(TRIM(p.product_brand)) = 'PUREGLOW'  THEN 'PureGlow'
        WHEN UPPER(TRIM(p.product_brand)) = 'HYDRALUXE' THEN 'HydraLuxe'
        WHEN UPPER(TRIM(p.product_brand)) = 'DERMAVITA' THEN 'DermaVita'
        WHEN UPPER(TRIM(p.product_brand)) = 'SUNGUARD'  THEN 'SunGuard'
        WHEN UPPER(TRIM(p.product_brand)) = 'CLEARME'   THEN 'ClearMe'
        WHEN UPPER(TRIM(p.product_brand)) = 'BOTANIQ'   THEN 'BotaniQ'
        WHEN UPPER(TRIM(p.product_brand)) = 'RENEWLAB'  THEN 'RenewLab'
        WHEN p.product_brand IS NULL
          OR LENGTH(TRIM(p.product_brand)) = 0        THEN 'Unbranded'
        ELSE INITCAP(TRIM(p.product_brand))
    END                                            AS clean_product_brand,

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
    CASE WHEN p.product_brand IS NULL
           OR LENGTH(TRIM(p.product_brand)) = 0
         THEN 'Y' ELSE 'N' END                     AS brand_defaulted,
    CASE WHEN p.product_category IS NULL
           OR LENGTH(TRIM(p.product_category)) = 0
         THEN 'Y' ELSE 'N' END                     AS category_defaulted,
    CASE WHEN p.product_unit_price IS NULL OR p.product_unit_price < 0
         THEN 'Y' ELSE 'N' END                     AS price_corrected
FROM product p
WHERE p.product_ID IS NOT NULL;

-- ===================================================================
-- SECTION 2: CREATE SEQUENCE  (2000 range - 43 products)
-- ===================================================================
-- DROP SEQUENCE seq_product_key;
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
        product_key, product_ID, product_name, product_brand,
        product_category, product_unit_price,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_product_key.NEXTVAL,
        product_ID, clean_product_name, clean_product_brand,
        clean_product_category, clean_product_price,
        SYSDATE,
        DATE '9999-12-31',
        'Y'
    FROM product_staging_v;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM product_staging_v
    WHERE name_cleaned = 'Y' OR brand_defaulted = 'Y'
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
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_product_dim_initial;

-- Expect 43
SELECT COUNT(*) AS total_rows FROM product_dim;

-- Expect 10 categories, none 'Uncategorised'
SELECT product_category, COUNT(*) AS products,
       ROUND(AVG(product_unit_price),2) AS avg_price
FROM product_dim
GROUP BY product_category
ORDER BY products DESC;

-- Expect 7 brands, none 'Unbranded'
SELECT product_brand, COUNT(*) AS products
FROM product_dim
GROUP BY product_brand
ORDER BY products DESC;

-- No orphans, no duplicate natural key
SELECT COUNT(*) AS orphan_rows FROM product_dim d
WHERE NOT EXISTS (SELECT 1 FROM product p
                  WHERE p.product_ID = d.product_ID);

SELECT product_ID, COUNT(*) AS versions FROM product_dim
GROUP BY product_ID HAVING COUNT(*) > 1;
