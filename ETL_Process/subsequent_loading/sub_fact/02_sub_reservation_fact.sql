-- ===================================================================
-- 02_sub_reservation_fact.sql  RESERVATION_FACT - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses reservation_fact_staging_v
--   SECTION 2: no sequence - the PK is the degenerate res_det_ID
--   SECTION 3: PROCEDURE - insert new lines, then update changed ones
--   SECTION 4: run + verification
--
-- STEP 2 matters most on this fact. A reservation is booked as
-- 'Confirmed' and only later becomes 'Completed', 'Cancelled' or
-- 'No-Show'. Insert-only would freeze every booking at 'Confirmed' and
-- the no-show rate - one of the analyses this warehouse exists for -
-- would read as zero forever.
--
-- Backfill the whole of data2 (2023-2024):
--     EXEC load_res_fact_incremental(DATE '2023-01-01');
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - reuses reservation_fact_staging_v from
--   ETL_Process\initial_loading\init_fact\02_init_reservation_fact.sql
-- OLTP cleansing only; surrogate-key joins are written out below.
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- ===================================================================

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
    -- STEP 1: insert new service lines
    -- ---------------------------------------------------------------
    INSERT INTO reservation_fact (
        date_key, customer_key, staff_key, branch_key, service_key,
        res_ID, res_det_ID, res_status, start_time, end_time,
        start_hour, res_duration, serv_price,
        serv_discount_amt, serv_tax_amt, serv_total_amt
    )
    SELECT
        d.date_key, c.customer_key, s.staff_key, b.branch_key,
        v.service_key, ls.res_ID, ls.res_det_ID, ls.clean_res_status,
        ls.start_time, ls.end_time, ls.start_hour, ls.res_duration,
        ls.clean_serv_price, ls.clean_discount_amt, ls.clean_tax_amt,
        ls.serv_total_amt
    -- SCD2 joins pick the version in force on the appointment date.
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
                      WHERE f.res_det_ID = ls.res_det_ID);

    v_count := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: refresh lines whose status or money moved.
    -- Rescheduling changes start_time/end_time too, which is why the
    -- derived start_hour and res_duration are refreshed with them.
    -- ---------------------------------------------------------------
    UPDATE reservation_fact f
    SET   (res_status, start_time, end_time, start_hour, res_duration,
           serv_price, serv_discount_amt, serv_tax_amt, serv_total_amt) =
          (SELECT ls.clean_res_status, ls.start_time, ls.end_time,
                  ls.start_hour, ls.res_duration, ls.clean_serv_price,
                  ls.clean_discount_amt, ls.clean_tax_amt,
                  ls.serv_total_amt
           FROM   reservation_fact_staging_v ls
           WHERE  ls.res_det_ID = f.res_det_ID)
    WHERE EXISTS (
        SELECT 1
        FROM   reservation_fact_staging_v ls
        WHERE  ls.res_det_ID = f.res_det_ID
          AND  ls.res_date >= v_from
          AND (   NVL(f.res_status, '~') <> NVL(ls.clean_res_status, '~')
               OR NVL(f.start_time, DATE '1900-01-01')
                    <> NVL(ls.start_time, DATE '1900-01-01')
               OR NVL(f.end_time, DATE '1900-01-01')
                    <> NVL(ls.end_time, DATE '1900-01-01')
               OR NVL(f.serv_price, -1)        <> NVL(ls.clean_serv_price, -1)
               OR NVL(f.serv_discount_amt, -1) <> NVL(ls.clean_discount_amt, -1)
               OR NVL(f.serv_tax_amt, -1)      <> NVL(ls.clean_tax_amt, -1) ));

    v_updated := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   reservation_fact_staging_v
    WHERE  res_date >= v_from
    AND   (status_defaulted = 'Y' OR time_unusable = 'Y'
        OR price_defaulted = 'Y'  OR money_defaulted = 'Y');

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
