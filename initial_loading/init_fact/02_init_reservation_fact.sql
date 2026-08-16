-- ===================================================================
-- 02_init_reservation_fact.sql   RESERVATION_FACT
-- Grain: one row per service line booked  (88,790 rows in data\)
-- Source: RESERVATION_DETAIL joined to RESERVATION and SERVICE
--
--   SECTION 1: staging VIEW - OLTP cleansing ONLY
--   SECTION 2: no sequence   - the PK is the degenerate res_det_ID
--   SECTION 3: PROCEDURE     - resolves surrogate keys, then inserts
--   SECTION 4: run
--
-- The view exposes natural keys and the raw appointment date only.
-- Three things the source does not store, resolved in the view:
--   1. serv_price   - joined from the OLTP SERVICE table (not the dim)
--   2. start_hour   - derived, for peak-hour analysis
--   3. res_duration - derived, actual minutes
-- staff_key comes from RESERVATION_DETAIL (the therapist who performed
-- the service), NOT from the reservation header.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW reservation_fact_staging_v AS
SELECT
    rd.res_det_ID,                                -- degenerate dim / PK
    r.res_ID,                                     -- degenerate dim

    -- ---------- NATURAL keys ----------
    r.cus_ID,
    r.br_ID,
    rd.st_ID,
    rd.serv_ID,
    -- Date of the appointment itself; falls back to the booking date
    -- if a slot has no start_time.
    NVL(TRUNC(rd.start_time), TRUNC(r.booking_date))
                                                   AS res_date,

    -- ---------- cleansed attributes ----------
    CASE
        WHEN UPPER(TRIM(r.res_status)) IN ('COMPLETED','COMPLETE','DONE')
            THEN 'Completed'
        WHEN UPPER(TRIM(r.res_status)) IN ('CANCELLED','CANCELED','VOID')
            THEN 'Cancelled'
        WHEN UPPER(TRIM(r.res_status)) IN ('NO-SHOW','NO SHOW','NOSHOW')
            THEN 'No-Show'
        WHEN UPPER(TRIM(r.res_status)) IN ('CONFIRMED','CONFIRM')
            THEN 'Confirmed'
        WHEN UPPER(TRIM(r.res_status)) IN ('BOOKED','BOOKING','NEW')
            THEN 'Booked'
        WHEN r.res_status IS NULL THEN 'Booked'
        ELSE INITCAP(TRIM(r.res_status))
    END                                            AS clean_res_status,

    rd.start_time,
    rd.end_time,

    -- DERIVED: appointment hour, 10..20
    CASE WHEN rd.start_time IS NULL THEN NULL
         ELSE TO_NUMBER(TO_CHAR(rd.start_time, 'HH24'))
    END                                            AS start_hour,

    -- DERIVED: slot length in minutes. Guarded against a NULL or
    -- reversed pair, which would otherwise give a negative duration.
    CASE
        WHEN rd.start_time IS NULL OR rd.end_time IS NULL
          OR rd.end_time <= rd.start_time THEN NULL
        ELSE ROUND((rd.end_time - rd.start_time) * 24 * 60)
    END                                            AS res_duration,

    -- ---------- measures ----------
    CASE WHEN sv.serv_price IS NULL OR sv.serv_price < 0
         THEN 0 ELSE sv.serv_price END             AS clean_serv_price,
    ROUND(NVL(rd.serv_discount, 0), 2)             AS clean_discount_amt,
    ROUND(NVL(rd.serv_tax, 0), 2)                  AS clean_tax_amt,
    ROUND(  CASE WHEN sv.serv_price IS NULL OR sv.serv_price < 0
                 THEN 0 ELSE sv.serv_price END
          - NVL(rd.serv_discount, 0)
          + NVL(rd.serv_tax, 0), 2)                AS serv_total_amt,

    -- ---------- data quality flags ----------
    CASE WHEN r.res_status IS NULL
         THEN 'Y' ELSE 'N' END                     AS status_defaulted,
    CASE WHEN rd.start_time IS NULL OR rd.end_time IS NULL
              OR rd.end_time <= rd.start_time
         THEN 'Y' ELSE 'N' END                     AS time_unusable,
    CASE WHEN sv.serv_price IS NULL OR sv.serv_price < 0
         THEN 'Y' ELSE 'N' END                     AS price_defaulted,
    CASE WHEN rd.serv_discount IS NULL OR rd.serv_tax IS NULL
         THEN 'Y' ELSE 'N' END                     AS money_defaulted

FROM reservation_detail rd
JOIN reservation r  ON r.res_ID   = rd.res_ID
JOIN service     sv ON sv.serv_ID = rd.serv_ID    -- OLTP, not the dim
WHERE rd.res_det_ID IS NOT NULL
  AND r.res_ID      IS NOT NULL
  AND r.cus_ID      IS NOT NULL
  AND r.br_ID       IS NOT NULL
  AND rd.st_ID      IS NOT NULL
  AND rd.serv_ID    IS NOT NULL
  AND NVL(rd.start_time, r.booking_date) IS NOT NULL;

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- res_det_ID from the source is the PK and a degenerate dimension.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_reservation_fact_initial AS
    v_count    NUMBER;
    v_errors   NUMBER := 0;
    v_orphaned NUMBER := 0;
    v_source   NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM reservation_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('RESERVATION_FACT already contains data. Use '
            || 'load_res_fact_incremental for updates.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_source FROM reservation_detail;

    INSERT INTO reservation_fact (
        date_key, customer_key, staff_key, branch_key, service_key,
        res_ID, res_det_ID, res_status, start_time, end_time,
        start_hour, res_duration, serv_price,
        serv_discount_amt, serv_tax_amt, serv_total_amt
    )
    SELECT
        d.date_key,
        c.customer_key,
        s.staff_key,
        b.branch_key,
        v.service_key,
        ls.res_ID,
        ls.res_det_ID,
        ls.clean_res_status,
        ls.start_time,
        ls.end_time,
        ls.start_hour,
        ls.res_duration,
        ls.clean_serv_price,
        ls.clean_discount_amt,
        ls.clean_tax_amt,
        ls.serv_total_amt
    FROM reservation_fact_staging_v ls
    JOIN date_dim     d ON d.cal_date = ls.res_date
    JOIN customer_dim c ON c.cus_ID   = ls.cus_ID
                       AND c.is_current_flag = 'Y'
    JOIN staff_dim    s ON s.st_ID    = ls.st_ID
                       AND s.is_current_flag = 'Y'
    JOIN branch_dim   b ON b.br_ID    = ls.br_ID
                       AND b.is_current_flag = 'Y'
    JOIN service_dim  v ON v.serv_ID  = ls.serv_ID
                       AND v.is_current_flag = 'Y';

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   reservation_fact_staging_v
    WHERE  status_defaulted = 'Y' OR time_unusable = 'Y'
       OR  price_defaulted = 'Y'  OR money_defaulted = 'Y';

    v_orphaned := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('RESERVATION_FACT initial load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Records inserted        : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Data quality corrections: ' || v_errors);
    DBMS_OUTPUT.PUT_LINE(' - Source rows not loaded  : ' || v_orphaned);

    IF v_orphaned <> 0 THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: a dimension lookup failed for '
            || 'those rows. Run the orphan checks in SECTION 4.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in RESERVATION_FACT initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN
-- Verification queries live in ..\validate_initial_loading.sql
-- ===================================================================
EXEC load_reservation_fact_initial;
