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
--     EXEC load_salary_fact_incremental(DATE '2023-01-01');
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - reuses salary_payment_fact_staging_v from
--   ETL_Process\initial_loading\init_fact\04_init_salary_payment_fact.sql
-- It joins the OLTP STAFF table to expose br_ID (salary_payment has
-- none by design). Surrogate-key joins are written out below.
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
    -- SCD2 joins pick the version in force on the payment date.
    FROM salary_payment_fact_staging_v ls
    JOIN date_dim   d ON d.cal_date = ls.payment_date
    JOIN staff_dim  s ON s.st_ID    = ls.st_ID
                     AND ls.payment_date BETWEEN s.effective_start_date
                                             AND s.effective_end_date
    JOIN branch_dim b ON b.br_ID    = ls.br_ID
                     AND ls.payment_date BETWEEN b.effective_start_date
                                             AND b.effective_end_date
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
