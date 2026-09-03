-- ===================================================================
-- 02_maintain_service_dim.sql    SERVICE_DIM - MAINTAIN SCD TYPE 2
--
--   SECTION 1: no new view - reuses service_staging_v
--   SECTION 2: no new sequence - reuses seq_service_key
--   SECTION 3: PROCEDURE - cursor FOR-loop: expire changed rows,
--              insert new versions
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- SCOPE: CHANGED RECORDS ONLY. New services belong to
--   sub_dimension\05_sub_service_dim.sql
--
-- TRACKED (TYPE 2): serv_price ONLY - only a price change creates
-- history. A rename or a recategorisation is a correction handled by
-- sub_dimension's STEP 2 (Type 1). This procedure versions the price
-- and nothing else.
-- The dimension carries no Type 1 attribute (the former derived
-- duration column no longer exists; actual slot length is a measure
-- on reservation_fact), so there is no in-place refresh step.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_service_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff      DATE   := TRUNC(p_effective_date);
    v_expired  NUMBER := 0;
    v_versions NUMBER := 0;

    CURSOR changed_services_cursor IS
        SELECT d.service_key AS old_key,
               s.serv_ID, s.clean_serv_name, s.clean_serv_category,
               s.clean_serv_price
        FROM   service_staging_v s
        JOIN   service_dim d ON d.serv_ID = s.serv_ID
                      AND d.is_current_flag = 'Y'
        WHERE  d.effective_start_date < v_eff
        AND   NVL(s.clean_serv_price, -1)
                <> NVL(d.serv_price, -1);
BEGIN
    FOR rec IN changed_services_cursor LOOP
        -- -----------------------------------------------------------
        -- STEP 1: expire the old current version (ends yesterday,
        -- never before its own start date).
        -- -----------------------------------------------------------
        UPDATE service_dim
        SET    effective_end_date = GREATEST(v_eff - 1,
                                             effective_start_date),
               is_current_flag    = 'N'
        WHERE  service_key = rec.old_key;
        v_expired := v_expired + 1;

        -- -----------------------------------------------------------
        -- STEP 2: insert the replacement version, current from v_eff.
        -- Both statements sit in ONE loop pass, so every expired row
        -- gets its replacement - the two counts cannot drift apart.
        -- -----------------------------------------------------------
        INSERT INTO service_dim (
            service_key, serv_ID, serv_name, serv_category, serv_price,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_service_key.NEXTVAL,
            rec.serv_ID, rec.clean_serv_name, rec.clean_serv_category,
            rec.clean_serv_price,
            v_eff,
            DATE '9999-12-31',
            'Y'
        );
        v_versions := v_versions + 1;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SERVICE_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in SERVICE_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/
