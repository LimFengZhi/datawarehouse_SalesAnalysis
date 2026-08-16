-- ===================================================================
-- 05_sub_service_dim.sql    SERVICE_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses service_staging_v
--   SECTION 2: no new sequence - reuses seq_service_key
--   SECTION 3: PROCEDURE - insert new records only
--   SECTION 4: run + verification
--
-- SCOPE: NEW RECORDS ONLY - a new service on the menu is added, with
-- its serv_duration derived from real bookings by the staging view.
--
-- Price changes and duration drift on EXISTING services are not
-- handled here. Duration in particular is an average over
-- reservation_detail, so it moves slightly on every run - refreshing
-- it belongs to the maintain step, where it should be treated as a
-- Type 1 attribute (overwrite, no new version) rather than Type 2.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - REUSED, NOT RECREATED
-- service_staging_v is defined in
--   initialLoading\init_dimension\04_init_service_dim.sql
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - REUSED, NOT RECREATED
-- seq_service_key already issued keys 1000..1015. It continues at 1016.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_service_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
BEGIN
    INSERT INTO service_dim (
        service_key, serv_ID, serv_name, serv_category, serv_price,
        serv_duration, effective_start_date, effective_end_date,
        is_current_flag
    )
    SELECT
        seq_service_key.NEXTVAL,
        s.serv_ID, s.clean_serv_name, s.clean_serv_category,
        s.clean_serv_price, s.derived_serv_duration,
        DATE '2019-01-01',   -- first version: start of recorded history
        DATE '9999-12-31',
        'Y'
    FROM   service_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM service_dim d
                       WHERE d.serv_ID = s.serv_ID);

    v_new := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_total FROM service_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SERVICE_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New services inserted  : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Already present        : '
        || (v_total - v_new));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in SERVICE_DIM subsequent load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
-- Procedure created above. The EXEC now lives in the folder runner
--   00_run_all_sub_dimensions.sql
-- so every call and its arguments sit in ONE place.
--   EXEC load_service_dim_incremental;

-- One row per natural key. Must return no rows.
SELECT serv_ID, COUNT(*) AS rows_per_key
FROM   service_dim
GROUP BY serv_ID HAVING COUNT(*) > 1;

SELECT service_key, serv_ID, serv_name, serv_category, serv_price,
       serv_duration
FROM   service_dim
ORDER BY service_key;

-- Every OLTP service is represented
SELECT COUNT(*) AS missing_from_dim
FROM   service s
WHERE  NOT EXISTS (SELECT 1 FROM service_dim d
                   WHERE d.serv_ID = s.serv_ID);
-- expect 0

-- Re-run the EXEC above: must report 0 new services inserted.
