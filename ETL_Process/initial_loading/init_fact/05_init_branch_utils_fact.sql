-- ===================================================================
-- 05_init_branch_utils_fact.sql   BRANCH_UTILS_FACT
-- Grain: one row per branch per utility category per period
-- Source: BRANCH_UTILS
--
--   SECTION 1: staging VIEW - OLTP cleansing ONLY
--   SECTION 2: no sequence   - PK is composite (date, branch keys +
--                              br_exp_ID); br_exp_ID is unique by grain (no constraint) and
--                              drives the NOT EXISTS
--   SECTION 3: PROCEDURE     - resolves surrogate keys, then inserts
--   SECTION 4: run
--
-- The last piece of branch profitability: overheads. There is NO
-- utilities dimension: util_name (Rent, Electricity, Water, Internet,
-- Maintenance, Waste Management) is carried on the fact row as a
-- degenerate text attribute, canonicalised here in the staging view
-- so the reports can split rent from electricity and maintenance.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW branch_utils_fact_staging_v AS
SELECT
    bu.br_exp_ID,                                 -- degenerate dim / one row per ID

    -- ---------- NATURAL keys ----------
    bu.br_ID,
    TRUNC(bu.payment_date)                         AS payment_date,

    -- ---------- cleansed attributes ----------
    -- Utility name: trim, collapse spaces, canonical spelling. This is
    -- the only place the six category names are enforced - the OLTP
    -- row carries free text.
    CASE
        WHEN UPPER(TRIM(bu.util_name)) IN ('RENT','RENTAL')
            THEN 'Rent'
        WHEN UPPER(TRIM(bu.util_name)) IN ('ELECTRICITY','ELECTRIC','POWER',
                                           'TNB')
            THEN 'Electricity'
        WHEN UPPER(TRIM(bu.util_name)) IN ('WATER','WATER SUPPLY')
            THEN 'Water'
        WHEN UPPER(TRIM(bu.util_name)) IN ('INTERNET','BROADBAND','WIFI')
            THEN 'Internet'
        WHEN UPPER(TRIM(bu.util_name)) IN ('MAINTENANCE','MAINTENENCE',
                                           'UPKEEP','REPAIR')
            THEN 'Maintenance'
        WHEN UPPER(TRIM(bu.util_name)) IN ('WASTE MANAGEMENT','WASTE',
                                           'GARBAGE','RUBBISH')
            THEN 'Waste Management'
        WHEN bu.util_name IS NULL OR LENGTH(TRIM(bu.util_name)) = 0
            THEN 'Unknown'
        ELSE INITCAP(REGEXP_REPLACE(TRIM(bu.util_name), '\s+', ' '))
    END                                            AS clean_util_name,

    CASE
        WHEN bu.billing_period IS NULL
             OR NOT REGEXP_LIKE(TRIM(bu.billing_period),
                                '^[0-9]{4}-[0-9]{2}$')
            THEN TO_CHAR(bu.payment_date, 'YYYY-MM')
        ELSE TRIM(bu.billing_period)
    END                                            AS clean_billing_period,

    -- Measure. Never negative, never NULL.
    ROUND(
        CASE WHEN bu.payment_amt IS NULL OR bu.payment_amt < 0
             THEN 0 ELSE bu.payment_amt END, 2)
                                                   AS clean_payment_amt,

    -- ---------- data quality flags ----------
    CASE WHEN bu.util_name IS NULL OR LENGTH(TRIM(bu.util_name)) = 0
         THEN 'Y' ELSE 'N' END                     AS name_defaulted,
    CASE WHEN bu.payment_amt IS NULL OR bu.payment_amt < 0
         THEN 'Y' ELSE 'N' END                     AS amount_corrected,
    CASE WHEN bu.billing_period IS NULL
              OR NOT REGEXP_LIKE(TRIM(bu.billing_period),
                                 '^[0-9]{4}-[0-9]{2}$')
         THEN 'Y' ELSE 'N' END                     AS period_defaulted

FROM branch_utils bu
WHERE bu.br_exp_ID    IS NOT NULL
  AND bu.br_ID        IS NOT NULL
  AND bu.payment_date IS NOT NULL;

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_branch_utils_fact_initial AS
    v_count    NUMBER;
    v_errors   NUMBER := 0;
    v_orphaned NUMBER := 0;
    v_source   NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM branch_utils_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('BRANCH_UTILS_FACT already contains data. '
            || 'Use load_br_utils_fact_incremental for updates.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_source FROM branch_utils;

    INSERT INTO branch_utils_fact (
        date_key, branch_key, br_exp_ID,
        util_name, billing_period, payment_amt
    )
    SELECT
        d.date_key,
        b.branch_key,
        ls.br_exp_ID,
        ls.clean_util_name,
        ls.clean_billing_period,
        ls.clean_payment_amt
    -- The SCD2 join picks the version in force on the payment date.
    FROM branch_utils_fact_staging_v ls
    JOIN date_dim   d ON d.cal_date = ls.payment_date
    JOIN branch_dim b ON b.br_ID    = ls.br_ID;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   branch_utils_fact_staging_v
    WHERE  name_defaulted = 'Y' OR amount_corrected = 'Y'
       OR  period_defaulted = 'Y';

    v_orphaned := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_UTILS_FACT initial load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Records inserted        : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Data quality corrections: ' || v_errors);
    DBMS_OUTPUT.PUT_LINE(' - Source rows not loaded  : ' || v_orphaned);

    IF v_orphaned <> 0 THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: a dimension lookup failed for '
            || 'those rows. Run the orphan checks in SECTION 4.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in BRANCH_UTILS_FACT initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN
-- ===================================================================
EXEC load_branch_utils_fact_initial;
