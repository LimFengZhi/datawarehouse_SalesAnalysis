-- ===================================================================
-- initial_load_date_dim.sql
-- ===================================================================
SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- Generates every calendar day 2019-01-01 .. 2023-12-31 (1,826 days)
-- holiday_ind starts as 'N' for every row; Section 5 flips the
-- holidays to 'Y'.
-- ===================================================================
CREATE OR REPLACE VIEW date_staging_v AS
SELECT
    v_date,
    TO_CHAR(v_date, 'DD-MON-YYYY')                          AS full_desc,
    TRIM(TO_CHAR(v_date, 'Day', 'NLS_DATE_LANGUAGE=ENGLISH')) AS day_week,
    TO_NUMBER(TO_CHAR(v_date, 'DD'))                        AS day_num_month,
    CASE WHEN v_date = LAST_DAY(v_date) THEN 'Y' ELSE 'N' END AS last_day_ind,
    NEXT_DAY(v_date - 1, 'SUNDAY')                          AS cal_week_end_date,
    -- IYYY (ISO year), not YYYY: IW is the ISO week number, and the days
    -- around New Year belong to the ISO year that owns the week -
    -- 2019-12-30 is 2020-W01, not "2019-W01" (which does not exist).
    TO_CHAR(v_date, 'IYYY') || '-W' || TO_CHAR(v_date, 'IW') AS cal_week_year,
    TRIM(TO_CHAR(v_date, 'Month', 'NLS_DATE_LANGUAGE=ENGLISH')) AS cal_month_name,
    TO_CHAR(v_date, 'Mon-YYYY', 'NLS_DATE_LANGUAGE=ENGLISH') AS cal_month_year,
    TO_NUMBER(TO_CHAR(v_date, 'YYYYMM'))                    AS cal_year_month,
    TO_NUMBER(TO_CHAR(v_date, 'Q'))                         AS cal_quarter,
    TO_CHAR(v_date, 'YYYY') || '-Q' || TO_CHAR(v_date, 'Q') AS cal_year_quarter,
    TO_NUMBER(TO_CHAR(v_date, 'YYYY'))                      AS cal_year,
    'N'                                                     AS holiday_ind,
    CAST(NULL AS VARCHAR2(80))                              AS holiday_name,
    CASE WHEN TO_CHAR(v_date, 'DY', 'NLS_DATE_LANGUAGE=ENGLISH')
              IN ('SAT','SUN')
         THEN 'N' ELSE 'Y' END                              AS weekday_ind
FROM (
    -- ROLLING horizon: always reaches 31 Dec ~11 full years past today
    -- (ADD_MONTHS(TRUNC(SYSDATE,'YYYY'), 144) - 1), so the SUBSEQUENT
    -- load can extend the calendar from this same view and nobody ever
    -- has to widen it again. The INITIAL load below bounds itself to
    -- 2023-12-31, so it still inserts exactly 1,826 days.
    SELECT TO_DATE('2019-01-01','YYYY-MM-DD') + LEVEL - 1 AS v_date
    FROM dual
    CONNECT BY LEVEL <= ADD_MONTHS(TRUNC(SYSDATE, 'YYYY'), 12 * 12) - 1
                      - TO_DATE('2019-01-01','YYYY-MM-DD') + 1
)
WHERE v_date IS NOT NULL;

-- ===================================================================
-- SECTION 2: CREATE SEQUENCE  (surrogate key: 1, 2, 3, ...)
-- ===================================================================
CREATE SEQUENCE date_dim_seq
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

-- ===================================================================
-- SECTION 3: ETL PROCEDURE (INITIAL LOAD - CALENDAR DAYS ONLY)
-- Holidays are applied afterwards by holiday_update.sql.
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_date_dim_initial AS
    v_inserted_count NUMBER := 0;
BEGIN
    -- Guard: do not double-load
    SELECT COUNT(*) INTO v_inserted_count FROM date_dim;

    IF v_inserted_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('DATE_DIM already contains data. '
            || 'Truncate it first if you intend to reload.');
        RETURN;
    END IF;

    INSERT INTO date_dim (
        date_key, cal_date, full_desc, day_week,
        day_num_month, last_day_ind, cal_week_end_date,
        cal_week_year, cal_month_name, cal_month_year, cal_year_month,
        cal_quarter, cal_year_quarter, cal_year,
        holiday_ind, holiday_name, weekday_ind
    )
    SELECT
        date_dim_seq.NEXTVAL,                     -- surrogate key: 1, 2, 3, ...
        v_date, full_desc, day_week,
        day_num_month, last_day_ind, cal_week_end_date,
        cal_week_year, cal_month_name, cal_month_year, cal_year_month,
        cal_quarter, cal_year_quarter, cal_year,
        holiday_ind, holiday_name, weekday_ind
    FROM date_staging_v
    -- The view rolls ~11 years past today. Bound the INITIAL load to
    -- the source data window (sales_data5\data19_23 = 2019-2023) so it
    -- still inserts exactly 1,826 days. Extending past this is the
    -- subsequent load's job:
    --   EXEC load_date_dim_incremental(2024);   -- data24
    --   EXEC load_date_dim_incremental(2025);   -- data25
    WHERE v_date <= DATE '2023-12-31';

    v_inserted_count := SQL%ROWCOUNT;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('DATE_DIM initial load completed: '
        || v_inserted_count || ' records inserted.');
    DBMS_OUTPUT.PUT_LINE('Holidays not set yet - run holiday_update.sql next.');

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in DATE_DIM initial load: ' || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + UNKNOWN MEMBER
-- ===================================================================
EXEC load_date_dim_initial;

-- Unknown member (date_key 0) for facts with a missing/invalid date.
-- Wrapped so re-running the script doesn't fail with ORA-00001.
BEGIN
    INSERT INTO date_dim (date_key, cal_date, full_desc, day_week,
                          cal_year, holiday_ind, weekday_ind)
    VALUES (0, DATE '1900-01-01', 'Unknown Date', 'Unknown', 1900, 'N', 'N');
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Unknown member inserted.');
EXCEPTION
    WHEN DUP_VAL_ON_INDEX THEN
        DBMS_OUTPUT.PUT_LINE('Unknown member already present - skipped.');
END;
/
