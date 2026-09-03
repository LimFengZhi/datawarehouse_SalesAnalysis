-- ===================================================================
-- 02_init_reservation_fact.sql   RESERVATION_FACT
-- Grain: one row per SERVICE per THERAPIST per RESERVATION
-- Source: RESERVATION_DETAIL joined to RESERVATION
--
--   SECTION 1: staging VIEW - OLTP cleansing + line aggregation
--   SECTION 2: no sequence   - PK is composite (dimension keys +
--                              res_ID); (res_ID, service_key, staff_key)
--                              is unique by grain (no constraint) and drives the NOT EXISTS
--
-- GRAIN: the ERD carries no detail-line ID on the fact, so the view
-- GROUPs BY (res_ID, serv_ID, st_ID) and SUMs discount / tax /
-- duration (MIN start, MAX end). In the data every such group is one
-- detail line, so nothing actually folds - the GROUP BY only protects
-- the composite PK. line_count (not stored) says how many lines a
-- row holds; the procedure multiplies the service price by it.
--   SECTION 3: PROCEDURE     - resolves surrogate keys, then inserts
--   SECTION 4: run
--
-- The view exposes natural keys and the raw appointment date only.
--   * date_key comes from reservation.reservation_date - the day of
--     the APPOINTMENT. booking_date (the day the booking was made,
--     0-14 days earlier) is NOT used by the fact.
--   * res_duration is derived in the view (actual minutes).
--   * The service price is NOT stored on reservation_detail. It comes
--     from service_dim.serv_price of the SCD2 version in force on the
--     reservation date, so serv_total_amt is computed in the PROCEDURE:
--         serv_total_amt = line_count * s.serv_price - discount + tax
--         serv_net_amt   = line_count * s.serv_price - discount
--     serv_net_amt is the same figure without the SST, which is collected
--     for the government - sum THAT column for service revenue.
-- staff_key comes from RESERVATION_DETAIL (the therapist who performed
-- the service), NOT from the reservation header.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW reservation_fact_staging_v AS
SELECT
    r.res_ID,                                     -- degenerate dim
    rd.serv_ID,                                   -- (res_ID, serv_ID, st_ID)
    rd.st_ID,                                     --   = the grain

    -- ---------- NATURAL keys ----------
    r.cus_ID,
    r.br_ID,
    -- Date of the appointment itself (NOT booking_date, NOT the time
    -- part of start_time). Drives date_key and every SCD2 lookup.
    TRUNC(r.reservation_date)                      AS res_date,

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

    MIN(rd.start_time)                             AS start_time,
    MAX(rd.end_time)                               AS end_time,

    -- DERIVED: slot length in minutes, summed over the folded lines.
    -- Guarded against a NULL or reversed pair, which would otherwise
    -- give a negative duration.
    SUM(CASE
            WHEN rd.start_time IS NULL OR rd.end_time IS NULL
              OR rd.end_time <= rd.start_time THEN NULL
            ELSE ROUND((rd.end_time - rd.start_time) * 24 * 60)
        END)                                       AS res_duration,

    -- ---------- measures ----------
    -- No price here: reservation_detail has none, and the view must
    -- not read service_dim. The procedure adds the dimension price.
    SUM(ROUND(NVL(rd.serv_discount, 0), 2))        AS clean_discount_amt,
    SUM(ROUND(NVL(rd.serv_tax, 0), 2))             AS clean_tax_amt,

    -- How many OLTP reservation_detail lines were folded into this row
    COUNT(*)                                       AS line_count,

    -- ---------- data quality flags ----------
    CASE WHEN r.res_status IS NULL
         THEN 'Y' ELSE 'N' END                     AS status_defaulted,
    MAX(CASE WHEN rd.start_time IS NULL OR rd.end_time IS NULL
                  OR rd.end_time <= rd.start_time
             THEN 'Y' ELSE 'N' END)                AS time_unusable,
    MAX(CASE WHEN rd.serv_discount IS NULL OR rd.serv_tax IS NULL
             THEN 'Y' ELSE 'N' END)                AS money_defaulted

FROM reservation_detail rd
JOIN reservation r  ON r.res_ID   = rd.res_ID
WHERE r.res_ID            IS NOT NULL
  AND r.cus_ID            IS NOT NULL
  AND r.br_ID             IS NOT NULL
  AND rd.st_ID            IS NOT NULL
  AND rd.serv_ID          IS NOT NULL
  AND r.reservation_date  IS NOT NULL
GROUP BY r.res_ID, rd.serv_ID, rd.st_ID, r.cus_ID, r.br_ID,
         TRUNC(r.reservation_date), r.res_status;

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- The PK is the composite of the five dimension keys plus res_ID;
-- (res_ID, service_key, staff_key) is unique by grain (no constraint) and is what the
-- incremental NOT EXISTS uses.
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

    -- Source grain is (reservation, service, therapist): count the
    -- distinct groups, not the detail lines.
    SELECT COUNT(*) INTO v_source
    FROM  (SELECT DISTINCT res_ID, serv_ID, st_ID FROM reservation_detail);

    INSERT INTO reservation_fact (
        date_key, customer_key, staff_key, branch_key, service_key,
        res_ID, res_duration, res_status,
        start_time, end_time,
        serv_discount_amt, serv_tax_amt, serv_total_amt,
        serv_net_amt
    )
    SELECT
        d.date_key,
        c.customer_key,
        s.staff_key,
        b.branch_key,
        v.service_key,
        ls.res_ID,
        ls.res_duration,
        ls.clean_res_status,
        ls.start_time,
        ls.end_time,
        ls.clean_discount_amt,
        ls.clean_tax_amt,
        -- Price = the service_dim version in force on the reservation
        -- date (joined below), so a later price change never rewrites
        -- history.
        ROUND(  ls.line_count * v.serv_price
              - ls.clean_discount_amt
              + ls.clean_tax_amt, 2)                AS serv_total_amt,
        -- the same base terms without the tax = revenue
        ROUND(  ls.line_count * v.serv_price
              - ls.clean_discount_amt, 2)           AS serv_net_amt
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
    JOIN service_dim  v ON v.serv_ID  = ls.serv_ID
                       AND ls.res_date BETWEEN v.effective_start_date
                                           AND v.effective_end_date;

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   reservation_fact_staging_v
    WHERE  status_defaulted = 'Y' OR time_unusable = 'Y'
       OR  money_defaulted = 'Y';

    v_orphaned := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('RESERVATION_FACT initial load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Records inserted        : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Data quality corrections: ' || v_errors);
    DBMS_OUTPUT.PUT_LINE(' - Source groups not loaded: ' || v_orphaned);

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
-- ===================================================================
EXEC load_reservation_fact_initial;
