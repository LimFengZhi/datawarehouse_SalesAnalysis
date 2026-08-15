-- ===================================================================
-- 05_init_branch_expense_fact.sql   BRANCH_EXPENSE_FACT
-- Grain: one row per branch per utility category per period (1,440)
-- Source: BRANCH_EXPENSE
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
    dd.date_key,
    bd.branch_key,
    ud.branch_utils_key,

    be.br_exp_ID,                                 -- degenerate dim / PK
    be.billing_period,                            -- 'YYYY-MM'

    -- Measure. Never negative, never NULL.
    ROUND(
        CASE WHEN be.payment_amount IS NULL OR be.payment_amount < 0
             THEN 0 ELSE be.payment_amount END, 2)
                                                   AS payment_amount

FROM branch_expense    be
JOIN date_dim          dd ON dd.cal_date   = TRUNC(be.payment_date)
JOIN branch_dim        bd ON bd.br_ID      = be.br_ID
                         AND bd.is_current_flag = 'Y'
JOIN branch_utils_dim  ud ON ud.br_utils_ID = be.br_utils_ID;
-- branch_utils_dim is a Type 1 lookup: no is_current_flag to filter on

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- br_exp_ID from the source is the PK and a degenerate dimension.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_br_expense_fact_initial AS
    v_count   NUMBER;
    v_source  NUMBER;
    v_dropped NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM branch_expense_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('BRANCH_EXPENSE_FACT already contains data. '
            || 'Delete it first if you intend to reload.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_source FROM branch_expense;

    INSERT INTO branch_expense_fact (
        date_key, branch_key, branch_utils_key,
        br_exp_ID, billing_period, payment_amount
    )
    SELECT
        date_key, branch_key, branch_utils_key,
        br_exp_ID, billing_period, payment_amount
    FROM branch_expense_fact_staging_v;

    v_count   := SQL%ROWCOUNT;
    v_dropped := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_EXPENSE_FACT initial load completed: '
        || v_count || ' records inserted.');

    IF v_dropped <> 0 THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: ' || v_dropped
            || ' source rows did NOT load - a dimension lookup failed.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('All ' || v_source
            || ' source rows resolved every dimension key.');
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

-- Expect 1440 in both columns  (5 branches x 6 utilities x 48 months)
SELECT (SELECT COUNT(*) FROM branch_expense_fact) AS fact_rows,
       (SELECT COUNT(*) FROM branch_expense)      AS source_rows
FROM dual;

-- Which lookup failed, if any. Both must return 0.
SELECT COUNT(*) AS no_date FROM branch_expense be
WHERE NOT EXISTS (SELECT 1 FROM date_dim dd
                  WHERE dd.cal_date = TRUNC(be.payment_date));

SELECT COUNT(*) AS no_utils FROM branch_expense be
WHERE NOT EXISTS (SELECT 1 FROM branch_utils_dim ud
                  WHERE ud.br_utils_ID = be.br_utils_ID);

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