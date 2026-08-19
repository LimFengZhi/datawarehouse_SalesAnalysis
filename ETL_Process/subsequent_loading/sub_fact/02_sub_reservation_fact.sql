-- ===================================================================
-- 02_sub_reservation_fact.sql  RESERVATION_FACT - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses reservation_fact_staging_v
--   SECTION 2: no sequence - PK is composite (dimension keys + res_ID);
--              (res_ID, service_key, staff_key) is unique by grain (no constraint) and is what
--              the NOT EXISTS anti-join and STEP 2 match on
--   SECTION 3: PROCEDURE - insert new lines, then update changed ones
--   SECTION 4: run + verification
--
-- STEP 2 matters most on this fact. A reservation is booked as
-- 'Confirmed' and only later becomes 'Completed', 'Cancelled' or
-- 'No-Show'. Insert-only would freeze every booking at 'Confirmed' and
-- the no-show rate - one of the analyses this warehouse exists for -
-- would read as zero forever.
--
-- DATE: date_key and the window are driven by reservation.reservation_date
-- (the appointment day, exposed by the view as res_date) - NOT by
-- booking_date, which is when the booking was made.
--
-- MONEY: reservation_detail stores no price. serv_total_amt =
--   service_dim.serv_price - discount + tax, where the service_dim row
-- is the SCD2 version in force on the reservation date. Both steps
-- join service_dim by serv_ID + date range for it.
--
-- Backfill the whole of data24 (2024):
--     EXEC load_res_fact_incremental(DATE '2024-01-01');
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_res_fact_incremental(
    p_load_date IN DATE DEFAULT SYSDATE
) AS
    v_from    DATE   := TRUNC(p_load_date) - 1;
    v_count   NUMBER := 0;
    v_updated NUMBER := 0;
    v_errors  NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: insert new (reservation, service, therapist) rows
    -- ---------------------------------------------------------------
    INSERT INTO reservation_fact (
        date_key, customer_key, staff_key, branch_key, service_key,
        res_ID, res_duration, res_status,
        start_time, end_time,
        serv_discount_amt, serv_tax_amt, serv_total_amt
    )
    SELECT
        d.date_key, c.customer_key, s.staff_key, b.branch_key,
        v.service_key, ls.res_ID, ls.res_duration,
        ls.clean_res_status, ls.start_time, ls.end_time,
        ls.clean_discount_amt, ls.clean_tax_amt,
        -- price from the service_dim version in force on the reservation date
        ROUND(  ls.line_count * v.serv_price
              - ls.clean_discount_amt
              + ls.clean_tax_amt, 2)
    -- SCD2 joins pick the version in force on the reservation date.
    FROM reservation_fact_staging_v ls
    JOIN date_dim     d ON d.cal_date = ls.res_date
    JOIN customer_dim c ON c.cus_ID   = ls.cus_ID
                       AND ls.res_date BETWEEN c.effective_start_date
                                           AND c.effective_end_date
    JOIN staff_dim    s ON s.st_ID    = ls.st_ID
                       AND ls.res_date BETWEEN s.effective_start_date
                                           AND s.effective_end_date
    JOIN branch_dim   b ON b.br_ID    = ls.br_ID
                       AND ls.res_date BETWEEN b.effective_start_date
                                           AND b.effective_end_date
    JOIN service_dim  v ON v.serv_ID  = ls.serv_ID
                       AND ls.res_date BETWEEN v.effective_start_date
                                           AND v.effective_end_date
    WHERE ls.res_date >= v_from
    AND   NOT EXISTS (SELECT 1 FROM reservation_fact f
                      WHERE f.res_ID      = ls.res_ID
                        AND f.service_key = v.service_key
                        AND f.staff_key   = s.staff_key);

    v_count := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: refresh rows whose status or money moved.
    -- Rescheduling changes start_time/end_time too, which is why the
    -- derived res_duration is refreshed with them.
    --
    -- The price is not in the staging view, so this is a MERGE whose
    -- source joins the staging view to the service_dim version in
    -- force on the reservation date (same lookup as STEP 1). A row
    -- whose price lookup finds nothing is simply not matched, never
    -- NULLed out. Dimension KEYS are not touched.
    -- ---------------------------------------------------------------
    MERGE INTO reservation_fact f
    USING (
        SELECT ls.res_ID,
               v.service_key,
               s.staff_key,
               ls.clean_res_status,
               ls.start_time,
               ls.end_time,
               ls.res_duration,
               ls.clean_discount_amt,
               ls.clean_tax_amt,
               ROUND(  ls.line_count * v.serv_price
                     - ls.clean_discount_amt
                     + ls.clean_tax_amt, 2)          AS serv_total_amt
        FROM   reservation_fact_staging_v ls
        JOIN   service_dim v ON v.serv_ID = ls.serv_ID
                            AND ls.res_date BETWEEN v.effective_start_date
                                                AND v.effective_end_date
        -- staff_key is part of the match key, so the same SCD2 lookup
        -- STEP 1 used is repeated here.
        JOIN   staff_dim   s ON s.st_ID   = ls.st_ID
                            AND ls.res_date BETWEEN s.effective_start_date
                                                AND s.effective_end_date
        WHERE  ls.res_date >= v_from
    ) src
    ON (    f.res_ID      = src.res_ID
        AND f.service_key = src.service_key
        AND f.staff_key   = src.staff_key)
    WHEN MATCHED THEN UPDATE SET
        f.res_status        = src.clean_res_status,
        f.start_time        = src.start_time,
        f.end_time          = src.end_time,
        f.res_duration      = src.res_duration,
        f.serv_discount_amt = src.clean_discount_amt,
        f.serv_tax_amt      = src.clean_tax_amt,
        f.serv_total_amt    = src.serv_total_amt
    WHERE (   NVL(f.res_status, '~') <> NVL(src.clean_res_status, '~')
           OR NVL(f.start_time, DATE '1900-01-01')
                <> NVL(src.start_time, DATE '1900-01-01')
           OR NVL(f.end_time, DATE '1900-01-01')
                <> NVL(src.end_time, DATE '1900-01-01')
           OR NVL(f.serv_discount_amt, -1) <> NVL(src.clean_discount_amt, -1)
           OR NVL(f.serv_tax_amt, -1)      <> NVL(src.clean_tax_amt, -1)
           OR NVL(f.serv_total_amt, -1)    <> NVL(src.serv_total_amt, -1) );

    v_updated := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   reservation_fact_staging_v
    WHERE  res_date >= v_from
    AND   (status_defaulted = 'Y' OR time_unusable = 'Y'
        OR money_defaulted = 'Y');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('RESERVATION_FACT incremental load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Window from             : '
        || TO_CHAR(v_from, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(' - New records inserted    : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Existing records updated: ' || v_updated);
    DBMS_OUTPUT.PUT_LINE(' - Data quality corrections: ' || v_errors);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in RESERVATION_FACT incremental load: '
            || SQLERRM);
        RAISE;
END;
/
