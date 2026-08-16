-- ===================================================================
-- 06_init_staff_dim.sql         STAFF_DIM  (SCD Type 2)
-- Source: STAFF (OLTP, 96 rows)
-- NOTE: st_name is DERIVED (first + last), st_age is DERIVED from
--       st_DOB - neither exists ready-made in the source.
--       br_ID is passed through UNCHANGED: staff_dim has a FK to
--       branch(br_ID), so it must stay a valid source value.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW staff_staging_v AS
SELECT
    s.st_ID,
    s.br_ID,                                    -- FK to branch, untouched

    -- Name: combine first + last, trim both, collapse spaces, title case
    CASE
        WHEN (s.st_first_name IS NULL OR LENGTH(TRIM(s.st_first_name)) = 0)
         AND (s.st_last_name  IS NULL OR LENGTH(TRIM(s.st_last_name))  = 0)
            THEN 'Unknown Staff'
        ELSE INITCAP(REGEXP_REPLACE(
                 TRIM(TRIM(s.st_first_name) || ' ' || TRIM(s.st_last_name)),
                 '\s+', ' '))
    END                                            AS clean_st_name,

    -- Role: the 6 real roles, plus common abbreviations
    CASE
        WHEN UPPER(TRIM(s.st_role)) IN ('BEAUTY THERAPIST','THERAPIST',
                                        'BEAUTICIAN')
            THEN 'Beauty Therapist'
        WHEN UPPER(TRIM(s.st_role)) IN ('SENIOR THERAPIST','SNR THERAPIST',
                                        'SR THERAPIST')
            THEN 'Senior Therapist'
        WHEN UPPER(TRIM(s.st_role)) IN ('SALES ASSISTANT','SALES ASST',
                                        'SALES')
            THEN 'Sales Assistant'
        WHEN UPPER(TRIM(s.st_role)) IN ('RECEPTIONIST','RECEPTION',
                                        'FRONT DESK')
            THEN 'Receptionist'
        WHEN UPPER(TRIM(s.st_role)) IN ('CASHIER','CASH','TELLER')
            THEN 'Cashier'
        WHEN UPPER(TRIM(s.st_role)) IN ('BRANCH MANAGER','MANAGER','BM',
                                        'OUTLET MANAGER')
            THEN 'Branch Manager'
        WHEN s.st_role IS NULL OR LENGTH(TRIM(s.st_role)) = 0
            THEN 'General Staff'
        ELSE INITCAP(TRIM(s.st_role))
    END                                            AS clean_st_role,

    -- Position / seniority grade: the 5 real grades
    CASE
        WHEN UPPER(TRIM(s.st_position)) IN ('JUNIOR','JNR','JR','ENTRY')
            THEN 'Junior'
        WHEN UPPER(TRIM(s.st_position)) IN ('SENIOR','SNR','SR')
            THEN 'Senior'
        WHEN UPPER(TRIM(s.st_position)) IN ('LEAD','TEAM LEAD','LEADER')
            THEN 'Lead'
        WHEN UPPER(TRIM(s.st_position)) IN ('PRINCIPAL','PRIN')
            THEN 'Principal'
        WHEN UPPER(TRIM(s.st_position)) IN ('MANAGER','MGR','MANAGEMENT')
            THEN 'Manager'
        WHEN s.st_position IS NULL OR LENGTH(TRIM(s.st_position)) = 0
            THEN 'Junior'
        ELSE INITCAP(TRIM(s.st_position))
    END                                            AS clean_st_position,

    -- City
    CASE
        WHEN UPPER(TRIM(s.st_city)) IN ('KUALA LUMPUR','KL','K.L.')
            THEN 'Kuala Lumpur'
        WHEN UPPER(TRIM(s.st_city)) IN ('PETALING JAYA','PJ','P.J.')
            THEN 'Petaling Jaya'
        WHEN UPPER(TRIM(s.st_city)) IN ('JOHOR BAHRU','JOHOR BHARU','JB')
            THEN 'Johor Bahru'
        WHEN UPPER(TRIM(s.st_city)) IN ('GEORGE TOWN','GEORGETOWN','PENANG')
            THEN 'George Town'
        WHEN UPPER(TRIM(s.st_city)) IN ('MELAKA','MALACCA')
            THEN 'Melaka'
        WHEN s.st_city IS NULL OR LENGTH(TRIM(s.st_city)) = 0
            THEN 'Unknown'
        ELSE INITCAP(TRIM(s.st_city))
    END                                            AS clean_st_city,

    -- State: source uses 'Wilayah Persekutuan' for KL
    CASE
        WHEN UPPER(TRIM(s.st_state)) IN ('WILAYAH PERSEKUTUAN','WP','W.P.',
                                         'WP KUALA LUMPUR','KUALA LUMPUR',
                                         'KL','FEDERAL TERRITORY')
            THEN 'Wilayah Persekutuan'
        WHEN UPPER(TRIM(s.st_state)) IN ('SELANGOR','SGR','SEL')
            THEN 'Selangor'
        WHEN UPPER(TRIM(s.st_state)) IN ('JOHOR','JOHORE','JHR',
                                         'JOHOR DARUL TAKZIM')
            THEN 'Johor'
        WHEN UPPER(TRIM(s.st_state)) IN ('PULAU PINANG','PENANG','P. PINANG',
                                         'P.PINANG','PNG','PG')
            THEN 'Pulau Pinang'
        WHEN UPPER(TRIM(s.st_state)) IN ('MELAKA','MALACCA','MLK')
            THEN 'Melaka'
        WHEN s.st_state IS NULL OR LENGTH(TRIM(s.st_state)) = 0
            THEN 'Unknown'
        ELSE INITCAP(TRIM(s.st_state))
    END                                            AS clean_st_state,

    -- Gender: accept single letters and full words
    CASE
        WHEN UPPER(TRIM(s.st_gender)) IN ('FEMALE','F','WOMAN')  THEN 'Female'
        WHEN UPPER(TRIM(s.st_gender)) IN ('MALE','M','MAN')      THEN 'Male'
        ELSE 'Unknown'
    END                                            AS clean_st_gender,

    -- DERIVED: age in whole years from date of birth.
    -- Guarded so a NULL / future / absurd DOB cannot produce a
    -- negative age or overflow NUMBER(3).
    CASE
        WHEN s.st_DOB IS NULL OR s.st_DOB > SYSDATE
             OR s.st_DOB < DATE '1930-01-01'
            THEN NULL
        ELSE FLOOR(MONTHS_BETWEEN(SYSDATE, s.st_DOB) / 12)
    END                                            AS derived_st_age,

    -- Email: validate, otherwise generate a deterministic address
    CASE
        WHEN s.st_email IS NULL
          OR NOT REGEXP_LIKE(TRIM(s.st_email),
                 '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
            THEN 'staff' || TO_CHAR(s.st_ID) || '@glowbeauty.com.my'
        ELSE LOWER(TRIM(s.st_email))
    END                                            AS clean_st_email,

    -- Hire date: no NULLs, no future dates, nothing absurdly old
    CASE
        WHEN s.st_hire_date IS NULL OR s.st_hire_date > SYSDATE
            THEN SYSDATE
        WHEN s.st_hire_date < DATE '1990-01-01'
            THEN DATE '1990-01-01'
        ELSE s.st_hire_date
    END                                            AS clean_st_hire_date,

    -- Salary: never negative, never NULL
    CASE
        WHEN s.st_salary IS NULL OR s.st_salary < 0
            THEN 0
        ELSE s.st_salary
    END                                            AS clean_st_salary,

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
    CASE WHEN s.st_DOB IS NULL OR s.st_DOB > SYSDATE
           OR s.st_DOB < DATE '1930-01-01'
         THEN 'Y' ELSE 'N' END                     AS age_unavailable,
    CASE WHEN s.st_hire_date IS NULL OR s.st_hire_date > SYSDATE
           OR s.st_hire_date < DATE '1990-01-01'
         THEN 'Y' ELSE 'N' END                     AS date_corrected,
    CASE WHEN s.st_salary IS NULL OR s.st_salary < 0
         THEN 'Y' ELSE 'N' END                     AS salary_corrected,
    CASE WHEN UPPER(TRIM(NVL(s.st_gender,'X'))) NOT IN ('MALE','FEMALE')
         THEN 'Y' ELSE 'N' END                     AS gender_defaulted
FROM staff s
WHERE s.st_ID IS NOT NULL;

-- ===================================================================
-- SECTION 2: CREATE SEQUENCE  (5000 range - 96 staff)
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
        staff_key, st_ID, br_ID, st_name, st_role, st_position,
        st_city, st_state, st_gender, st_age, st_email,
        st_hire_date, st_salary, st_status,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_staff_key.NEXTVAL,
        st_ID, br_ID, clean_st_name, clean_st_role, clean_st_position,
        clean_st_city, clean_st_state, clean_st_gender, derived_st_age,
        clean_st_email, clean_st_hire_date, clean_st_salary,
        clean_st_status,
        DATE '2019-01-01',   -- first version: start of recorded history
        DATE '9999-12-31',
        'Y'
    FROM staff_staging_v;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM staff_staging_v
    WHERE name_cleaned = 'Y' OR email_generated = 'Y'
       OR age_unavailable = 'Y' OR date_corrected = 'Y'
       OR salary_corrected = 'Y' OR gender_defaulted = 'Y';

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
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_staff_dim_initial;

-- Expect 96
SELECT COUNT(*) AS total_rows FROM staff_dim;

-- Expect 6 roles: Beauty Therapist 36, Sales Assistant 18,
-- Senior Therapist 16, Receptionist 12, Cashier 9, Branch Manager 5
SELECT st_role, COUNT(*) AS staff_count
FROM staff_dim
GROUP BY st_role
ORDER BY staff_count DESC;

-- Expect Active 93, Resigned 3. No 'Unknown' genders.
SELECT st_status, st_gender, COUNT(*) AS n
FROM staff_dim
GROUP BY st_status, st_gender
ORDER BY st_status, st_gender;

-- Every branch should have exactly 1 Branch Manager
SELECT br_ID, COUNT(*) AS managers
FROM staff_dim
WHERE st_role = 'Branch Manager'
GROUP BY br_ID
ORDER BY br_ID;

-- Derived age must be sensible, never NULL if DOB was good
SELECT MIN(st_age) AS min_age, MAX(st_age) AS max_age,
       COUNT(*) - COUNT(st_age) AS null_ages
FROM staff_dim;

-- No orphans, no duplicate natural key
SELECT COUNT(*) AS orphan_rows FROM staff_dim d
WHERE NOT EXISTS (SELECT 1 FROM staff s WHERE s.st_ID = d.st_ID);

SELECT st_ID, COUNT(*) AS versions FROM staff_dim
GROUP BY st_ID HAVING COUNT(*) > 1;
