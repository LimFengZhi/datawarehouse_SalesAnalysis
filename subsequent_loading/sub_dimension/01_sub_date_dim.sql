-- ===================================================================
-- 01_sub_date_dim.sql        DATE_DIM - SUBSEQUENT (INCREMENTAL) LOAD
--
-- Extends the calendar to the end of a year you name:
--     EXEC load_date_dim_incremental(2026);
--
--   SECTION 1: no new view - reuses date_staging_v
--   SECTION 2: no new sequence - reuses date_dim_seq
--   SECTION 3: PROCEDURE - incremental load
--   SECTION 4: run + holidays + verification
--
-- Safe to re-run: a NOT EXISTS on cal_date means days already loaded
-- are never inserted twice.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - reuses date_staging_v from
--   initial_loading\init_data_dim\initial_load_date_dim.sql
-- Its row generator runs to 2035-12-31; the initial load bounds itself
-- to 2022-12-31. This procedure moves that bound outward.
--
-- SECTION 2: SEQUENCE - reuses date_dim_seq. It carries on from where
-- the initial load stopped; recreating it would restart at 1 and
-- collide with existing primary keys.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_date_dim_incremental(
    p_until_year IN NUMBER
) AS
    v_last_date  DATE;
    v_target_end DATE;
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

    v_target_end := TO_DATE(TO_CHAR(p_until_year) || '-12-31',
                            'YYYY-MM-DD');

    -- date_staging_v stops at 2035. Asking beyond that would quietly
    -- return no rows, so say so instead of appearing to succeed.
    IF p_until_year > 2035 THEN
        DBMS_OUTPUT.PUT_LINE('*** date_staging_v only reaches 2035. '
            || 'Widen its CONNECT BY in initial_load_date_dim.sql '
            || 'to go further.');
        RETURN;
    END IF;

    IF v_target_end <= v_last_date THEN
        DBMS_OUTPUT.PUT_LINE('DATE_DIM already covers to '
            || TO_CHAR(v_last_date, 'YYYY-MM-DD')
            || '. Nothing to add for ' || p_until_year || '.');
        RETURN;
    END IF;

    -- Cursor FOR loop, NOT one INSERT..SELECT. date_staging_v contains
    -- CONNECT BY, and Oracle refuses a sequence NEXTVAL in the same
    -- query block as CONNECT BY (ORA-02287, which surfaces as
    -- PLS-00905 when you EXEC an invalid procedure). Putting NEXTVAL
    -- in a VALUES clause sidesteps it completely.
    -- ORDER BY keeps surrogate keys ascending with the calendar.
    FOR r IN (SELECT * FROM date_staging_v s
              WHERE  s.v_date >  v_last_date
                AND  s.v_date <= v_target_end
                AND  NOT EXISTS (SELECT 1 FROM date_dim d
                                 WHERE d.cal_date = s.v_date)
              ORDER BY s.v_date)
    LOOP
        INSERT INTO date_dim (
            date_key, cal_date, full_desc, day_week, day_num_week,
            day_num_month, day_num_year, last_day_ind, cal_week_end_date,
            cal_week_year, cal_month_name, cal_month_year, cal_year_month,
            cal_quarter, cal_year_quarter, cal_year,
            holiday_ind, holiday_name, weekday_ind
        ) VALUES (
            date_dim_seq.NEXTVAL,
            r.v_date, r.full_desc, r.day_week, r.day_num_week,
            r.day_num_month, r.day_num_year, r.last_day_ind,
            r.cal_week_end_date, r.cal_week_year, r.cal_month_name,
            r.cal_month_year, r.cal_year_month, r.cal_quarter,
            r.cal_year_quarter, r.cal_year,
            r.holiday_ind, r.holiday_name, r.weekday_ind
        );
        v_count := v_count + 1;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('DATE_DIM incremental load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Previous last date  : '
        || TO_CHAR(v_last_date, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(' - New days inserted   : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Calendar now ends   : '
        || TO_CHAR(v_target_end, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(' - New years arrive with NO holidays. Run:');
    DBMS_OUTPUT.PUT_LINE('     python gen_holidays.py 2019 '
        || p_until_year || ' > holiday_update.sql');
    DBMS_OUTPUT.PUT_LINE('     @holiday_update.sql');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in DATE_DIM incremental load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION - moved out
-- The EXECs live in execute_sub_procedure.sql (data2, 2023-2024) and
-- execute_sub2.sql (data3, 2025).
-- Verification queries live in ..\validate_subsequent_loading.sql
--
-- HOLIDAYS: new days land with holiday_ind = 'N'. After extending the
-- calendar, regenerate and run the holiday file:
--     cd initial_loading\init_data_dim
--     python gen_holidays.py 2019 <last year> > holiday_update.sql
--     @holiday_update.sql
-- The generated file resets ONLY the years it covers.
-- ===================================================================
