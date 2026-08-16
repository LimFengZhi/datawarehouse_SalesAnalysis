-- ===================================================================
-- 01_sub_order_fact.sql       ORDER_FACT - SUBSEQUENT (INCREMENTAL)
--
--   SECTION 1: no new view - reuses order_fact_staging_v
--   SECTION 2: no sequence - the PK is the degenerate order_det_ID
--   SECTION 3: PROCEDURE - insert new lines, then update changed ones
--   SECTION 4: run + verification
--
-- TWO STEPS:
--   STEP 1  INSERT order lines that are not in the fact yet
--   STEP 2  UPDATE lines that ARE in the fact but whose values moved
--
-- STEP 2 is what makes a fact load different from a dimension load.
-- order_status is not frozen at the moment of sale - an order sits at
-- 'Processing' and later becomes 'Completed' or 'Cancelled'. Without
-- the update the warehouse would keep reporting the status the row had
-- on the day it first loaded, and cancellation rates would be wrong.
--
-- THE WINDOW
--   p_load_date IN DATE DEFAULT SYSDATE, filtered as
--       order_date >= TRUNC(p_load_date) - 1
--   so a bare call picks up yesterday and today.
--
--   To BACKFILL a historical range, just pass the first date you want.
--   Loading the whole of data2 (2023-2024):
--       EXEC load_order_fact_incremental(DATE '2023-01-01');
--   which filters order_date >= 2022-12-31.
--
--   Note the window opens ONE DAY EARLIER than the date you pass -
--   that is the "- 1" above, and it is deliberate. On a daily run it
--   catches rows that arrived late for yesterday. On a backfill it
--   just re-reads one already-loaded day, which the NOT EXISTS
--   anti-join skips. So there is no need to add a day yourself.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - reuses order_fact_staging_v from
--   initial_loading\init_fact\01_init_order_fact.sql
-- OLTP cleansing only; the surrogate-key joins are written out in the
-- procedure below, where the raw date drives the window filter.
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_order_fact_incremental(
    p_load_date IN DATE DEFAULT SYSDATE
) AS
    v_from    DATE   := TRUNC(p_load_date) - 1;
    v_count   NUMBER := 0;
    v_updated NUMBER := 0;
    v_errors  NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: insert new order lines.
    -- The NOT EXISTS anti-join on the degenerate PK is what makes this
    -- safe to re-run - a second pass inserts nothing.
    -- ---------------------------------------------------------------
    INSERT INTO order_fact (
        date_key, product_key, customer_key, staff_key, branch_key,
        order_ID, order_det_ID, order_status,
        order_qty, order_unit_price, order_gross_amt,
        order_discount_amt, order_tax_amt, order_total_amt
    )
    SELECT
        d.date_key, p.product_key, c.customer_key, s.staff_key,
        b.branch_key, ls.order_ID, ls.order_det_ID,
        ls.clean_order_status, ls.clean_order_qty, ls.clean_unit_price,
        ls.order_gross_amt, ls.clean_discount_amt, ls.clean_tax_amt,
        ls.order_total_amt
    -- Each SCD2 join picks the version IN FORCE ON THE ORDER DATE, not
    -- whichever version is current at load time - so the load order of
    -- facts vs price maintenance can no longer attach rows to the
    -- wrong version.
    FROM order_fact_staging_v ls
    JOIN date_dim     d ON d.cal_date   = ls.order_date
    JOIN product_dim  p ON p.product_ID = ls.product_ID
                       AND ls.order_date BETWEEN p.effective_start_date
                                             AND p.effective_end_date
    JOIN customer_dim c ON c.cus_ID     = ls.cus_ID
                       AND ls.order_date BETWEEN c.effective_start_date
                                             AND c.effective_end_date
    JOIN staff_dim    s ON s.st_ID      = ls.st_ID
                       AND ls.order_date BETWEEN s.effective_start_date
                                             AND s.effective_end_date
    JOIN branch_dim   b ON b.br_ID      = ls.br_ID
                       AND ls.order_date BETWEEN b.effective_start_date
                                             AND b.effective_end_date
    WHERE ls.order_date >= v_from
    AND   NOT EXISTS (SELECT 1 FROM order_fact f
                      WHERE f.order_det_ID = ls.order_det_ID);

    v_count := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: refresh lines already in the fact whose values changed.
    --
    -- Mostly order_status moving on, but a corrected quantity or
    -- discount lands here too. The measures update together so
    -- gross - discount + tax = total always holds.
    --
    -- No dimension joins here: a changed STATUS does not move the row
    -- to a different customer or product. If the natural key itself
    -- changed it would be a different order line.
    --
    -- NVL on both sides: NULL <> 'x' is UNKNOWN, not TRUE, so a bare
    -- <> would silently skip any change involving a NULL.
    --
    -- The window is applied here as well. That is a deliberate
    -- deviation from the course sample, which scans the whole fact:
    -- order_fact holds 635,000 rows and an unfiltered correlated
    -- update against the staging view is far too slow on XE. The
    -- trade-off is that a status change on an order OLDER than the
    -- window is not picked up - widen p_load_date if you need it.
    -- ---------------------------------------------------------------
    UPDATE order_fact f
    SET   (order_status, order_qty, order_unit_price, order_gross_amt,
           order_discount_amt, order_tax_amt, order_total_amt) =
          (SELECT ls.clean_order_status, ls.clean_order_qty,
                  ls.clean_unit_price, ls.order_gross_amt,
                  ls.clean_discount_amt, ls.clean_tax_amt,
                  ls.order_total_amt
           FROM   order_fact_staging_v ls
           WHERE  ls.order_det_ID = f.order_det_ID)
    WHERE EXISTS (
        SELECT 1
        FROM   order_fact_staging_v ls
        WHERE  ls.order_det_ID = f.order_det_ID
          AND  ls.order_date >= v_from
          AND (   NVL(f.order_status, '~')     <> NVL(ls.clean_order_status, '~')
               OR NVL(f.order_qty, -1)          <> NVL(ls.clean_order_qty, -1)
               OR NVL(f.order_unit_price, -1)   <> NVL(ls.clean_unit_price, -1)
               OR NVL(f.order_discount_amt, -1) <> NVL(ls.clean_discount_amt, -1)
               OR NVL(f.order_tax_amt, -1)      <> NVL(ls.clean_tax_amt, -1) ));

    v_updated := SQL%ROWCOUNT;

    -- Rows in the window that the cleansing had to repair
    SELECT COUNT(*) INTO v_errors
    FROM   order_fact_staging_v
    WHERE  order_date >= v_from
    AND   (qty_corrected = 'Y' OR price_corrected = 'Y'
        OR status_defaulted = 'Y' OR money_defaulted = 'Y');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('ORDER_FACT incremental load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Window from             : '
        || TO_CHAR(v_from, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(' - New records inserted    : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Existing records updated: ' || v_updated);
    DBMS_OUTPUT.PUT_LINE(' - Data quality corrections: ' || v_errors);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in ORDER_FACT incremental load: '
            || SQLERRM);
        RAISE;
END;
/
