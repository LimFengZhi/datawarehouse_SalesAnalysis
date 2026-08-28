-- ===================================================================
-- 04_sub_salary_payment_fact.sql  SALARY_PAYMENT_FACT - SUBSEQUENT
--
--   SECTION 1: no new view - reuses salary_payment_fact_staging_v
--   SECTION 2: no sequence - PK is composite (date, staff, branch keys
--              + sal_pay_ID); sal_pay_ID is unique by grain (no constraint) and is what the
--              NOT EXISTS anti-join and STEP 2 match on
--   SECTION 3: PROCEDURE - insert new rows, then update changed ones
--   SECTION 4: run + verification
--
-- STEP 2 catches a payroll re-run: a bonus added after the fact, or a
-- deduction corrected. total_amt is recomputed with the components
-- so base + bonus - deduction = total keeps holding.
--
-- THE WINDOW: the lower bound is AUTO-DETECTED (newest payment date
-- already in the fact; empty fact -> 2019-01-01); the upper bound is
-- the one parameter, p_end_date, defaulting to SYSDATE. A bare call
--     EXEC load_salary_fact_incremental;
-- picks up a month or backfills a whole folder, whichever is there;
--     EXEC load_salary_fact_incremental(DATE '2024-12-31');
-- caps the backfill at 2024 even if data25 is already in the OLTP.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_salary_fact_incremental(
    p_end_date IN DATE DEFAULT SYSDATE
) AS
    v_from    DATE;
    v_to      DATE   := TRUNC(p_end_date);
    v_count   NUMBER := 0;
    v_updated NUMBER := 0;
    v_errors  NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 0: auto-detect the window. The newest payment date already
    -- in THIS fact (via date_dim; date_key 0, the Unknown member,
    -- never appears on a fact row) is where the window opens.
    -- Re-reading that whole last day is deliberate: it catches rows
    -- that arrived late for it, and the NOT EXISTS anti-join skips
    -- everything already loaded. An empty fact falls back to
    -- 2019-01-01, the warehouse epoch, so this also works right after
    -- the tables are created. The upper bound is p_end_date (default
    -- SYSDATE = everything available); pass a date to cap a backfill,
    -- e.g. DATE '2024-12-31' loads the data24 year only.
    -- ---------------------------------------------------------------
    SELECT NVL(MAX(d.cal_date), DATE '2019-01-01')
    INTO   v_from
    FROM   salary_payment_fact f
    JOIN   date_dim d ON d.date_key = f.date_key;

    -- ---------------------------------------------------------------
    -- STEP 1: insert new payslips
    -- ---------------------------------------------------------------
    INSERT INTO salary_payment_fact (
        date_key, staff_key, branch_key, sal_pay_ID, pay_period,
        base_amt, bonus_amt, deduction_amt, total_amt
    )
    SELECT
        d.date_key, s.staff_key, b.branch_key, ls.sal_pay_ID,
        ls.clean_pay_period, ls.clean_base_amt,
        ls.clean_bonus_amt, ls.clean_deduction_amt,
        ls.total_amt
    -- SCD2 joins pick the version in force on the payment date.
    -- branch_key comes from the OLTP staff.br_ID exposed by the view
    -- (staff_dim has no br_ID), matched to branch_dim by date range.
    FROM salary_payment_fact_staging_v ls
    JOIN date_dim   d ON d.cal_date = ls.payment_date
    JOIN staff_dim  s ON s.st_ID    = ls.st_ID
                     AND ls.payment_date BETWEEN s.effective_start_date
                                             AND s.effective_end_date
    JOIN branch_dim b ON b.br_ID    = ls.br_ID
                     AND ls.payment_date BETWEEN b.effective_start_date
                                             AND b.effective_end_date
    WHERE ls.payment_date >= v_from
    AND   ls.payment_date <= v_to
    AND   NOT EXISTS (SELECT 1 FROM salary_payment_fact f
                      WHERE f.sal_pay_ID = ls.sal_pay_ID);

    v_count := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: refresh amended payslips. total_amt is refreshed
    -- with the components so base + bonus - deduction = total holds.
    -- ---------------------------------------------------------------
    UPDATE salary_payment_fact f
    SET   (base_amt, bonus_amt, deduction_amt, total_amt) =
          (SELECT ls.clean_base_amt, ls.clean_bonus_amt,
                  ls.clean_deduction_amt, ls.total_amt
           FROM   salary_payment_fact_staging_v ls
           WHERE  ls.sal_pay_ID = f.sal_pay_ID)
    WHERE EXISTS (
        SELECT 1
        FROM   salary_payment_fact_staging_v ls
        WHERE  ls.sal_pay_ID = f.sal_pay_ID
          AND  ls.payment_date >= v_from
          AND  ls.payment_date <= v_to
          AND (   NVL(f.base_amt, -1)
                    <> NVL(ls.clean_base_amt, -1)
               OR NVL(f.bonus_amt, -1)
                    <> NVL(ls.clean_bonus_amt, -1)
               OR NVL(f.deduction_amt, -1)
                    <> NVL(ls.clean_deduction_amt, -1) ));

    v_updated := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   salary_payment_fact_staging_v
    WHERE  payment_date >= v_from
    AND    payment_date <= v_to
    AND   (base_corrected = 'Y' OR money_defaulted = 'Y'
        OR period_defaulted = 'Y');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SALARY_PAYMENT_FACT incremental load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Window from (auto)      : '
        || TO_CHAR(v_from, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(' - Window to (p_end_date)  : '
        || TO_CHAR(v_to, 'YYYY-MM-DD'));
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
