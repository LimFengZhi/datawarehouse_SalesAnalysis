-- ===================================================================
-- 03_sub_purchase_fact.sql    PURCHASE_FACT - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses purchase_fact_staging_v
--   SECTION 2: no sequence - PK is composite (date, supplier, branch,
--              product keys + the degenerate purchase_ID, like every
--              other fact); purchase_ID alone is what the
--              NOT EXISTS anti-join and STEP 2 match on
--   SECTION 3: PROCEDURE - insert new lines, then update changed ones
--   SECTION 4: run + verification
--
-- SCOPE: this is the COGS fact. It has no status column, so STEP 2
-- only catches corrections - a quantity re-counted at goods-in, or a
-- unit cost amended after the supplier invoice arrives. Those do
-- happen, and they move branch profitability, so they are refreshed.
--
-- THE WINDOW: the lower bound is AUTO-DETECTED (newest purchase date
-- already in the fact; empty fact -> 2019-01-01); the upper bound is
-- the one parameter, p_end_date, defaulting to SYSDATE. A bare call
--     EXEC load_purchase_fact_incremental;
-- picks up a day or backfills a whole folder, whichever is there;
--     EXEC load_purchase_fact_incremental(DATE '2024-12-31');
-- caps the backfill at 2024 even if data25 is already in the OLTP.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_purchase_fact_incremental(
    p_end_date IN DATE DEFAULT SYSDATE
) AS
    v_from    DATE;
    v_to      DATE   := TRUNC(p_end_date);
    v_count   NUMBER := 0;
    v_updated NUMBER := 0;
    v_errors  NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 0: auto-detect the window. The newest purchase date already
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
    FROM   purchase_fact f
    JOIN   date_dim d ON d.date_key = f.date_key;

    -- ---------------------------------------------------------------
    -- STEP 1: insert new restocking lines
    -- ---------------------------------------------------------------
    INSERT INTO purchase_fact (
        date_key, supplier_key, branch_key, product_key,
        purchase_ID, purchase_qty, purchase_unit_cost,
        purchase_total_cost
    )
    SELECT
        d.date_key, u.supplier_key, b.branch_key, p.product_key,
        ls.purchase_ID, ls.clean_purchase_qty, ls.clean_unit_cost,
        ls.purchase_total_cost
    -- SCD2 joins pick the version in force on the purchase date.
    FROM purchase_fact_staging_v ls
    JOIN date_dim     d ON d.cal_date   = ls.purchase_date
    JOIN supplier_dim u ON u.sup_ID     = ls.sup_ID
                       AND ls.purchase_date BETWEEN u.effective_start_date
                                                AND u.effective_end_date
    JOIN branch_dim   b ON b.br_ID      = ls.br_ID
                       AND ls.purchase_date BETWEEN b.effective_start_date
                                                AND b.effective_end_date
    JOIN product_dim  p ON p.product_ID = ls.product_ID
                       AND ls.purchase_date BETWEEN p.effective_start_date
                                                AND p.effective_end_date
    WHERE ls.purchase_date >= v_from
    AND   ls.purchase_date <= v_to
    AND   NOT EXISTS (SELECT 1 FROM purchase_fact f
                      WHERE f.purchase_ID = ls.purchase_ID);

    v_count := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: refresh corrected quantities or costs.
    -- purchase_total_cost is refreshed with them so qty * cost = total
    -- continues to hold.
    -- ---------------------------------------------------------------
    UPDATE purchase_fact f
    SET   (purchase_qty, purchase_unit_cost, purchase_total_cost) =
          (SELECT ls.clean_purchase_qty, ls.clean_unit_cost,
                  ls.purchase_total_cost
           FROM   purchase_fact_staging_v ls
           WHERE  ls.purchase_ID = f.purchase_ID)
    WHERE EXISTS (
        SELECT 1
        FROM   purchase_fact_staging_v ls
        WHERE  ls.purchase_ID = f.purchase_ID
          AND  ls.purchase_date >= v_from
          AND  ls.purchase_date <= v_to
          AND (   NVL(f.purchase_qty, -1)
                    <> NVL(ls.clean_purchase_qty, -1)
               OR NVL(f.purchase_unit_cost, -1)
                    <> NVL(ls.clean_unit_cost, -1) ));

    v_updated := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   purchase_fact_staging_v
    WHERE  purchase_date >= v_from
    AND    purchase_date <= v_to
    AND   (qty_corrected = 'Y' OR cost_corrected = 'Y');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('PURCHASE_FACT incremental load completed:');
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
        DBMS_OUTPUT.PUT_LINE('Error in PURCHASE_FACT incremental load: '
            || SQLERRM);
        RAISE;
END;
/
