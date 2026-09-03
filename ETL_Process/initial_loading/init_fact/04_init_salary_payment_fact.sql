-- ===================================================================
-- 04_init_salary_payment_fact.sql   SALARY_PAYMENT_FACT
-- Grain: one row per staff member per pay period
-- Source: SALARY_PAYMENT joined to STAFF
--
--   SECTION 1: staging VIEW - OLTP cleansing ONLY
--   SECTION 2: no sequence   - PK is composite (date, staff, branch
--                              keys + sal_pay_ID); sal_pay_ID is unique by grain (no constraint)
--                              and drives the NOT EXISTS
--   SECTION 3: PROCEDURE     - resolves surrogate keys, then inserts
--   SECTION 4: run
--
-- salary_payment has NO br_ID by design, and staff_dim does NOT carry
-- br_ID either, so the view joins the OLTP STAFF table to expose
-- staff.br_ID as a natural key. That is an OLTP-to-OLTP join - it does
-- NOT couple the view to a dimension. The procedure then resolves
--   staff_key  from staff_dim  by st_ID + payment_date range
--   branch_key from branch_dim by that br_ID + payment_date range
-- Measures: base, bonus, deduction and
--   total_amt = base + bonus - deduction  (net pay)
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW salary_payment_fact_staging_v AS
SELECT
    sp.sal_pay_ID,                                -- degenerate dim / one row per ID

    -- ---------- NATURAL keys ----------
    sp.st_ID,
    st.br_ID,                                     -- via OLTP STAFF, by design
    TRUNC(sp.payment_date)                         AS payment_date,

    -- ---------- cleansed attributes ----------
    CASE
        WHEN sp.pay_period IS NULL
             OR NOT REGEXP_LIKE(TRIM(sp.pay_period), '^[0-9]{4}-[0-9]{2}$')
            THEN TO_CHAR(sp.payment_date, 'YYYY-MM')
        ELSE TRIM(sp.pay_period)
    END                                            AS clean_pay_period,

    CASE WHEN sp.base_amt IS NULL OR sp.base_amt < 0
         THEN 0 ELSE sp.base_amt END            AS clean_base_amt,
    ROUND(NVL(sp.bonus_amt, 0), 2)              AS clean_bonus_amt,
    ROUND(NVL(sp.deduction_amt, 0), 2)          AS clean_deduction_amt,

    -- ---------- derived measure ----------
    -- total_amt = base + bonus - deduction (the net pay)
    ROUND(  CASE WHEN sp.base_amt IS NULL OR sp.base_amt < 0
                 THEN 0 ELSE sp.base_amt END
          + NVL(sp.bonus_amt, 0)
          - NVL(sp.deduction_amt, 0), 2)        AS total_amt,

    -- ---------- data quality flags ----------
    CASE WHEN sp.base_amt IS NULL OR sp.base_amt < 0
         THEN 'Y' ELSE 'N' END                     AS base_corrected,
    CASE WHEN sp.bonus_amt IS NULL OR sp.deduction_amt IS NULL
         THEN 'Y' ELSE 'N' END                     AS money_defaulted,
    CASE WHEN sp.pay_period IS NULL
              OR NOT REGEXP_LIKE(TRIM(sp.pay_period), '^[0-9]{4}-[0-9]{2}$')
         THEN 'Y' ELSE 'N' END                     AS period_defaulted

FROM salary_payment sp
JOIN staff st ON st.st_ID = sp.st_ID              -- OLTP staff, NOT staff_dim
WHERE sp.sal_pay_ID   IS NOT NULL
  AND sp.st_ID        IS NOT NULL
  AND st.br_ID        IS NOT NULL
  AND sp.payment_date IS NOT NULL;

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_salary_fact_initial AS
    v_count    NUMBER;
    v_errors   NUMBER := 0;
    v_orphaned NUMBER := 0;
    v_source   NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM salary_payment_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('SALARY_PAYMENT_FACT already contains data. '
            || 'Use load_salary_fact_incremental for updates.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_source FROM salary_payment;

    INSERT INTO salary_payment_fact (
        date_key, staff_key, branch_key, sal_pay_ID, pay_period,
        base_amt, bonus_amt, deduction_amt, total_amt
    )
    SELECT
        d.date_key,
        s.staff_key,
        b.branch_key,
        ls.sal_pay_ID,
        ls.clean_pay_period,
        ls.clean_base_amt,
        ls.clean_bonus_amt,
        ls.clean_deduction_amt,
        ls.total_amt
    -- SCD2 joins pick the version in force on the payment date.
    -- branch_key comes from the OLTP staff.br_ID exposed by the view
    -- (staff_dim has no br_ID), matched to branch_dim by date range.
    FROM salary_payment_fact_staging_v ls
    JOIN date_dim   d ON d.cal_date = ls.payment_date
    JOIN staff_dim  s ON s.st_ID    = ls.st_ID
                     AND ls.payment_date BETWEEN s.effective_start_date
                                             AND s.effective_end_date
    JOIN branch_dim b ON b.br_ID    = ls.br_ID;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   salary_payment_fact_staging_v
    WHERE  base_corrected = 'Y' OR money_defaulted = 'Y'
       OR  period_defaulted = 'Y';

    v_orphaned := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SALARY_PAYMENT_FACT initial load completed:');
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
        DBMS_OUTPUT.PUT_LINE('Error in SALARY_PAYMENT_FACT initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN
-- ===================================================================
EXEC load_salary_fact_initial;
