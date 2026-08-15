-- ===================================================================
-- 04_maintain_service_dim.sql    SERVICE_DIM - MAINTAIN SCD 2 + SCD 1
--
--   SECTION 1: no new view - reuses service_staging_v
--   SECTION 2: no new sequence - reuses seq_service_key
--   SECTION 3: PROCEDURE - expire + version (Type 2), then refresh
--              serv_duration in place (Type 1)
--   SECTION 4: run + verification
--
-- SCOPE: CHANGED RECORDS ONLY. New services belong to
--   subsequentLoading\sub_dimension\05_sub_service_dim.sql
--
-- MIXED TYPES ON PURPOSE:
--   serv_name / serv_category / serv_price  -> TYPE 2, versioned
--   serv_duration                           -> TYPE 1, overwritten
--
-- serv_duration is an AVERAGE over reservation_detail, so it drifts a
-- little every time new bookings arrive. Versioning on it would create
-- a new row almost every run for no business reason. Overwriting it is
-- correct: it is a statistic about the service, not a business change.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - REUSED, NOT RECREATED
-- service_staging_v is defined in
--   initialLoading\init_dimension\04_init_service_dim.sql
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - REUSED, NOT RECREATED
-- seq_service_key continues from wherever the last load left it.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2 + TYPE 1)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_service_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff       DATE   := TRUNC(p_effective_date);
    v_expired   NUMBER := 0;
    v_versions  NUMBER := 0;
    v_durations NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: expire changed services.
    -- serv_duration is deliberately EXCLUDED - see the header note.
    -- ---------------------------------------------------------------
    UPDATE service_dim d
    SET    d.effective_end_date = GREATEST(v_eff - 1,
                                           d.effective_start_date),
           d.is_current_flag    = 'N'
    WHERE  d.is_current_flag = 'Y'
    AND EXISTS (
        SELECT 1
        FROM   service_staging_v s
        WHERE  s.serv_ID = d.serv_ID
          AND (   NVL(s.clean_serv_name, '~')
                    <> NVL(d.serv_name, '~')
               OR NVL(s.clean_serv_category, '~')
                    <> NVL(d.serv_category, '~')
               OR NVL(s.clean_serv_price, -1)
                    <> NVL(d.serv_price, -1) ));

    v_expired := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: new version for each service STEP 1 expired.
    -- ---------------------------------------------------------------
    INSERT INTO service_dim (
        service_key, serv_ID, serv_name, serv_category, serv_price,
        serv_duration, effective_start_date, effective_end_date,
        is_current_flag
    )
    SELECT
        seq_service_key.NEXTVAL,
        s.serv_ID, s.clean_serv_name, s.clean_serv_category,
        s.clean_serv_price, s.derived_serv_duration,
        v_eff,
        DATE '9999-12-31',
        'Y'
    FROM   service_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM service_dim d
                       WHERE d.serv_ID = s.serv_ID
                         AND d.is_current_flag = 'Y')
    AND    EXISTS     (SELECT 1 FROM service_dim d
                       WHERE d.serv_ID = s.serv_ID);

    v_versions := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 3: TYPE 1 refresh of the derived duration on CURRENT rows.
    -- Overwrites in place, creating no history.
    -- ---------------------------------------------------------------
    UPDATE service_dim d
    SET    d.serv_duration =
             (SELECT s.derived_serv_duration
              FROM   service_staging_v s
              WHERE  s.serv_ID = d.serv_ID)
    WHERE  d.is_current_flag = 'Y'
    AND    EXISTS (SELECT 1 FROM service_staging_v s
                   WHERE s.serv_ID = d.serv_ID
                     AND NVL(s.derived_serv_duration, -1)
                           <> NVL(d.serv_duration, -1));

    v_durations := SQL%ROWCOUNT;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SERVICE_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired        : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added  : ' || v_versions);
    DBMS_OUTPUT.PUT_LINE(' - Durations refreshed : ' || v_durations
        || '  (Type 1, in place)');

    IF v_expired <> v_versions THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: expired and inserted counts '
            || 'differ - run the integrity checks in SECTION 4.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in SERVICE_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
-- No argument -> the change is dated TODAY (SYSDATE).
EXEC maintain_service_dim_scd2;

-- Or date it to when the change ACTUALLY happened. The old version is
-- closed the day before, the new one opens on that date:
--     EXEC maintain_service_dim_scd2(DATE '2024-07-01');

-- Exactly ONE current row per natural key. Must return no rows.
SELECT serv_ID, COUNT(*) AS current_versions
FROM   service_dim
WHERE  is_current_flag = 'Y'
GROUP BY serv_ID HAVING COUNT(*) <> 1;

SELECT service_key, serv_ID, serv_name, serv_category, serv_price,
       serv_duration, effective_start_date, effective_end_date,
       is_current_flag
FROM   service_dim
ORDER BY serv_ID, service_key;

-- No expired row may still claim 9999-12-31
SELECT COUNT(*) AS bad_end_dates FROM service_dim
WHERE  is_current_flag = 'N' AND effective_end_date = DATE '9999-12-31';
-- expect 0

-- Re-run the EXEC: expect 0 expired, 0 versions. "Durations refreshed"
-- may be non-zero once and 0 thereafter, until new bookings arrive.
