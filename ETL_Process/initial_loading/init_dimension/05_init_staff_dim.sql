-- ===================================================================
-- 05_init_staff_dim.sql         STAFF_DIM  (SCD Type 2)
-- Source: STAFF (OLTP, 96 rows)
-- NOTE: st_name is DERIVED (first + last) - it does not exist
--       ready-made in the source.
--       st_position is the single job-title column (Branch Manager /
--       Senior Therapist / Beauty Therapist / Sales Assistant /
--       Receptionist / Cashier). The OLTP no longer has st_role or
--       st_salary, and staff_dim no longer carries br_ID, city, state,
--       gender, age or hire date - facts that need the branch resolve
--       it from the OLTP transaction (orders.br_ID / reservation.br_ID
--       / staff.br_ID in the salary staging view).
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW staff_staging_v AS
SELECT
    s.st_ID,

    -- Name: combine first + last, trim both, collapse spaces, title case
    CASE
        WHEN (s.st_first_name IS NULL OR LENGTH(TRIM(s.st_first_name)) = 0)
         AND (s.st_last_name  IS NULL OR LENGTH(TRIM(s.st_last_name))  = 0)
            THEN 'Unknown Staff'
        ELSE INITCAP(REGEXP_REPLACE(
                 TRIM(TRIM(s.st_first_name) || ' ' || TRIM(s.st_last_name)),
                 '\s+', ' '))
    END                                            AS clean_st_name,

    -- Position (job title): the 6 real titles, plus common abbreviations
    CASE
        WHEN UPPER(TRIM(s.st_position)) IN ('BEAUTY THERAPIST','THERAPIST',
                                            'BEAUTICIAN')
            THEN 'Beauty Therapist'
        WHEN UPPER(TRIM(s.st_position)) IN ('SENIOR THERAPIST','SNR THERAPIST',
                                            'SR THERAPIST')
            THEN 'Senior Therapist'
        WHEN UPPER(TRIM(s.st_position)) IN ('SALES ASSISTANT','SALES ASST',
                                            'SALES')
            THEN 'Sales Assistant'
        WHEN UPPER(TRIM(s.st_position)) IN ('RECEPTIONIST','RECEPTION',
                                            'FRONT DESK')
            THEN 'Receptionist'
        WHEN UPPER(TRIM(s.st_position)) IN ('CASHIER','CASH','TELLER')
            THEN 'Cashier'
        WHEN UPPER(TRIM(s.st_position)) IN ('BRANCH MANAGER','MANAGER','BM',
                                            'OUTLET MANAGER')
            THEN 'Branch Manager'
        WHEN s.st_position IS NULL OR LENGTH(TRIM(s.st_position)) = 0
            THEN 'General Staff'
        ELSE INITCAP(TRIM(s.st_position))
    END                                            AS clean_st_position,

    -- Email: validate, otherwise generate a deterministic address
    CASE
        WHEN s.st_email IS NULL
          OR NOT REGEXP_LIKE(TRIM(s.st_email),
                 '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
            THEN 'staff' || TO_CHAR(s.st_ID) || '@glowbeauty.com.my'
        ELSE LOWER(TRIM(s.st_email))
    END                                            AS clean_st_email,

    -- Status: source has Active / Resigned; OLTP also allows Inactive
    CASE
        WHEN UPPER(TRIM(s.st_status)) IN ('ACTIVE','A','WORKING')
            THEN 'Active'
        WHEN UPPER(TRIM(s.st_status)) IN ('RESIGNED','R','LEFT','QUIT')
            THEN 'Resigned'
        WHEN UPPER(TRIM(s.st_status)) IN ('INACTIVE','I','SUSPENDED')
            THEN 'Inactive'
        WHEN s.st_status IS NULL OR LENGTH(TRIM(s.st_status)) = 0
            THEN 'Active'
        ELSE INITCAP(TRIM(s.st_status))
    END                                            AS clean_st_status,

    -- ---------- data quality flags ----------
    CASE WHEN (s.st_first_name IS NULL OR LENGTH(TRIM(s.st_first_name)) = 0)
           OR (s.st_last_name  IS NULL OR LENGTH(TRIM(s.st_last_name))  = 0)
         THEN 'Y' ELSE 'N' END                     AS name_cleaned,
    CASE WHEN s.st_email IS NULL
           OR NOT REGEXP_LIKE(TRIM(s.st_email),
                  '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
         THEN 'Y' ELSE 'N' END                     AS email_generated,
    CASE WHEN s.st_position IS NULL OR LENGTH(TRIM(s.st_position)) = 0
         THEN 'Y' ELSE 'N' END                     AS position_defaulted,
    CASE WHEN s.st_status IS NULL OR LENGTH(TRIM(s.st_status)) = 0
         THEN 'Y' ELSE 'N' END                     AS status_defaulted
FROM staff s
WHERE s.st_ID IS NOT NULL;

-- ===================================================================
-- SECTION 2: CREATE SEQUENCE
-- ===================================================================
-- DROP SEQUENCE seq_staff_key;
CREATE SEQUENCE seq_staff_key
    START WITH 5000
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_staff_dim_initial AS
    v_count  NUMBER;
    v_errors NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM staff_dim;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('STAFF_DIM already contains data. '
            || 'Delete it first if you intend to reload.');
        RETURN;
    END IF;

    INSERT INTO staff_dim (
        staff_key, st_ID, st_name, st_email, st_position, st_status,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_staff_key.NEXTVAL,
        st_ID, clean_st_name, clean_st_email, clean_st_position,
        clean_st_status,
        DATE '2019-01-01',   -- first version: the first sales year (facts start 2019-01-01)
        DATE '9999-12-31',
        'Y'
    FROM staff_staging_v;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM staff_staging_v
    WHERE name_cleaned = 'Y' OR email_generated = 'Y'
       OR position_defaulted = 'Y' OR status_defaulted = 'Y';

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('STAFF_DIM initial load completed: '
        || v_count || ' records inserted.');
    DBMS_OUTPUT.PUT_LINE('Data quality corrections applied: '
        || v_errors || ' records had issues corrected.');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in STAFF_DIM initial load: ' || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN
-- ===================================================================
EXEC load_staff_dim_initial;
