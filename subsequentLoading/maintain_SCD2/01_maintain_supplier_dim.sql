-- ===================================================================
-- 01_maintain_supplier_dim.sql   SUPPLIER_DIM - MAINTAIN SCD TYPE 2
--
--   SECTION 1: no new view - reuses supplier_staging_v
--   SECTION 2: no new sequence - reuses seq_supplier_key
--   SECTION 3: PROCEDURE - expire changed rows, insert new versions
--   SECTION 4: run + verification
--
-- SCOPE: CHANGED RECORDS ONLY.
--   STEP 1  expire the current row of any supplier whose attributes
--           changed  (effective_end_date = yesterday, flag = 'N')
--   STEP 2  insert a new current version for exactly those suppliers
--
-- BRAND-NEW suppliers are NOT inserted here - that is the job of
-- subsequentLoading\sub_dimension\02_sub_supplier_dim.sql. The two
-- steps are deliberately orthogonal:
--     sub_dimension  -> natural keys that do not exist yet
--     maintain_SCD2  -> natural keys that exist and changed
-- Run sub_dimension FIRST, then this.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - REUSED, NOT RECREATED
-- supplier_staging_v is defined in
--   initialLoading\init_dimension\03_init_supplier_dim.sql
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - REUSED, NOT RECREATED
-- seq_supplier_key continues from wherever the last load left it.
-- Each new VERSION consumes a key, exactly like a new record does.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (MAINTAIN SCD TYPE 2)
-- ===================================================================
CREATE OR REPLACE PROCEDURE maintain_supplier_dim_scd2(
    p_effective_date IN DATE DEFAULT SYSDATE
) AS
    v_eff      DATE   := TRUNC(p_effective_date);
    v_expired  NUMBER := 0;
    v_versions NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: expire changed rows.
    --
    -- NVL on BOTH sides is essential. In SQL, NULL <> 'x' evaluates to
    -- UNKNOWN, not TRUE, so a bare <> silently misses every change
    -- that involves a NULL on either side.
    -- ---------------------------------------------------------------
    UPDATE supplier_dim d
    SET    d.effective_end_date = GREATEST(v_eff - 1,
                                           d.effective_start_date),
           d.is_current_flag    = 'N'
    WHERE  d.is_current_flag = 'Y'
    AND EXISTS (
        SELECT 1
        FROM   supplier_staging_v s
        WHERE  s.sup_ID = d.sup_ID
          AND (   NVL(s.clean_sup_name, '~')  <> NVL(d.sup_name, '~')
               OR NVL(s.clean_sup_phone, '~') <> NVL(d.sup_phone, '~')
               OR NVL(s.clean_sup_email, '~') <> NVL(d.sup_email, '~') ));

    v_expired := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: insert the new version for each supplier STEP 1 expired.
    --
    -- Two conditions, and both matter:
    --   NOT EXISTS current  -> the row was just expired (or never had one)
    --   EXISTS any          -> the supplier already has history, so it
    --                          is a CHANGE, not a brand-new supplier
    -- Without the second test this would also insert new suppliers and
    -- duplicate what sub_dimension already does.
    -- ---------------------------------------------------------------
    INSERT INTO supplier_dim (
        supplier_key, sup_ID, sup_name, sup_phone, sup_email,
        effective_start_date, effective_end_date, is_current_flag
    )
    SELECT
        seq_supplier_key.NEXTVAL,
        s.sup_ID, s.clean_sup_name, s.clean_sup_phone, s.clean_sup_email,
        v_eff,
        DATE '9999-12-31',
        'Y'
    FROM   supplier_staging_v s
    WHERE  NOT EXISTS (SELECT 1 FROM supplier_dim d
                       WHERE d.sup_ID = s.sup_ID
                         AND d.is_current_flag = 'Y')
    AND    EXISTS     (SELECT 1 FROM supplier_dim d
                       WHERE d.sup_ID = s.sup_ID);

    v_versions := SQL%ROWCOUNT;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUPPLIER_DIM SCD2 maintenance completed:');
    DBMS_OUTPUT.PUT_LINE(' - Rows expired       : ' || v_expired);
    DBMS_OUTPUT.PUT_LINE(' - New versions added : ' || v_versions);

    IF v_expired <> v_versions THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: expired and inserted counts '
            || 'differ. Every expired row must get a replacement - '
            || 'run the integrity checks in SECTION 4.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in SUPPLIER_DIM SCD2 maintenance: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
-- No argument -> the change is dated TODAY (SYSDATE).
EXEC maintain_supplier_dim_scd2;

-- Or date it to when the change ACTUALLY happened. The old version is
-- closed the day before, the new one opens on that date:
--     EXEC maintain_supplier_dim_scd2(DATE '2024-07-01');

-- Exactly ONE current row per natural key. Must return no rows.
SELECT sup_ID, COUNT(*) AS current_versions
FROM   supplier_dim
WHERE  is_current_flag = 'Y'
GROUP BY sup_ID HAVING COUNT(*) <> 1;

-- Version history for anything that changed
SELECT supplier_key, sup_ID, sup_name, sup_phone,
       effective_start_date, effective_end_date, is_current_flag
FROM   supplier_dim
WHERE  sup_ID IN (SELECT sup_ID FROM supplier_dim
                  GROUP BY sup_ID HAVING COUNT(*) > 1)
ORDER BY sup_ID, supplier_key;

-- No expired row may still claim 9999-12-31
SELECT COUNT(*) AS bad_end_dates FROM supplier_dim
WHERE  is_current_flag = 'N' AND effective_end_date = DATE '9999-12-31';
-- expect 0

-- Re-run the EXEC above: must report 0 expired, 0 versions.
