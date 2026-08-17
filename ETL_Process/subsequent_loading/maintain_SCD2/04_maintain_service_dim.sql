-- ===================================================================
-- 04_maintain_service_dim.sql    SERVICE_DIM - MAINTAIN SCD TYPE 2
--
--   SECTION 1: no new view - reuses service_staging_v
--   SECTION 2: no new sequence - reuses seq_service_key
--   SECTION 3: PROCEDURE - expire changed rows, insert new versions
--   SECTION 4: run + verification
--
-- SCOPE: CHANGED RECORDS ONLY. New services belong to
--   sub_dimension\05_sub_service_dim.sql
--
-- Tracked attributes (all TYPE 2, versioned):
--   serv_name / serv_category / serv_price
-- The dimension carries no Type 1 attribute (the former derived
-- duration column no longer exists; actual slot length is a measure
-- on reservation_fact), so there is no in-place refresh step.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - reuses service_staging_v from
--   ETL_Process\initial_loading\init_dimension\04_init_service_dim.sql
--
-- SECTION 2: SEQUENCE - reuses seq_service_key, continuing from
-- wherever the last load left it.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_service_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff       DATE   := TRUNC(p_effective_date);
    v_expired   NUMBER := 0;
    v_versions  NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: expire changed services.
    -- Price uses NVL(...,-1): it is a NUMBER, so a string sentinel
    -- would raise ORA-01722.
    -- ---------------------------------------------------------------
    UPDATE service_dim d
    SET    d.effective_end_date = GREATEST(v_eff - 1,
                                           d.effective_start_date),
           d.is_current_flag    = 'N'
    WHERE  d.is_current_flag = 'Y'
    -- Never version BACKWARDS: expiring a version that starts on or
    -- after the effective date would corrupt the timeline.
    AND    d.effective_start_date < v_eff
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
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_service_key.NEXTVAL,
        s.serv_ID, s.clean_serv_name, s.clean_serv_category,
        s.clean_serv_price,
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

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SERVICE_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired        : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added  : ' || v_versions);

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
