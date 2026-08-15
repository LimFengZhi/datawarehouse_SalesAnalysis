-- ===================================================================
-- 02_init_reservation_fact.sql   RESERVATION_FACT
-- Grain: one row per service line booked  (88,790 rows)
-- Source: RESERVATION_DETAIL joined to RESERVATION
--
-- TWO THINGS THE SOURCE DOES NOT STORE, resolved here:
--   1. serv_price - reservation_detail has a discount and a tax but
--      no price. It comes from SERVICE_DIM.
--   2. start_hour / res_duration - derived from start_time & end_time,
--      for the peak-hour and therapist-utilisation analyses.
--
-- staff_key comes from RESERVATION_DETAIL (the therapist who performed
-- the service), NOT from the reservation header.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW reservation_fact_staging_v AS
SELECT
    dd.date_key,
    cd.customer_key,
    sd.staff_key,
    bd.branch_key,
    vd.service_key,

    r.res_ID,                                     -- degenerate dim
    rd.res_det_ID,                                -- degenerate dim / PK

    -- All statuses load, including Cancelled and No-Show, so the
    -- warehouse can report no-show rates. Filter in your queries.
    r.res_status,

    rd.start_time,
    rd.end_time,

    -- DERIVED: appointment hour, 10..20. Peak is 16:00-18:00.
    CASE
        WHEN rd.start_time IS NULL THEN NULL
        ELSE TO_NUMBER(TO_CHAR(rd.start_time, 'HH24'))
    END                                            AS start_hour,

    -- DERIVED: actual slot length in minutes. Guarded against a NULL
    -- or reversed pair, which would otherwise give a negative duration.
    CASE
        WHEN rd.start_time IS NULL OR rd.end_time IS NULL
          OR rd.end_time <= rd.start_time THEN NULL
        ELSE ROUND((rd.end_time - rd.start_time) * 24 * 60)
    END                                            AS res_duration,

    -- Measures. Price is carried from the dimension because the source
    -- line does not store it.
    vd.serv_price,
    ROUND(NVL(rd.serv_discount, 0), 2)             AS serv_discount_amt,
    ROUND(NVL(rd.serv_tax, 0), 2)                  AS serv_tax_amt,
    ROUND(  vd.serv_price
          - NVL(rd.serv_discount, 0)
          + NVL(rd.serv_tax, 0), 2)                AS serv_total_amt

FROM reservation_detail rd
JOIN reservation  r  ON r.res_ID  = rd.res_ID
-- Date of the appointment itself; falls back to the booking date if a
-- slot has no start_time.
JOIN date_dim     dd ON dd.cal_date = NVL(TRUNC(rd.start_time),
                                          TRUNC(r.booking_date))
JOIN customer_dim cd ON cd.cus_ID  = r.cus_ID
                    AND cd.is_current_flag = 'Y'
JOIN staff_dim    sd ON sd.st_ID   = rd.st_ID
                    AND sd.is_current_flag = 'Y'
JOIN branch_dim   bd ON bd.br_ID   = r.br_ID
                    AND bd.is_current_flag = 'Y'
JOIN service_dim  vd ON vd.serv_ID = rd.serv_ID
                    AND vd.is_current_flag = 'Y';

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- res_det_ID from the source is the PK and a degenerate dimension.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_reservation_fact_initial AS
    v_count   NUMBER;
    v_source  NUMBER;
    v_dropped NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM reservation_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('RESERVATION_FACT already contains data. '
            || 'Delete it first if you intend to reload.');
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
        date_key, customer_key, staff_key, branch_key, service_key,
        res_ID, res_det_ID, res_status, start_time, end_time,
        start_hour, res_duration, serv_price,
        serv_discount_amt, serv_tax_amt, serv_total_amt
    FROM reservation_fact_staging_v;

    v_count   := SQL%ROWCOUNT;
    v_dropped := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('RESERVATION_FACT initial load completed: '
        || v_count || ' records inserted.');

    IF v_dropped <> 0 THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: ' || v_dropped
            || ' source rows did NOT load - a dimension lookup failed. '
            || 'Run the orphan checks in SECTION 4.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('All ' || v_source
            || ' source rows resolved every dimension key.');
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
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_reservation_fact_initial;

-- Expect 88790 in both columns
SELECT (SELECT COUNT(*) FROM reservation_fact)   AS fact_rows,
       (SELECT COUNT(*) FROM reservation_detail) AS source_rows
FROM dual;

-- Which lookup failed, if any. All must return 0.
SELECT COUNT(*) AS no_date FROM reservation_detail rd
JOIN reservation r ON r.res_ID = rd.res_ID
WHERE NOT EXISTS (SELECT 1 FROM date_dim dd
                  WHERE dd.cal_date = NVL(TRUNC(rd.start_time),
                                          TRUNC(r.booking_date)));

SELECT COUNT(*) AS no_service FROM reservation_detail rd
WHERE NOT EXISTS (SELECT 1 FROM service_dim vd
                  WHERE vd.serv_ID = rd.serv_ID
                    AND vd.is_current_flag = 'Y');

SELECT COUNT(*) AS no_staff FROM reservation_detail rd
WHERE NOT EXISTS (SELECT 1 FROM staff_dim sd
                  WHERE sd.st_ID = rd.st_ID AND sd.is_current_flag = 'Y');

-- Derived columns must be sane: hours 10..20, no negative durations
SELECT MIN(start_hour) AS min_hr, MAX(start_hour) AS max_hr,
       MIN(res_duration) AS min_mins, MAX(res_duration) AS max_mins,
       COUNT(*) - COUNT(res_duration) AS null_durations
FROM reservation_fact;

-- THE COVID CHECK. Services were banned during MCO 1.0 and FMCO, so
-- these two windows must return ZERO completed reservations.
SELECT d.cal_year, d.cal_quarter, COUNT(*) AS completed_services
FROM reservation_fact f
JOIN date_dim d ON d.date_key = f.date_key
WHERE f.res_status = 'Completed'
  AND ( (d.cal_date BETWEEN DATE '2020-04-01' AND DATE '2020-04-30')
     OR (d.cal_date BETWEEN DATE '2021-06-01' AND DATE '2021-08-31') )
GROUP BY d.cal_year, d.cal_quarter
ORDER BY 1, 2;
-- expect NO ROWS

-- Service revenue by year. Expect ~2.48m / 1.66m / 1.18m / 3.52m
SELECT d.cal_year,
       ROUND(SUM(f.serv_price - f.serv_discount_amt), 2) AS net_revenue,
       COUNT(*) AS service_lines
FROM reservation_fact f
JOIN date_dim d ON d.date_key = f.date_key
WHERE f.res_status = 'Completed'
GROUP BY d.cal_year
ORDER BY d.cal_year;

-- Peak booking hour. Expect a bulge at 16:00-18:00.
SELECT start_hour, COUNT(*) AS bookings
FROM reservation_fact
WHERE res_status = 'Completed'
GROUP BY start_hour
ORDER BY start_hour;
