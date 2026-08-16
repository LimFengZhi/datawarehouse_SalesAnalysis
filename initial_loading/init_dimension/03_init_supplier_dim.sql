-- ===================================================================
-- 03_init_supplier_dim.sql      SUPPLIER_DIM  (SCD Type 2)
-- Source: SUPPLIER (OLTP, 6 rows)
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW supplier_staging_v AS
SELECT
    s.sup_ID,

    -- Name: trim, collapse spaces, title case, standardise the
    -- Malaysian company suffix ('Sdn. Bhd.' -> 'Sdn Bhd').
    CASE
        WHEN s.sup_name IS NULL OR LENGTH(TRIM(s.sup_name)) < 2
            THEN 'Unknown Supplier'
        ELSE REPLACE(
                 INITCAP(REGEXP_REPLACE(TRIM(s.sup_name), '\s+', ' ')),
             'Sdn. Bhd.', 'Sdn Bhd')
    END                                            AS clean_sup_name,

    -- Phone: strip every non-digit, then default if nothing is left.
    -- Source format is '03-56781234' -> '0356781234'
    CASE
        WHEN s.sup_phone IS NULL
          OR LENGTH(REGEXP_REPLACE(s.sup_phone, '[^0-9]', '')) = 0
            THEN '0000000000'
        ELSE REGEXP_REPLACE(s.sup_phone, '[^0-9]', '')
    END                                            AS clean_sup_phone,

    -- Email: validate, otherwise generate
    CASE
        WHEN s.sup_email IS NULL
          OR NOT REGEXP_LIKE(TRIM(s.sup_email),
                 '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
            THEN 'supplier' || TO_CHAR(s.sup_ID) || '@glowbeauty.com.my'
        ELSE LOWER(TRIM(s.sup_email))
    END                                            AS clean_sup_email,

    -- ---------- data quality flags ----------
    CASE WHEN s.sup_name IS NULL OR LENGTH(TRIM(s.sup_name)) < 2
         THEN 'Y' ELSE 'N' END                     AS name_cleaned,
    CASE WHEN s.sup_email IS NULL
           OR NOT REGEXP_LIKE(TRIM(s.sup_email),
                  '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
         THEN 'Y' ELSE 'N' END                     AS email_generated,
    CASE WHEN s.sup_phone IS NULL
           OR LENGTH(REGEXP_REPLACE(s.sup_phone, '[^0-9]', '')) = 0
         THEN 'Y' ELSE 'N' END                     AS phone_defaulted
FROM supplier s
WHERE s.sup_ID IS NOT NULL;

-- ===================================================================
-- SECTION 2: CREATE SEQUENCE  (500..999 range - 6 suppliers)
-- ===================================================================
-- DROP SEQUENCE seq_supplier_key;
CREATE SEQUENCE seq_supplier_key
    START WITH 500
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_supplier_dim_initial AS
    v_count  NUMBER;
    v_errors NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM supplier_dim;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('SUPPLIER_DIM already contains data. '
            || 'Delete it first if you intend to reload.');
        RETURN;
    END IF;

    INSERT INTO supplier_dim (
        supplier_key, sup_ID, sup_name, sup_phone, sup_email,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_supplier_key.NEXTVAL,
        sup_ID, clean_sup_name, clean_sup_phone, clean_sup_email,
        DATE '2019-01-01',   -- first version: start of recorded history
        DATE '9999-12-31',
        'Y'
    FROM supplier_staging_v;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM supplier_staging_v
    WHERE name_cleaned = 'Y' OR email_generated = 'Y'
       OR phone_defaulted = 'Y';

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUPPLIER_DIM initial load completed: '
        || v_count || ' records inserted.');
    DBMS_OUTPUT.PUT_LINE('Data quality corrections applied: '
        || v_errors || ' records had issues corrected.');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in SUPPLIER_DIM initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN
-- Verification queries live in ..\validate_initial_loading.sql
-- ===================================================================
EXEC load_supplier_dim_initial;
