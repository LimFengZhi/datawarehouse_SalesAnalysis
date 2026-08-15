-- ===================================================================
-- 04_sub_salary_payment_fact.sql  SALARY_PAYMENT_FACT - SUBSEQUENT
--
--   SECTION 1: no new view - reuses salary_payment_fact_staging_v
--   SECTION 2: no sequence - the PK is the degenerate sal_pay_ID
--   SECTION 3: PROCEDURE - insert new rows, then update changed ones
--   SECTION 4: run + verification
--
-- STEP 2 catches a payroll re-run: a bonus added after the fact, or a
-- deduction corrected. gross_amount and net_amount are recomputed with
-- the components so base + bonus - deduction = net keeps holding.
--
-- Backfill the whole of data2 (2023-2024):
--     EXEC load_salary_fact_incremental(DATE '2023-01-02');
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - REUSED, NOT RECREATED
-- salary_payment_fact_staging_v is defined in
--   initialLoading\init_fact\04_init_salary_payment_fact.sql
--
-- It joins the OLTP STAFF table to expose br_ID, because
-- salary_payment has no br_ID by design. That is an OLTP-to-OLTP join,
-- so the view stays free of any dimension. Surrogate joins are below.
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_salary_fact_incremental(
    p_load_date IN DATE DEFAULT SYSDATE
) AS
    v_from    DATE   := TRUNC(p_load_date) - 1;
    v_count   NUMBER := 0;
    v_updated NUMBER := 0;
    v_errors  NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: insert new payslips
    -- ---------------------------------------------------------------
    INSERT INTO salary_payment_fact (
        date_key, staff_key, branch_key, sal_pay_ID, pay_period,
        base_amount, bonus_amount, deduction_amount,
        gross_amount, net_amount
    )
    SELECT
        d.date_key, s.staff_key, b.branch_key, ls.sal_pay_ID,
        ls.clean_pay_period, ls.clean_base_amount,
        ls.clean_bonus_amount, ls.clean_deduction_amount,
        ls.gross_amount, ls.net_amount
    FROM salary_payment_fact_staging_v ls
    JOIN date_dim   d ON d.cal_date = ls.payment_date
    JOIN staff_dim  s ON s.st_ID    = ls.st_ID
                     AND s.is_current_flag = 'Y'
    JOIN branch_dim b ON b.br_ID    = ls.br_ID
                     AND b.is_current_flag = 'Y'
    WHERE ls.payment_date >= v_from
    AND   NOT EXISTS (SELECT 1 FROM salary_payment_fact f
                      WHERE f.sal_pay_ID = ls.sal_pay_ID);

    v_count := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: refresh amended payslips
    -- ---------------------------------------------------------------
    UPDATE salary_payment_fact f
    SET   (base_amount, bonus_amount, deduction_amount,
           gross_amount, net_amount) =
          (SELECT ls.clean_base_amount, ls.clean_bonus_amount,
                  ls.clean_deduction_amount, ls.gross_amount,
                  ls.net_amount
           FROM   salary_payment_fact_staging_v ls
           WHERE  ls.sal_pay_ID = f.sal_pay_ID)
    WHERE EXISTS (
        SELECT 1
        FROM   salary_payment_fact_staging_v ls
        WHERE  ls.sal_pay_ID = f.sal_pay_ID
          AND  ls.payment_date >= v_from
          AND (   NVL(f.base_amount, -1)
                    <> NVL(ls.clean_base_amount, -1)
               OR NVL(f.bonus_amount, -1)
                    <> NVL(ls.clean_bonus_amount, -1)
               OR NVL(f.deduction_amount, -1)
                    <> NVL(ls.clean_deduction_amount, -1) ));

    v_updated := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   salary_payment_fact_staging_v
    WHERE  payment_date >= v_from
    AND   (base_corrected = 'Y' OR money_defaulted = 'Y'
        OR period_defaulted = 'Y');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SALARY_PAYMENT_FACT incremental load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Window from             : '
        || TO_CHAR(v_from, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(' - New records inserted    : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Existing records updated: ' || v_updated);
    DBMS_OUTPUT.PUT_LINE(' - Data quality corrections: ' || v_errors);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in SALARY_PAYMENT_FACT incremental load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
-- EXEC load_salary_fact_incremental;                 -- daily
-- Procedure created above. The EXEC now lives in the folder runner
--   00_run_all_sub_facts.sql
-- so every call and its arguments sit in ONE place.
--   EXEC load_salary_fact_incremental(DATE '2023-01-02'); -- backfill data2

SELECT (SELECT COUNT(*) FROM salary_payment_fact) AS fact_rows,
       (SELECT COUNT(*) FROM salary_payment)      AS source_rows
FROM dual;

-- Which lookup dropped rows, if any. Both must be 0.
SELECT COUNT(*) AS no_date FROM salary_payment_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                  WHERE d.cal_date = ls.payment_date);

SELECT COUNT(*) AS no_branch FROM salary_payment_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM branch_dim b
                  WHERE b.br_ID = ls.br_ID AND b.is_current_flag = 'Y');

-- Arithmetic reconciles
SELECT COUNT(*) AS bad_arithmetic FROM salary_payment_fact
WHERE ABS(gross_amount - deduction_amount - net_amount) > 0.01;
-- expect 0

-- Payroll by year and branch. 2023-24 should step up as the Ipoh team
-- joins from February 2023.
SELECT SUBSTR(f.pay_period, 1, 4) AS yr, b.br_city,
       ROUND(SUM(f.net_amount), 2) AS payroll,
       COUNT(DISTINCT f.staff_key) AS headcount
FROM salary_payment_fact f
JOIN branch_dim b ON b.branch_key = f.branch_key
GROUP BY SUBSTR(f.pay_period, 1, 4), b.br_city
ORDER BY yr, b.br_city;

-- Bonus pattern: December 13th-month and the April Raya bonus
SELECT f.pay_period, ROUND(SUM(f.bonus_amount), 2) AS total_bonus
FROM salary_payment_fact f
WHERE f.pay_period LIKE '2023%' OR f.pay_period LIKE '2024%'
GROUP BY f.pay_period
HAVING SUM(f.bonus_amount) > 0
ORDER BY f.pay_period;

-- Re-run the EXEC above: expect 0 inserted, 0 updated.
