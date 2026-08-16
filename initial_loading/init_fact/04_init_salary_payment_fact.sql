-- ===================================================================
-- 04_init_salary_payment_fact.sql   SALARY_PAYMENT_FACT
-- Grain: one row per staff member per pay period (3,135 in data\)
-- Source: SALARY_PAYMENT joined to STAFF
--
--   SECTION 1: staging VIEW - OLTP cleansing ONLY
--   SECTION 2: no sequence   - the PK is the degenerate sal_pay_ID
--   SECTION 3: PROCEDURE     - resolves surrogate keys, then inserts
--   SECTION 4: run + verification
--
-- THE VIEW DOES NOT TOUCH THE DIMENSIONS - natural keys out (st_ID,
-- br_ID) and the raw payment_date.
--
-- THE INTERESTING BIT: salary_payment has NO br_ID - that was a
-- deliberate decision in the OLTP model (see the comment in
-- 01_create_operational_db.sql). The view therefore joins the OLTP
-- STAFF table to expose br_ID as a natural key. That is an
-- OLTP-to-OLTP join, exactly like LOAN joining LOAN_DETAILS - it does
-- NOT couple the view to a dimension.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW salary_payment_fact_staging_v AS
SELECT
    sp.sal_pay_ID,                                -- degenerate dim / PK

    -- ---------- NATURAL keys ----------
    sp.st_ID,
    s.br_ID,                                      -- via STAFF, by design
    TRUNC(sp.payment_date)                         AS payment_date,

    -- ---------- cleansed attributes ----------
    CASE
        WHEN sp.pay_period IS NULL
             OR NOT REGEXP_LIKE(TRIM(sp.pay_period), '^[0-9]{4}-[0-9]{2}$')
            THEN TO_CHAR(sp.payment_date, 'YYYY-MM')
        ELSE TRIM(sp.pay_period)
    END                                            AS clean_pay_period,

    CASE WHEN sp.base_amount IS NULL OR sp.base_amount < 0
         THEN 0 ELSE sp.base_amount END            AS clean_base_amount,
    ROUND(NVL(sp.bonus_amount, 0), 2)              AS clean_bonus_amount,
    ROUND(NVL(sp.deduction_amount, 0), 2)          AS clean_deduction_amount,

    -- ---------- derived measures ----------
    ROUND(  CASE WHEN sp.base_amount IS NULL OR sp.base_amount < 0
                 THEN 0 ELSE sp.base_amount END
          + NVL(sp.bonus_amount, 0), 2)            AS gross_amount,
    ROUND(  CASE WHEN sp.base_amount IS NULL OR sp.base_amount < 0
                 THEN 0 ELSE sp.base_amount END
          + NVL(sp.bonus_amount, 0)
          - NVL(sp.deduction_amount, 0), 2)        AS net_amount,

    -- ---------- data quality flags ----------
    CASE WHEN sp.base_amount IS NULL OR sp.base_amount < 0
         THEN 'Y' ELSE 'N' END                     AS base_corrected,
    CASE WHEN sp.bonus_amount IS NULL OR sp.deduction_amount IS NULL
         THEN 'Y' ELSE 'N' END                     AS money_defaulted,
    CASE WHEN sp.pay_period IS NULL
              OR NOT REGEXP_LIKE(TRIM(sp.pay_period), '^[0-9]{4}-[0-9]{2}$')
         THEN 'Y' ELSE 'N' END                     AS period_defaulted

FROM salary_payment sp
JOIN staff s ON s.st_ID = sp.st_ID                -- OLTP, not staff_dim
WHERE sp.sal_pay_ID   IS NOT NULL
  AND sp.st_ID        IS NOT NULL
  AND s.br_ID         IS NOT NULL
  AND sp.payment_date IS NOT NULL;

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- sal_pay_ID from the source is the PK and a degenerate dimension.
-- ===================================================================

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
        base_amount, bonus_amount, deduction_amount,
        gross_amount, net_amount
    )
    SELECT
        d.date_key,
        s.staff_key,
        b.branch_key,
        ls.sal_pay_ID,
        ls.clean_pay_period,
        ls.clean_base_amount,
        ls.clean_bonus_amount,
        ls.clean_deduction_amount,
        ls.gross_amount,
        ls.net_amount
    FROM salary_payment_fact_staging_v ls
    JOIN date_dim   d ON d.cal_date = ls.payment_date
    JOIN staff_dim  s ON s.st_ID    = ls.st_ID
                     AND s.is_current_flag = 'Y'
    JOIN branch_dim b ON b.br_ID    = ls.br_ID
                     AND b.is_current_flag = 'Y';

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
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_salary_fact_initial;

SELECT (SELECT COUNT(*) FROM salary_payment_fact) AS fact_rows,
       (SELECT COUNT(*) FROM salary_payment)      AS source_rows
FROM dual;

SELECT (SELECT COUNT(*) FROM salary_payment)
     - (SELECT COUNT(*) FROM salary_payment_fact_staging_v) AS rejected_by_view
FROM dual;
-- expect 0

-- Which DIMENSION lookup failed, if any. Both must return 0.
SELECT COUNT(*) AS no_date FROM salary_payment_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                  WHERE d.cal_date = ls.payment_date);

SELECT COUNT(*) AS no_branch FROM salary_payment_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM branch_dim b
                  WHERE b.br_ID = ls.br_ID AND b.is_current_flag = 'Y');

-- Arithmetic check: gross - deduction = net
SELECT COUNT(*) AS bad_arithmetic FROM salary_payment_fact
WHERE ABS(gross_amount - deduction_amount - net_amount) > 0.01;

-- Payroll by branch and year
SELECT b.br_city, SUBSTR(f.pay_period, 1, 4) AS yr,
       ROUND(SUM(f.net_amount), 2) AS payroll
FROM salary_payment_fact f
JOIN branch_dim b ON b.branch_key = f.branch_key
GROUP BY b.br_city, SUBSTR(f.pay_period, 1, 4)
ORDER BY b.br_city, yr;

-- THE MCO PAY-CUT CHECK. The README says salaries were cut 20% then
-- 15% during lockdown, and 13th-month / Raya bonuses were paid.
-- Average base should dip in 2020 and bonuses should spike in Dec.
SELECT SUBSTR(pay_period, 1, 4) AS yr,
       ROUND(AVG(base_amount), 2)  AS avg_base,
       ROUND(SUM(bonus_amount), 2) AS total_bonus
FROM salary_payment_fact
GROUP BY SUBSTR(pay_period, 1, 4)
ORDER BY yr;
