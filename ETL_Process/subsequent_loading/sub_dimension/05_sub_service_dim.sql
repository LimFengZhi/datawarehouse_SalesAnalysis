-- ===================================================================
-- 05_sub_service_dim.sql    SERVICE_DIM - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses service_staging_v
--   SECTION 2: no new sequence - reuses seq_service_key
--   SECTION 3: PROCEDURE - insert new records only
--   SECTION 4: run + verification
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
BEGIN
    INSERT INTO service_dim (
        service_key, serv_ID, serv_name, serv_category, serv_price,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_service_key.NEXTVAL,
        s.serv_ID, s.clean_serv_name, s.clean_serv_category,
        s.clean_serv_price,
        DATE '2019-01-01',   -- first version: the first sales year (facts start 2019-01-01)
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
