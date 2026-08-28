-- ===================================================================
-- 01_sub_date_dim.sql        DATE_DIM - SUBSEQUENT (INCREMENTAL) LOAD
--
-- Extends the calendar up to a date you pass (defaults to today):
--     EXEC load_date_dim_incremental;                     -- to SYSDATE
--     EXEC load_date_dim_incremental(DATE '2024-12-31');  -- data24 run
--
--   SECTION 1: no new view - reuses date_staging_v
--   SECTION 2: no new sequence - reuses date_dim_seq
--   SECTION 3: PROCEDURE - incremental load (set-based, like the
--              initial load; the row volume is a year of days, but the
--              insert is one INSERT..SELECT either way)
--   SECTION 4: none - the EXEC lives in exec_sub_proc24/25.sql
--
-- Safe to re-run: a NOT EXISTS on cal_date means days already loaded
-- are never inserted twice, and a p_end_date already covered is a
-- polite no-op.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_date_dim_incremental(
    p_end_date IN DATE DEFAULT SYSDATE
) AS
    v_last_date  DATE;
    v_target_end DATE := TRUNC(p_end_date);
    v_view_max   DATE;
    v_count      NUMBER := 0;
BEGIN
    -- Highest REAL calendar date. date_key 0 is the Unknown member
    -- (1900-01-01) and must not be treated as calendar data.
    SELECT MAX(cal_date) INTO v_last_date
    FROM   date_dim
    WHERE  date_key <> 0;

    IF v_last_date IS NULL THEN
        DBMS_OUTPUT.PUT_LINE('DATE_DIM is empty. '
            || 'Run initial_load_date_dim.sql first.');
        RETURN;
    END IF;

    IF v_target_end <= v_last_date THEN
        DBMS_OUTPUT.PUT_LINE('DATE_DIM already covers to '
            || TO_CHAR(v_last_date, 'YYYY-MM-DD')
            || '. Nothing to add for '
            || TO_CHAR(v_target_end, 'YYYY-MM-DD') || '.');
        RETURN;
    END IF;

    -- date_staging_v rolls ~11 years past today (its CONNECT BY is
    -- bound to SYSDATE, not a literal). Asking beyond its current max
    -- would quietly return no rows, so check the REAL max and say so
    -- instead of appearing to succeed.
    SELECT MAX(v_date) INTO v_view_max FROM date_staging_v;

    IF v_target_end > v_view_max THEN
        DBMS_OUTPUT.PUT_LINE('*** date_staging_v currently reaches only '
            || TO_CHAR(v_view_max, 'YYYY-MM-DD')
            || '. The horizon rolls forward with SYSDATE; for a target '
            || 'this far out, widen it in initial_load_date_dim.sql.');
        RETURN;
    END IF;

    -- Set-based, exactly like the initial load: one INSERT..SELECT
    -- with NEXTVAL in the outer select over the staging VIEW. (NEXTVAL
    -- cannot share a query block with the view's CONNECT BY or with an
    -- ORDER BY - so no ORDER BY here. CONNECT BY LEVEL generates the
    -- days in ascending order anyway, so the surrogate keys still
    -- follow the calendar.)
    INSERT INTO date_dim (
        date_key, cal_date, full_desc, day_week,
        day_num_month, last_day_ind, cal_week_end_date,
        cal_week_year, cal_month_name, cal_month_year, cal_year_month,
        cal_quarter, cal_year_quarter, cal_year,
        holiday_ind, holiday_name, weekday_ind
    )
    SELECT
        date_dim_seq.NEXTVAL,
        s.v_date, s.full_desc, s.day_week,
        s.day_num_month, s.last_day_ind, s.cal_week_end_date,
        s.cal_week_year, s.cal_month_name, s.cal_month_year,
        s.cal_year_month, s.cal_quarter, s.cal_year_quarter, s.cal_year,
        s.holiday_ind, s.holiday_name, s.weekday_ind
    FROM date_staging_v s
    WHERE s.v_date >  v_last_date
    AND   s.v_date <= v_target_end
    AND   NOT EXISTS (SELECT 1 FROM date_dim d
                      WHERE d.cal_date = s.v_date);

    v_count := SQL%ROWCOUNT;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('DATE_DIM incremental load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Previous last date  : '
        || TO_CHAR(v_last_date, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(' - New days inserted   : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Calendar now ends   : '
        || TO_CHAR(v_target_end, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(' - New years arrive with NO holidays. Run:');
    DBMS_OUTPUT.PUT_LINE('     python gen_holidays.py 2019 '
        || TO_CHAR(v_target_end, 'YYYY') || ' > holiday_update.sql');
    DBMS_OUTPUT.PUT_LINE('     @holiday_update.sql');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in DATE_DIM incremental load: '
            || SQLERRM);
        RAISE;
END;
/
