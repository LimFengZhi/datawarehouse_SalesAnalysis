-- ===================================================================
-- 04_init_salary_payment_fact.sql   SALARY_PAYMENT_FACT
-- Grain: one row per staff member per pay period  (3,135 rows)
-- Source: SALARY_PAYMENT
--
-- THE INTERESTING BIT: salary_payment has NO br_ID - that was a
-- deliberate design decision in the OLTP model (see the comment in
-- 01_create_operational_db.sql). branch_key is therefore resolved
-- by walking SALARY_PAYMENT -> STAFF -> BRANCH_DIM.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW salary_payment_fact_staging_v AS
SELECT
    dd.date_key,
    sd.staff_key,
    bd.branch_key,                                -- resolved via STAFF

    sp.sal_pay_ID,                                -- degenerate dim / PK
    sp.pay_period,                                -- 'YYYY-MM'

    sp.base_amount,
    ROUND(NVL(sp.bonus_amount, 0), 2)              AS bonus_amount,
    ROUND(NVL(sp.deduction_amount, 0), 2)          AS deduction_amount,

    -- Measures
    ROUND(sp.base_amount + NVL(sp.bonus_amount, 0), 2)
                                                   AS gross_amount,
    ROUND(  sp.base_amount
          + NVL(sp.bonus_amount, 0)
          - NVL(sp.deduction_amount, 0), 2)        AS net_amount

FROM salary_payment sp
-- the bridge: the staff member's branch
JOIN staff        s  ON s.st_ID     = sp.st_ID
JOIN date_dim     dd ON dd.cal_date = TRUNC(sp.payment_date)
JOIN staff_dim    sd ON sd.st_ID    = sp.st_ID
                    AND sd.is_current_flag = 'Y'
JOIN branch_dim   bd ON bd.br_ID    = s.br_ID
                    AND bd.is_current_flag = 'Y';

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- sal_pay_ID from the source is the PK and a degenerate dimension.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_salary_fact_initial AS
    v_count   NUMBER;
    v_source  NUMBER;
    v_dropped NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM salary_payment_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('SALARY_PAYMENT_FACT already contains data. '
            || 'Delete it first if you intend to reload.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_source FROM salary_payment;

    INSERT INTO salary_payment_fact (
        date_key, staff_key, branch_key, sal_pay_ID, pay_period,
        base_amount, bonus_amount, deduction_amount,
        gross_amount, net_amount
    )
    SELECT
        date_key, staff_key, branch_key, sal_pay_ID, pay_period,
        base_amount, bonus_amount, deduction_amount,
        gross_amount, net_amount
    FROM salary_payment_fact_staging_v;

    v_count   := SQL%ROWCOUNT;
    v_dropped := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SALARY_PAYMENT_FACT initial load completed: '
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
        DBMS_OUTPUT.PUT_LINE('Error in SALARY_PAYMENT_FACT initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_salary_fact_initial;

-- Expect 3135 in both columns
SELECT (SELECT COUNT(*) FROM salary_payment_fact) AS fact_rows,
       (SELECT COUNT(*) FROM salary_payment)      AS source_rows
FROM dual;

-- Which lookup failed, if any. Both must return 0.
SELECT COUNT(*) AS no_date FROM salary_payment sp
WHERE NOT EXISTS (SELECT 1 FROM date_dim dd
                  WHERE dd.cal_date = TRUNC(sp.payment_date));

SELECT COUNT(*) AS no_branch_via_staff FROM salary_payment sp
JOIN staff s ON s.st_ID = sp.st_ID
WHERE NOT EXISTS (SELECT 1 FROM branch_dim bd
                  WHERE bd.br_ID = s.br_ID AND bd.is_current_flag = 'Y');

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
