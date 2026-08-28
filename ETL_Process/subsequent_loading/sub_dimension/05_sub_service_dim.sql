-- ===================================================================
-- 05_sub_service_dim.sql    SERVICE_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses service_staging_v
--   SECTION 2: no new sequence - reuses seq_service_key
--   SECTION 3: PROCEDURE - cursor FOR-loop inserts new records only
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: NEW RECORDS ONLY - a new service on the menu is added.
--
-- Name / category / price changes on EXISTING services are not
-- handled here - that is SCD Type 2 and belongs to the separate
-- maintain-SCD2 step. effective_start_date / end_date /
-- is_current_flag are populated on insert so that step has a clean
-- starting point.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_service_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
    -- The NOT EXISTS anti-join lives INSIDE the cursor query, so a
    -- second run fetches nothing - that is what keeps this idempotent.
    -- Cursor FOR-loop is the deliberate idiom for the small dimension
    -- loads; set-based DML stays where volume demands it (the facts).
    CURSOR new_services_cursor IS
        SELECT s.*
        FROM   service_staging_v s
        WHERE  NOT EXISTS (SELECT 1 FROM service_dim d
                           WHERE d.serv_ID = s.serv_ID);
BEGIN
    FOR rec IN new_services_cursor LOOP
        INSERT INTO service_dim (
            service_key, serv_ID, serv_name, serv_category, serv_price,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_service_key.NEXTVAL,
            rec.serv_ID, rec.clean_serv_name, rec.clean_serv_category,
            rec.clean_serv_price,
            DATE '2019-01-01',
            DATE '9999-12-31',
            'Y'
        );
        v_new := v_new + 1;
    END LOOP;

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
