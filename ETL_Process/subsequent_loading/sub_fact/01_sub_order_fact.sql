-- ===================================================================
-- 01_sub_order_fact.sql       ORDER_FACT - SUBSEQUENT (INCREMENTAL)
--
--   SECTION 1: no new view - reuses order_fact_staging_v
--   SECTION 2: no sequence - PK is composite (dimension keys + order_ID
--              + order_det_ID); order_det_ID is UNIQUE and is what the
--              NOT EXISTS anti-join and STEP 2 match on
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
-- MONEY: order_detail stores no unit price. order_total_amt =
--   qty * product_dim.product_unit_price - discount + tax, where the
-- product_dim row is the SCD2 version in force on the order date. Both
-- steps therefore join product_dim by product_ID + date range - STEP 1
-- for product_key and the price, STEP 2 for the price alone.
--
-- THE WINDOW
--   p_load_date IN DATE DEFAULT SYSDATE, filtered as
--       order_date >= TRUNC(p_load_date) - 1
--   so a bare call picks up yesterday and today.
--
--   To BACKFILL a historical range, just pass the first date you want.
--   Loading the whole of data22_23 (2022-2023):
--       EXEC load_order_fact_incremental(DATE '2022-01-01');
--   which filters order_date >= 2021-12-31.
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
--   ETL_Process\initial_loading\init_fact\01_init_order_fact.sql
-- OLTP cleansing only (qty / discount / tax, no price); the
-- surrogate-key joins and the price lookup are written out in the
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
    -- The NOT EXISTS anti-join on the degenerate order_det_ID (UNIQUE
    -- in the fact) is what makes this safe to re-run - a second pass
    -- inserts nothing.
    -- ---------------------------------------------------------------
    INSERT INTO order_fact (
        date_key, product_key, customer_key, staff_key, branch_key,
        order_ID, order_det_ID, order_status,
        order_qty, order_discount_amt, order_tax_amt, order_total_amt
    )
    SELECT
        d.date_key, p.product_key, c.customer_key, s.staff_key,
        b.branch_key, ls.order_ID, ls.order_det_ID,
        ls.clean_order_status, ls.clean_order_qty,
        ls.clean_discount_amt, ls.clean_tax_amt,
        -- price from the product_dim version in force on the order date
        ROUND(  ls.clean_order_qty * p.product_unit_price
              - ls.clean_discount_amt
              + ls.clean_tax_amt, 2)
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
    -- discount lands here too. order_total_amt is recomputed with the
    -- components so qty * price - discount + tax = total always holds.
    --
    -- The price is not in the staging view (order_detail has none), so
    -- this is a MERGE whose source joins the staging view to the
    -- product_dim version in force on the order date - the same lookup
    -- STEP 1 uses. A MERGE (rather than UPDATE .. SET (..) = (SELECT ..))
    -- keeps that join in one place and cannot NULL a row out if the
    -- price lookup found nothing: such a row is simply not matched.
    --
    -- The dimension KEYS are not touched: a changed STATUS does not
    -- move the row to a different customer or product. If the natural
    -- key itself changed it would be a different order line.
    --
    -- NVL on both sides: NULL <> 'x' is UNKNOWN, not TRUE, so a bare
    -- <> would silently skip any change involving a NULL.
    --
    -- The window is applied here as well. That is a deliberate
    -- deviation from the course sample, which scans the whole fact:
    -- order_fact holds hundreds of thousands of rows and an unfiltered
    -- update against the staging view is far too slow on XE. The
    -- trade-off is that a status change on an order OLDER than the
    -- window is not picked up - widen p_load_date if you need it.
    -- ---------------------------------------------------------------
    MERGE INTO order_fact f
    USING (
        SELECT ls.order_det_ID,
               ls.clean_order_status,
               ls.clean_order_qty,
               ls.clean_discount_amt,
               ls.clean_tax_amt,
               ROUND(  ls.clean_order_qty * p.product_unit_price
                     - ls.clean_discount_amt
                     + ls.clean_tax_amt, 2)          AS order_total_amt
        FROM   order_fact_staging_v ls
        JOIN   product_dim p ON p.product_ID = ls.product_ID
                            AND ls.order_date BETWEEN p.effective_start_date
                                                  AND p.effective_end_date
        WHERE  ls.order_date >= v_from
    ) src
    ON (f.order_det_ID = src.order_det_ID)
    WHEN MATCHED THEN UPDATE SET
        f.order_status       = src.clean_order_status,
        f.order_qty          = src.clean_order_qty,
        f.order_discount_amt = src.clean_discount_amt,
        f.order_tax_amt      = src.clean_tax_amt,
        f.order_total_amt    = src.order_total_amt
    WHERE (   NVL(f.order_status, '~')     <> NVL(src.clean_order_status, '~')
           OR NVL(f.order_qty, -1)          <> NVL(src.clean_order_qty, -1)
           OR NVL(f.order_discount_amt, -1) <> NVL(src.clean_discount_amt, -1)
           OR NVL(f.order_tax_amt, -1)      <> NVL(src.clean_tax_amt, -1)
           OR NVL(f.order_total_amt, -1)    <> NVL(src.order_total_amt, -1) );

    v_updated := SQL%ROWCOUNT;

    -- Rows in the window that the cleansing had to repair
    SELECT COUNT(*) INTO v_errors
    FROM   order_fact_staging_v
    WHERE  order_date >= v_from
    AND   (qty_corrected = 'Y'
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
