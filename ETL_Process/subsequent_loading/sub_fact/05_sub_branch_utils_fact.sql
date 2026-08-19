-- ===================================================================
-- 05_sub_branch_utils_fact.sql  BRANCH_UTILS_FACT - SUBSEQUENT
--
--   SECTION 1: no new view - reuses branch_utils_fact_staging_v
--   SECTION 2: no sequence - PK is composite (date, branch keys +
--              br_exp_ID); br_exp_ID is unique by grain (no constraint) and is what the
--              NOT EXISTS anti-join and STEP 2 match on
--   SECTION 3: PROCEDURE - insert new rows, then update changed ones
--   SECTION 4: run + verification
--
-- STEP 2 catches a re-billed utility - an estimated electricity bill
-- replaced by an actual reading, or a rent rebate applied after the
-- fact - and a corrected utility name. All move branch profitability,
-- so they are refreshed.
--
-- Backfill the whole of data24 (2024):
--     EXEC load_br_utils_fact_incremental(DATE '2024-01-01');
-- (the name is abbreviated to stay inside Oracle 11.2's 30-character
--  identifier limit)
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_br_utils_fact_incremental(
    p_load_date IN DATE DEFAULT SYSDATE
) AS
    v_from    DATE   := TRUNC(p_load_date) - 1;
    v_count   NUMBER := 0;
    v_updated NUMBER := 0;
    v_errors  NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: insert new utility rows
    -- ---------------------------------------------------------------
    INSERT INTO branch_utils_fact (
        date_key, branch_key, br_exp_ID,
        util_name, billing_period, payment_amount
    )
    SELECT
        d.date_key, b.branch_key, ls.br_exp_ID,
        ls.clean_util_name, ls.clean_billing_period, ls.clean_payment_amount
    -- The SCD2 join picks the version in force on the payment date.
    FROM branch_utils_fact_staging_v ls
    JOIN date_dim   d ON d.cal_date = ls.payment_date
    JOIN branch_dim b ON b.br_ID    = ls.br_ID
                     AND ls.payment_date BETWEEN b.effective_start_date
                                             AND b.effective_end_date
    WHERE ls.payment_date >= v_from
    AND   NOT EXISTS (SELECT 1 FROM branch_utils_fact f
                      WHERE f.br_exp_ID = ls.br_exp_ID);

    v_count := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: refresh re-billed amounts / corrected names
    -- ---------------------------------------------------------------
    UPDATE branch_utils_fact f
    SET   (util_name, billing_period, payment_amount) =
          (SELECT ls.clean_util_name, ls.clean_billing_period,
                  ls.clean_payment_amount
           FROM   branch_utils_fact_staging_v ls
           WHERE  ls.br_exp_ID = f.br_exp_ID)
    WHERE EXISTS (
        SELECT 1
        FROM   branch_utils_fact_staging_v ls
        WHERE  ls.br_exp_ID = f.br_exp_ID
          AND  ls.payment_date >= v_from
          AND (   NVL(f.payment_amount, -1)
                    <> NVL(ls.clean_payment_amount, -1)
               OR NVL(f.billing_period, '~')
                    <> NVL(ls.clean_billing_period, '~')
               OR NVL(f.util_name, '~')
                    <> NVL(ls.clean_util_name, '~') ));

    v_updated := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   branch_utils_fact_staging_v
    WHERE  payment_date >= v_from
    AND   (name_defaulted = 'Y' OR amount_corrected = 'Y'
           OR period_defaulted = 'Y');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_UTILS_FACT incremental load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Window from             : '
        || TO_CHAR(v_from, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(' - New records inserted    : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Existing records updated: ' || v_updated);
    DBMS_OUTPUT.PUT_LINE(' - Data quality corrections: ' || v_errors);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in BRANCH_UTILS_FACT incremental load: '
            || SQLERRM);
        RAISE;
END;
/
