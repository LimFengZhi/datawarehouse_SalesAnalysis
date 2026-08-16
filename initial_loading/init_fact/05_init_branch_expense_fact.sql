-- ===================================================================
-- 05_init_branch_expense_fact.sql   BRANCH_EXPENSE_FACT
-- Grain: one row per branch per utility category per period (1,440)
-- Source: BRANCH_EXPENSE
--
--   SECTION 1: staging VIEW - OLTP cleansing ONLY
--   SECTION 2: no sequence   - the PK is the degenerate br_exp_ID
--   SECTION 3: PROCEDURE     - resolves surrogate keys, then inserts
--   SECTION 4: run + verification
--
-- THE VIEW DOES NOT TOUCH THE DIMENSIONS - natural keys out (br_ID,
-- br_utils_ID) and the raw payment_date.
--
-- The last piece of branch profitability: overheads. Combined with
-- branch_utils_dim.util_category ('Fixed' / 'Variable') this splits
-- rent and internet from electricity and maintenance.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW branch_expense_fact_staging_v AS
SELECT
    be.br_exp_ID,                                 -- degenerate dim / PK

    -- ---------- NATURAL keys ----------
    be.br_ID,
    be.br_utils_ID,
    TRUNC(be.payment_date)                         AS payment_date,

    -- ---------- cleansed attributes ----------
    CASE
        WHEN be.billing_period IS NULL
             OR NOT REGEXP_LIKE(TRIM(be.billing_period),
                                '^[0-9]{4}-[0-9]{2}$')
            THEN TO_CHAR(be.payment_date, 'YYYY-MM')
        ELSE TRIM(be.billing_period)
    END                                            AS clean_billing_period,

    -- Measure. Never negative, never NULL.
    ROUND(
        CASE WHEN be.payment_amount IS NULL OR be.payment_amount < 0
             THEN 0 ELSE be.payment_amount END, 2)
                                                   AS clean_payment_amount,

    -- ---------- data quality flags ----------
    CASE WHEN be.payment_amount IS NULL OR be.payment_amount < 0
         THEN 'Y' ELSE 'N' END                     AS amount_corrected,
    CASE WHEN be.billing_period IS NULL
              OR NOT REGEXP_LIKE(TRIM(be.billing_period),
                                 '^[0-9]{4}-[0-9]{2}$')
         THEN 'Y' ELSE 'N' END                     AS period_defaulted

FROM branch_expense be
WHERE be.br_exp_ID    IS NOT NULL
  AND be.br_ID        IS NOT NULL
  AND be.br_utils_ID  IS NOT NULL
  AND be.payment_date IS NOT NULL;

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- br_exp_ID from the source is the PK and a degenerate dimension.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_br_expense_fact_initial AS
    v_count    NUMBER;
    v_errors   NUMBER := 0;
    v_orphaned NUMBER := 0;
    v_source   NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM branch_expense_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('BRANCH_EXPENSE_FACT already contains data. '
            || 'Use load_br_exp_fact_incremental for updates.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_source FROM branch_expense;

    INSERT INTO branch_expense_fact (
        date_key, branch_key, branch_utils_key,
        br_exp_ID, billing_period, payment_amount
    )
    SELECT
        d.date_key,
        b.branch_key,
        u.branch_utils_key,
        ls.br_exp_ID,
        ls.clean_billing_period,
        ls.clean_payment_amount
    FROM branch_expense_fact_staging_v ls
    JOIN date_dim         d ON d.cal_date    = ls.payment_date
    JOIN branch_dim       b ON b.br_ID       = ls.br_ID
                           AND b.is_current_flag = 'Y'
    -- branch_utils_dim is a Type 1 lookup: no is_current_flag to filter
    JOIN branch_utils_dim u ON u.br_utils_ID = ls.br_utils_ID;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   branch_expense_fact_staging_v
    WHERE  amount_corrected = 'Y' OR period_defaulted = 'Y';

    v_orphaned := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_EXPENSE_FACT initial load completed:');
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
        DBMS_OUTPUT.PUT_LINE('Error in BRANCH_EXPENSE_FACT initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_br_expense_fact_initial;

-- Expect 1440 in both  (5 branches x 6 utilities x 48 months)
SELECT (SELECT COUNT(*) FROM branch_expense_fact) AS fact_rows,
       (SELECT COUNT(*) FROM branch_expense)      AS source_rows
FROM dual;

SELECT (SELECT COUNT(*) FROM branch_expense)
     - (SELECT COUNT(*) FROM branch_expense_fact_staging_v) AS rejected_by_view
FROM dual;
-- expect 0

-- Which DIMENSION lookup failed, if any. Both must return 0.
SELECT COUNT(*) AS no_date FROM branch_expense_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                  WHERE d.cal_date = ls.payment_date);

SELECT COUNT(*) AS no_utils FROM branch_expense_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM branch_utils_dim u
                  WHERE u.br_utils_ID = ls.br_utils_ID);

-- Fixed vs variable overhead per branch
SELECT b.br_city, u.util_category,
       ROUND(SUM(f.payment_amount), 2) AS total_expense
FROM branch_expense_fact f
JOIN branch_dim       b ON b.branch_key       = f.branch_key
JOIN branch_utils_dim u ON u.branch_utils_key = f.branch_utils_key
GROUP BY b.br_city, u.util_category
ORDER BY b.br_city, u.util_category;

-- THE RENT-REBATE CHECK. The README says landlords gave rebates during
-- lockdown, so 2020 rent should dip below 2019 and 2021.
SELECT SUBSTR(f.billing_period, 1, 4) AS yr,
       ROUND(SUM(f.payment_amount), 2) AS total_rent
FROM branch_expense_fact f
JOIN branch_utils_dim u ON u.branch_utils_key = f.branch_utils_key
WHERE u.util_name = 'Rent'
GROUP BY SUBSTR(f.billing_period, 1, 4)
ORDER BY yr;
