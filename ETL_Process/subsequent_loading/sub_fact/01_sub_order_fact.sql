-- ===================================================================
-- 01_sub_order_fact.sql       ORDER_FACT - SUBSEQUENT (INCREMENTAL)
--
--   SECTION 1: no new view - reuses order_fact_staging_v
--   SECTION 2: no sequence - PK is composite (dimension keys + order_ID);
--              (order_ID, product_key) is unique by grain (no constraint) and is what the
--              NOT EXISTS anti-join and STEP 2 match on. Grain = one row
--              per (order, product): the staging view already folds
--              duplicate-product lines of one order into one row.
--   SECTION 3: PROCEDURE - insert new lines, then update changed ones
--   SECTION 4: run + verification
--
-- TWO STEPS:
--   STEP 1  INSERT (order, product) rows that are not in the fact yet
--   STEP 2  UPDATE rows that ARE in the fact but whose values moved
--
-- STEP 2 is what makes a fact load different from a dimension load.
-- order_status is not frozen at the moment of sale - an order sits at
-- 'Processing' and later becomes 'Completed' or 'Cancelled'. Without
-- the update the warehouse would keep reporting the status the row had
-- on the day it first loaded, and cancellation rates would be wrong.
--
-- MONEY: order_detail stores no unit price. order_total_amt =
--   qty * product_dim.product_unit_price - discount + tax, and
--   order_net_amt is the same without the tax (that is the revenue
--   figure - the SST belongs to the government), where the
-- product_dim row is the SCD2 version in force on the order date. Both
-- steps therefore join product_dim by product_ID + date range - STEP 1
-- for product_key and the price, STEP 2 for the price alone.
--
-- THE WINDOW
--   The lower bound is AUTO-DETECTED: the newest order date already in
--   the fact (via date_dim). The upper bound is the one parameter,
--   p_end_date, defaulting to SYSDATE:
--       order_date >= newest loaded date  AND  order_date <= p_end_date
--   so one bare call
--       EXEC load_order_fact_incremental;
--   loads however much the OLTP holds beyond what is loaded - one day
--   on a daily run, a whole year on a backfill. Pass a date to CAP a
--   backfill instead:
--       EXEC load_order_fact_incremental(DATE '2024-12-31');
--   loads data24 only, even if data25 is already sitting in the OLTP.
--
--   The window opens ON the last loaded day, not after it - that is
--   deliberate. It catches rows that arrived late for that day, and
--   the NOT EXISTS anti-join skips the ones already in. An empty fact
--   falls back to 2019-01-01, the warehouse epoch.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_order_fact_incremental(
    p_end_date IN DATE DEFAULT SYSDATE
) AS
    v_from    DATE;
    v_to      DATE   := TRUNC(p_end_date);
    v_count   NUMBER := 0;
    v_updated NUMBER := 0;
    v_errors  NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 0: auto-detect the window. The newest order date already
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
    FROM   order_fact f
    JOIN   date_dim d ON d.date_key = f.date_key;

    -- ---------------------------------------------------------------
    -- STEP 1: insert new (order, product) rows.
    -- The NOT EXISTS anti-join on (order_ID, product_key) - unique by
    -- grain in the fact (no constraint; PK covers it) - is what makes this safe to re-run: a second pass
    -- inserts nothing. product_key is fixed by the order date (the
    -- version in force then), so the key is stable across re-runs as
    -- long as product versions are never back-dated after a load.
    -- ---------------------------------------------------------------
    INSERT INTO order_fact (
        date_key, product_key, customer_key, staff_key, branch_key,
        order_ID, order_status,
        order_qty, order_discount_amt, order_tax_amt, order_total_amt,
        order_net_amt
    )
    SELECT
        d.date_key, p.product_key, c.customer_key, s.staff_key,
        b.branch_key, ls.order_ID,
        ls.clean_order_status, ls.clean_order_qty,
        ls.clean_discount_amt, ls.clean_tax_amt,
        -- price from the product_dim version in force on the order date
        ROUND(  ls.clean_order_qty * p.product_unit_price
              - ls.clean_discount_amt
              + ls.clean_tax_amt, 2),
        ROUND(  ls.clean_order_qty * p.product_unit_price
              - ls.clean_discount_amt, 2)
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
    AND   ls.order_date <= v_to
    AND   NOT EXISTS (SELECT 1 FROM order_fact f
                      WHERE f.order_ID     = ls.order_ID
                        AND f.product_key  = p.product_key);

    v_count := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: refresh rows already in the fact whose values changed.
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
    -- key itself changed it would be a different (order, product) row.
    --
    -- NVL on both sides: NULL <> 'x' is UNKNOWN, not TRUE, so a bare
    -- <> would silently skip any change involving a NULL.
    --
    -- The window is applied here as well. That is a deliberate
    -- deviation from the course sample, which scans the whole fact:
    -- order_fact holds hundreds of thousands of rows and an unfiltered
    -- update against the staging view is far too slow on XE. The
    -- trade-off is that a status change on an order OLDER than the
    -- window is not picked up. The window opens at the newest loaded
    -- date, so on a steady daily cadence nothing is ever older than it.
    -- ---------------------------------------------------------------
    MERGE INTO order_fact f
    USING (
        SELECT ls.order_ID,
               p.product_key,
               ls.clean_order_status,
               ls.clean_order_qty,
               ls.clean_discount_amt,
               ls.clean_tax_amt,
               ROUND(  ls.clean_order_qty * p.product_unit_price
                     - ls.clean_discount_amt
                     + ls.clean_tax_amt, 2)          AS order_total_amt,
               ROUND(  ls.clean_order_qty * p.product_unit_price
                     - ls.clean_discount_amt, 2)     AS order_net_amt
        FROM   order_fact_staging_v ls
        JOIN   product_dim p ON p.product_ID = ls.product_ID
                            AND ls.order_date BETWEEN p.effective_start_date
                                                  AND p.effective_end_date
        WHERE  ls.order_date >= v_from
        AND    ls.order_date <= v_to
    ) src
    ON (f.order_ID = src.order_ID AND f.product_key = src.product_key)
    WHEN MATCHED THEN UPDATE SET
        f.order_status       = src.clean_order_status,
        f.order_qty          = src.clean_order_qty,
        f.order_discount_amt = src.clean_discount_amt,
        f.order_tax_amt      = src.clean_tax_amt,
        f.order_total_amt    = src.order_total_amt,
        f.order_net_amt      = src.order_net_amt
    WHERE (   NVL(f.order_status, '~')     <> NVL(src.clean_order_status, '~')
           OR NVL(f.order_qty, -1)          <> NVL(src.clean_order_qty, -1)
           OR NVL(f.order_discount_amt, -1) <> NVL(src.clean_discount_amt, -1)
           OR NVL(f.order_tax_amt, -1)      <> NVL(src.clean_tax_amt, -1)
           OR NVL(f.order_total_amt, -1)    <> NVL(src.order_total_amt, -1)
           OR NVL(f.order_net_amt, -1)      <> NVL(src.order_net_amt, -1) );

    v_updated := SQL%ROWCOUNT;

    -- Rows in the window that the cleansing had to repair
    SELECT COUNT(*) INTO v_errors
    FROM   order_fact_staging_v
    WHERE  order_date >= v_from
    AND    order_date <= v_to
    AND   (qty_corrected = 'Y'
        OR status_defaulted = 'Y' OR money_defaulted = 'Y');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('ORDER_FACT incremental load completed:');
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
        DBMS_OUTPUT.PUT_LINE('Error in ORDER_FACT incremental load: '
            || SQLERRM);
        RAISE;
END;
/
