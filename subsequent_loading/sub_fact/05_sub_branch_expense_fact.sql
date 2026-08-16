-- ===================================================================
-- 05_sub_branch_expense_fact.sql  BRANCH_EXPENSE_FACT - SUBSEQUENT
--
--   SECTION 1: no new view - reuses branch_expense_fact_staging_v
--   SECTION 2: no sequence - the PK is the degenerate br_exp_ID
--   SECTION 3: PROCEDURE - insert new rows, then update changed ones
--   SECTION 4: run + verification
--
-- STEP 2 catches a re-billed utility - an estimated electricity bill
-- replaced by an actual reading, or a rent rebate applied after the
-- fact. Both move branch profitability, so they are refreshed.
--
-- Backfill the whole of data2 (2023-2024):
--     EXEC load_br_exp_fact_incremental(DATE '2023-01-01');
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - reuses branch_expense_fact_staging_v from
--   initial_loading\init_fact\05_init_branch_expense_fact.sql
-- OLTP cleansing only; surrogate-key joins are written out below.
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_br_exp_fact_incremental(
    p_load_date IN DATE DEFAULT SYSDATE
) AS
    v_from    DATE   := TRUNC(p_load_date) - 1;
    v_count   NUMBER := 0;
    v_updated NUMBER := 0;
    v_errors  NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: insert new expense rows
    -- ---------------------------------------------------------------
    INSERT INTO branch_expense_fact (
        date_key, branch_key, branch_utils_key,
        br_exp_ID, billing_period, payment_amount
    )
    SELECT
        d.date_key, b.branch_key, u.branch_utils_key,
        ls.br_exp_ID, ls.clean_billing_period, ls.clean_payment_amount
    -- The SCD2 join picks the version in force on the payment date.
    FROM branch_expense_fact_staging_v ls
    JOIN date_dim         d ON d.cal_date    = ls.payment_date
    JOIN branch_dim       b ON b.br_ID       = ls.br_ID
                           AND ls.payment_date BETWEEN b.effective_start_date
                                                   AND b.effective_end_date
    -- branch_utils_dim is a Type 1 lookup: no effective dates
    JOIN branch_utils_dim u ON u.br_utils_ID = ls.br_utils_ID
    WHERE ls.payment_date >= v_from
    AND   NOT EXISTS (SELECT 1 FROM branch_expense_fact f
                      WHERE f.br_exp_ID = ls.br_exp_ID);

    v_count := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: refresh re-billed amounts
    -- ---------------------------------------------------------------
    UPDATE branch_expense_fact f
    SET   (billing_period, payment_amount) =
          (SELECT ls.clean_billing_period, ls.clean_payment_amount
           FROM   branch_expense_fact_staging_v ls
           WHERE  ls.br_exp_ID = f.br_exp_ID)
    WHERE EXISTS (
        SELECT 1
        FROM   branch_expense_fact_staging_v ls
        WHERE  ls.br_exp_ID = f.br_exp_ID
          AND  ls.payment_date >= v_from
          AND (   NVL(f.payment_amount, -1)
                    <> NVL(ls.clean_payment_amount, -1)
               OR NVL(f.billing_period, '~')
                    <> NVL(ls.clean_billing_period, '~') ));

    v_updated := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   branch_expense_fact_staging_v
    WHERE  payment_date >= v_from
    AND   (amount_corrected = 'Y' OR period_defaulted = 'Y');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_EXPENSE_FACT incremental load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Window from             : '
        || TO_CHAR(v_from, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(' - New records inserted    : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Existing records updated: ' || v_updated);
    DBMS_OUTPUT.PUT_LINE(' - Data quality corrections: ' || v_errors);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in BRANCH_EXPENSE_FACT incremental load: '
            || SQLERRM);
        RAISE;
END;
/
