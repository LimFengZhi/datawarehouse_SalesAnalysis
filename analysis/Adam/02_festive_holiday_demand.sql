-- ===================================================================
-- 02_festive_holiday_demand.sql
-- SALES ANALYSIS - FESTIVE AND HOLIDAY DEMAND
--   calendar coverage -> year trend -> the daily shape -> branch -> category
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\user\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Adam\02_festive_holiday_demand.sql
--
-- PARAMETERS (prompted)
--   focus year   the year to zoom into              (default 2025)
--   festival     Chinese New Year / Hari Raya Aidilfitri /
--                Christmas Day                      (default CNY)
--                Short forms work: CNY, Raya, Christmas
--   branch       city name for the section 5 dice   (default Kuala Lumpur)
--
-- WHAT IT ANSWERS
--   1. Which festivals does the calendar actually flag, and for
--      which years?
--   2. How much bigger is an average RUN-UP day than a normal
--      trading day, and has that held up over eight years?
--   3. Day by day, what shape does demand take around a festival?
--   4. Is the pattern company-wide, or driven by a few branches?
--   5. Does festive demand shift the product MIX, or lift the whole
--      basket evenly?
--
-- THE CENTRAL POINT
--   Festive uplift lives in the DAYS BEFORE the festival, not on the
--   festival itself. Measuring "the festival week" as one block
--   averages the run-up together with the holiday and cancels the
--   effect out. This report always separates three day types:
--
--     RUN-UP        the N days before a festival (N below)
--     FESTIVAL DAY  the gazetted day(s) themselves
--     NORMAL        every other trading day
--
-- RUN-UP LENGTH PER FESTIVAL
--   The source data ramps each festival over its own window, so the
--   report uses the same windows rather than one flat number:
--       Hari Raya Aidilfitri  25 days   (the strongest, peak x1.85)
--       Chinese New Year      18 days   (peak x1.75)
--       Christmas Day         16 days   (peak x1.40)
--       Deepavali             14 days   (peak x1.45, if ever flagged)
--   Documented in sales_data2\README.md and encoded in the FESTIVALS
--   list of sales_data2\gen_sales_data2.py (one unified generator now
--   covers all eight years, replacing the old data\/data2\/data3\
--   three-generator split).
--
-- ===================================================================
-- HOW FESTIVALS ARE MATCHED - READ THIS BEFORE CHANGING IT
-- ===================================================================
--   date_dim.holiday_name is NOT a stable string. gen_holidays.py
--   maps the python `holidays` library's MALAY names to short English
--   labels, but newer versions of that library return ENGLISH names
--   which match none of the map's keys, so they fall through to the
--   library's own wording. This warehouse was loaded by such a
--   version. Hari Raya is therefore stored as:
--       'Eid al-Fitr'                        <- what is actually here
--       'Eid al-Fitr (Second Day)'
--       'Eid al-Fitr (observed)' / '(additional holiday)'
--   and NOT as any of the names the generator's NAME_MAP produces:
--       'Hari Raya Aidilfitri'   (mapped, Malay-name library)
--       'Hari Raya Puasa'        (raw, Malay-name library)
--
--   'Eid al-Adha' is Hari Raya HAJI - a different festival with no
--   retail ramp in this dataset - and is excluded explicitly.
--
--   Matching on equality would therefore silently drop the STRONGEST
--   festival in the data and quietly understate every figure in the
--   report. Section 1B exists to catch exactly that.
--
--   This report therefore matches on PATTERNS, not equality, and
--   normalises everything to three canonical labels. Section 1B
--   prints every holiday name actually present so you can see what
--   your date_dim really holds.
--
--   Hari Raya HAJI / QURBAN is explicitly excluded - it is a
--   different festival and carries no retail ramp in this dataset.
--
-- ===================================================================
-- A GAP TO KNOW ABOUT - DEEPAVALI
-- ===================================================================
--   Only three of Malaysia's four retail festivals can normally be
--   analysed here. DEEPAVALI IS USUALLY MISSING FROM date_dim:
--   gen_holidays.py calls holidays.Malaysia(years=...) with no
--   subdiv, which returns NATIONAL holidays only, and in that library
--   Deepavali (like New Year's Day and Thaipusam) is state-level.
--   The sales data DOES contain the Deepavali ramp (x1.45 over 14
--   days) - nothing flags those dates. Section 1 makes the gap
--   visible, and the matching below picks Deepavali up automatically
--   if it is ever added.
--   To add it, gen_holidays.py would need subdiv='KUL' and every year
--   regenerated - a change to shared ETL, not to this report.
--
-- FACT USED  (one)
--   order_fact   product sales, Completed lines only, ~670,000 rows
--   across 13 branches, 2018-2025. order_fact no longer stores a unit
--   price or a gross amount (removed - the price now lives only in
--   product_dim, version-in-force on the order date); this report
--   reconstructs revenue from order_total_amt and order_tax_amt
--   instead, see MEASURE DEFINITIONS below.
--   Services are deliberately out of scope - reservation seasonality
--   is a separate report.
--
-- DIMENSIONS USED  (three)
--   date_dim     holiday_ind, holiday_name, cal_date, day_week
--                  -> classifies every day and drives the drill path
--   branch_dim   br_city                    -> section 4 rows, sec 5 dice
--   product_dim  product_category           -> section 5 rows
--
-- MEASURE DEFINITIONS
--   Revenue   = gross - discount, EXCLUDING tax (SST is passed on to
--               the government). Only COMPLETED orders count.
--               order_fact stores no gross amount or unit price (the
--               price now lives only in product_dim); reconstructed
--               as order_total_amt - order_tax_amt, since the ETL
--               computes order_total_amt = qty*price - discount + tax,
--               so subtracting tax alone leaves gross - discount.
--   Avg/day   = revenue divided by the number of CALENDAR days of
--               that type, not the number of days that had a sale -
--               a dead day is data, not an absence of data.
--   Uplift %  = (avg run-up day / avg normal day - 1) * 100
--
--   Grouped on the branch NATURAL key (br_ID) and on product
--   CATEGORY, never the surrogate keys - both dimensions are SCD2,
--   so one branch or product can own several rows and must still
--   roll up as one line.
--
-- REPORT SECTIONS  (the drill path, OLAP operation per section)
--   1A FESTIVE CALENDAR COVERAGE            ROLL-UP (+ data check)
--   1B EVERY HOLIDAY NAME IN date_dim       diagnostic listing
--   2  RUN-UP vs FESTIVAL vs NORMAL, BY YEAR  ROLL-UP
--   3  FOCUS YEAR - DAILY SHAPE              SLICE + DRILL-DOWN to day
--   4  FOCUS YEAR - UPLIFT BY BRANCH         SLICE, rolled up by branch
--   5  CHOSEN BRANCH x CHOSEN FESTIVAL       DICE + category detail
--   6  SUMMARY STATISTICS                    ROLL-UP
--
-- WHAT TO LOOK FOR
--   - Section 1A: expect THREE festivals, EIGHT years each (2018-2025).
--     If Hari Raya is absent, the pattern matching failed - check 1B
--     for the actual stored name. If a YEAR is missing, gen_holidays.py
--     was never run for it; fix that before reading anything else
--   - Section 2: the RUN-UP uplift is the durable finding - positive
--     in all eight years (RM +30% to +61%). It is WIDEST in 2021, the
--     worst trading year (FMCO), because the normal-day baseline
--     collapsed while the festive rush still happened
--   - Section 2, festival day: NEGATIVE IN EVERY YEAR, 2018 through
--     2025 (RM -25% to -66%, no exceptions). All eight years now come
--     from ONE generator (sales_data2\gen_sales_data2.py) that applies
--     the same holiday-day dip (x0.45) throughout, so - unlike the old
--     three-generator dataset this report was first written against -
--     there is no era discontinuity to work around here. Shops are
--     genuinely quieter on the gazetted day itself; the run-up carries
--     the season
--   - Section 3: the classic shape - a steady climb through the
--     run-up, peaking 1-3 days out, then a drop on the festival day.
--     Consistent in every year now; 2021 (widest run-up) and 2025
--     (deepest festival-day drop) are the sections most worth running
--   - Section 4: every branch shows the uplift (RM +29% to +43% across
--     all 13 branches), so it is real demand, not one branch's
--     promotion. Ipoh, the newest branch (opened 2023-03-01), still
--     shows a normal uplift once it is trading
--   - Section 5: uplift is NOT broad-based - it ranges from RM +66%
--     (Serum) down to RM +6% (Spot Treatment), and MIX ON NORMAL vs
--     MIX IN RUN-UP moves several points for the categories at either
--     end (Serum +3pp, Moisturizer/Sunscreen/Spot Treatment each
--     losing 1-2pp). Festive demand shifts the basket toward serums,
--     eye care and masks rather than lifting every category evenly -
--     the opposite of this report's original finding, and it matches
--     the generator's own run-up category weighting
--     (gen_sales_data2.py: Serum / Eye Cream / Face Mask get an extra
--     x1.15 during a run-up). Check this section's actual output for
--     the year and festival you run, rather than assuming the ranking
--     above is fixed - it was only checked for CNY 2025
--   - Raya MOVES about 11 days earlier each year: 2018-06-15,
--     2019-06-05, 2020-05-24, 2021-05-13, 2022-05-02, 2023-04-22,
--     2024-04-10, 2025-03-31. Any month-on-month comparison across
--     years is meaningless unless it is anchored to the festival date,
--     which is exactly what section 3 does
-- ===================================================================

-- reset anything a previous script left behind in this session
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 132
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

-- SQL*Plus caps an ACCEPT prompt at 99 characters - a longer one
-- raises SP2-0003 and leaves the variable UNDEFINED, which then
-- makes SQL*Plus ask "Enter value for ..." mid-report. Keep these
-- short.
ACCEPT focus_year NUMBER DEFAULT 2025 PROMPT 'Focus year (default 2025): '
ACCEPT festival   CHAR   DEFAULT 'Chinese New Year' PROMPT 'Festival - CNY / Raya / Christmas (default CNY): '
ACCEPT branch     CHAR   DEFAULT 'Kuala Lumpur' PROMPT 'Branch city for section 5 (default Kuala Lumpur): '

-- ---- values reused in every title ---------------------------------
-- TERMOUT OFF hides these helper queries (only works when the file is
-- run with @, which is how this report is meant to be run). TO_CHAR
-- keeps the number from being captured with leading spaces.
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN focus_y NEW_VALUE focus_y NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;

-- Normalise whatever the user typed into one canonical label, so
-- 'cny', 'CNY', 'Chinese New Year' and 'chinese' all land on the
-- same festival. Printed in the section 3 and 5 titles.
COLUMN fest_label NEW_VALUE fest_label NOPRINT
SELECT CASE
           WHEN UPPER('&festival') LIKE '%CNY%'
             OR UPPER('&festival') LIKE '%CHINESE%'   THEN 'Chinese New Year'
           WHEN UPPER('&festival') LIKE '%RAYA%'
             OR UPPER('&festival') LIKE '%AIDIL%'
             OR UPPER('&festival') LIKE '%PUASA%'     THEN 'Hari Raya Aidilfitri'
           WHEN UPPER('&festival') LIKE '%CHRIS%'
             OR UPPER('&festival') LIKE '%KRIS%'
             OR UPPER('&festival') LIKE '%XMAS%'      THEN 'Christmas Day'
           WHEN UPPER('&festival') LIKE '%DEEPA%'     THEN 'Deepavali'
           ELSE 'Chinese New Year'
       END AS fest_label FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL festive_holiday_demand_output.txt


-- ###################################################################
-- SECTION 1A - FESTIVE CALENDAR COVERAGE
-- OLAP: ROLL-UP over date_dim. Also the data-quality guard: every
-- later section is meaningless if the holiday flags are not loaded.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1A. FESTIVE CALENDAR COVERAGE IN date_dim' SKIP 1 -
       CENTER 'WHICH FESTIVALS ARE FLAGGED, AND FOR WHICH YEARS' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN festival     HEADING 'FESTIVAL'            FORMAT A22
COLUMN runup_days   HEADING 'RUN-UP|WINDOW'       FORMAT 990
COLUMN yrs_flagged  HEADING 'YEARS|FLAGGED'       FORMAT 990
COLUMN days_flagged HEADING 'DAYS|FLAGGED'        FORMAT 990
COLUMN first_date   HEADING 'FIRST'               FORMAT A12
COLUMN last_date    HEADING 'LAST'                FORMAT A12
COLUMN drift_note   HEADING 'MOVES?'              FORMAT A14

WITH fest_map AS (
    -- pattern matching, not equality - see the header note on why
    -- holiday_name is not a stable string
    SELECT cal_date,
           CASE
               WHEN UPPER(holiday_name) LIKE '%CHINESE NEW YEAR%'
                 OR UPPER(holiday_name) LIKE '%TAHUN BAHARU CINA%'
                   THEN 'Chinese New Year'
               WHEN (   UPPER(holiday_name) LIKE '%EID AL-FITR%'
                     OR UPPER(holiday_name) LIKE '%AIDILFITRI%'
                     OR UPPER(holiday_name) LIKE '%RAYA PUASA%'
                     OR UPPER(holiday_name) LIKE '%HARI RAYA%')
                    AND UPPER(holiday_name) NOT LIKE '%HAJI%'
                    AND UPPER(holiday_name) NOT LIKE '%QURBAN%'
                    AND UPPER(holiday_name) NOT LIKE '%ADHA%'
                   THEN 'Hari Raya Aidilfitri'
               WHEN UPPER(holiday_name) LIKE '%CHRISTMAS%'
                 OR UPPER(holiday_name) LIKE '%KRISMAS%'
                   THEN 'Christmas Day'
               WHEN UPPER(holiday_name) LIKE '%DEEPAVALI%'
                 OR UPPER(holiday_name) LIKE '%DIWALI%'
                   THEN 'Deepavali'
           END AS festival
    FROM   date_dim
    WHERE  holiday_ind = 'Y'
)
SELECT festival,
       CASE festival
           WHEN 'Hari Raya Aidilfitri' THEN 25
           WHEN 'Chinese New Year'     THEN 18
           WHEN 'Christmas Day'        THEN 16
           ELSE 14
       END                                            AS runup_days,
       COUNT(DISTINCT TO_CHAR(cal_date, 'YYYY'))      AS yrs_flagged,
       COUNT(*)                                       AS days_flagged,
       TO_CHAR(MIN(cal_date), 'YYYY-MM-DD')           AS first_date,
       TO_CHAR(MAX(cal_date), 'YYYY-MM-DD')           AS last_date,
       -- a fixed-date festival always falls in the same month; a
       -- lunar one does not. This is what makes month-on-month
       -- comparison across years unsafe for Raya and CNY
       CASE WHEN COUNT(DISTINCT TO_CHAR(cal_date, 'MM')) > 1
            THEN 'YES - lunar'
            ELSE 'no - fixed' END                     AS drift_note
FROM   fest_map
WHERE  festival IS NOT NULL
GROUP  BY festival
ORDER  BY festival;

PROMPT
PROMPT   Expect THREE festivals, 8 years each. Deepavali normally will
PROMPT   NOT appear: gen_holidays.py loads national holidays only.
PROMPT   If Hari Raya is missing, check section 1B for its real name.
PROMPT


-- ###################################################################
-- SECTION 1B - EVERY HOLIDAY NAME PRESENT  (diagnostic)
-- Not an analysis section. This is what tells you whether the
-- pattern matching above found everything it should have.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1B. EVERY HOLIDAY NAME STORED IN date_dim' SKIP 1 -
       CENTER 'DIAGNOSTIC - CONFIRMS WHAT SECTION 1A MATCHED ON' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN holiday_name HEADING 'HOLIDAY NAME AS STORED' FORMAT A52
COLUMN days_flagged HEADING 'DAYS'                   FORMAT 990
COLUMN yrs_flagged  HEADING 'YEARS'                  FORMAT 990
COLUMN matched_as   HEADING 'MATCHED AS'             FORMAT A22
COLUMN sort_key     NOPRINT

SELECT holiday_name,
       COUNT(*)                                  AS days_flagged,
       COUNT(DISTINCT TO_CHAR(cal_date,'YYYY'))  AS yrs_flagged,
       NVL(CASE
               WHEN UPPER(holiday_name) LIKE '%CHINESE NEW YEAR%'
                 OR UPPER(holiday_name) LIKE '%TAHUN BAHARU CINA%'
                   THEN 'Chinese New Year'
               WHEN (   UPPER(holiday_name) LIKE '%EID AL-FITR%'
                     OR UPPER(holiday_name) LIKE '%AIDILFITRI%'
                     OR UPPER(holiday_name) LIKE '%RAYA PUASA%'
                     OR UPPER(holiday_name) LIKE '%HARI RAYA%')
                    AND UPPER(holiday_name) NOT LIKE '%HAJI%'
                    AND UPPER(holiday_name) NOT LIKE '%QURBAN%'
                    AND UPPER(holiday_name) NOT LIKE '%ADHA%'
                   THEN 'Hari Raya Aidilfitri'
               WHEN UPPER(holiday_name) LIKE '%CHRISTMAS%'
                 OR UPPER(holiday_name) LIKE '%KRISMAS%'
                   THEN 'Christmas Day'
               WHEN UPPER(holiday_name) LIKE '%DEEPAVALI%'
                 OR UPPER(holiday_name) LIKE '%DIWALI%'
                   THEN 'Deepavali'
           END, 'not a retail festival')       AS matched_as,
       -- matched festivals first, then the ones correctly ignored
       CASE WHEN UPPER(holiday_name) LIKE '%CHINESE NEW YEAR%'
              OR UPPER(holiday_name) LIKE '%TAHUN BAHARU CINA%'
              OR UPPER(holiday_name) LIKE '%EID AL-FITR%'
              OR UPPER(holiday_name) LIKE '%AIDILFITRI%'
              OR UPPER(holiday_name) LIKE '%RAYA PUASA%'
              OR UPPER(holiday_name) LIKE '%CHRISTMAS%'
              OR UPPER(holiday_name) LIKE '%KRISMAS%'
              OR UPPER(holiday_name) LIKE '%DEEPAVALI%'
              OR UPPER(holiday_name) LIKE '%DIWALI%'
            THEN 1 ELSE 2 END                   AS sort_key
FROM   date_dim
WHERE  holiday_ind = 'Y'
GROUP  BY holiday_name
ORDER  BY sort_key, matched_as, holiday_name;

PROMPT
PROMPT   Matched festivals are listed first. Everything below them is
PROMPT   correctly ignored - Labour Day, National Day, Vesak, and
PROMPT   Eid al-Adha, which is Hari Raya Haji, not Aidilfitri.
PROMPT


-- ###################################################################
-- SECTION 2 - RUN-UP vs FESTIVAL DAY vs NORMAL, BY YEAR
-- OLAP: ROLL-UP to year grain over all three day types
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. AVERAGE DAILY REVENUE BY DAY TYPE, 2018 - 2025' SKIP 1 -
       CENTER 'EACH FESTIVAL WITH ITS OWN RUN-UP WINDOW' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year    HEADING 'YEAR'                 FORMAT 9999
COLUMN runup_avg   HEADING 'RUN-UP|AVG/DAY (RM)'  FORMAT 999,990.00
COLUMN fest_avg    HEADING 'FESTIVAL DAY|AVG/DAY (RM)' FORMAT 999,990.00
COLUMN normal_avg  HEADING 'NORMAL|AVG/DAY (RM)'  FORMAT 999,990.00
COLUMN uplift_pct  HEADING 'RUN-UP|UPLIFT %'      FORMAT S9990.0
COLUMN festday_pct HEADING 'FESTIVAL DAY|VS NORMAL %' FORMAT S9990.0
COLUMN runup_share HEADING 'RUN-UP SHARE|OF YEAR %' FORMAT 990.0

WITH fest AS (
    SELECT cal_date AS f_date,
           CASE festival
               WHEN 'Hari Raya Aidilfitri' THEN 25
               WHEN 'Chinese New Year'     THEN 18
               WHEN 'Christmas Day'        THEN 16
               ELSE 14
           END AS runup_days
    FROM (
        SELECT cal_date,
               CASE
                   WHEN UPPER(holiday_name) LIKE '%CHINESE NEW YEAR%'
                     OR UPPER(holiday_name) LIKE '%TAHUN BAHARU CINA%'
                       THEN 'Chinese New Year'
                   WHEN (   UPPER(holiday_name) LIKE '%EID AL-FITR%'
                         OR UPPER(holiday_name) LIKE '%AIDILFITRI%'
                         OR UPPER(holiday_name) LIKE '%RAYA PUASA%'
                         OR UPPER(holiday_name) LIKE '%HARI RAYA%')
                        AND UPPER(holiday_name) NOT LIKE '%HAJI%'
                        AND UPPER(holiday_name) NOT LIKE '%QURBAN%'
                        AND UPPER(holiday_name) NOT LIKE '%ADHA%'
                       THEN 'Hari Raya Aidilfitri'
                   WHEN UPPER(holiday_name) LIKE '%CHRISTMAS%'
                     OR UPPER(holiday_name) LIKE '%KRISMAS%'
                       THEN 'Christmas Day'
                   WHEN UPPER(holiday_name) LIKE '%DEEPAVALI%'
                     OR UPPER(holiday_name) LIKE '%DIWALI%'
                       THEN 'Deepavali'
               END AS festival
        FROM   date_dim
        WHERE  holiday_ind = 'Y'
    )
    WHERE festival IS NOT NULL
),
day_type AS (
    -- classify EVERY calendar day. The festival test comes first, so
    -- the second day of CNY is a festival day, not the run-up of the
    -- first. date_key <> 0 excludes the Unknown member.
    SELECT d.date_key, d.cal_date, d.cal_year,
           CASE
               WHEN EXISTS (SELECT 1 FROM fest f
                            WHERE f.f_date = d.cal_date)
                   THEN 'FESTIVAL'
               WHEN EXISTS (SELECT 1 FROM fest f
                            WHERE d.cal_date BETWEEN f.f_date - f.runup_days
                                                 AND f.f_date - 1)
                   THEN 'RUNUP'
               ELSE 'NORMAL'
           END AS day_type
    FROM   date_dim d
    WHERE  d.date_key <> 0
),
sales AS (
    -- aggregate the fact ONCE, then attach it to the day scaffold
    SELECT f.date_key,
           -- order_fact no longer stores gross or unit price (the
           -- price now lives only in product_dim, version-in-force).
           -- order_total_amt = qty*price - discount + tax, so
           -- subtracting tax alone reconstructs gross - discount
           -- without a product_dim join.
           SUM(f.order_total_amt - f.order_tax_amt) AS rev
    FROM   order_fact f
    WHERE  f.order_status = 'Completed'
    GROUP  BY f.date_key
),
daily AS (
    -- LEFT JOIN, not INNER: a day with no completed sale is a real
    -- zero and must pull the average down, not vanish from it
    SELECT t.cal_year, t.day_type, t.cal_date, NVL(s.rev, 0) AS rev
    FROM   day_type t
    LEFT   JOIN sales s ON s.date_key = t.date_key
),
by_year AS (
    SELECT cal_year,
           AVG(CASE WHEN day_type = 'RUNUP'    THEN rev END) AS runup_avg,
           AVG(CASE WHEN day_type = 'FESTIVAL' THEN rev END) AS fest_avg,
           AVG(CASE WHEN day_type = 'NORMAL'   THEN rev END) AS normal_avg,
           SUM(CASE WHEN day_type = 'RUNUP'    THEN rev END) AS runup_total,
           SUM(rev)                                          AS year_total
    FROM   daily
    GROUP  BY cal_year
)
SELECT cal_year, runup_avg, fest_avg, normal_avg,
       ROUND(runup_avg / NULLIF(normal_avg, 0) * 100 - 100, 1) AS uplift_pct,
       ROUND(fest_avg  / NULLIF(normal_avg, 0) * 100 - 100, 1) AS festday_pct,
       ROUND(runup_total / NULLIF(year_total, 0) * 100, 1)     AS runup_share
FROM   by_year
ORDER  BY cal_year;

PROMPT
PROMPT   RUN-UP UPLIFT is positive in every year. That is the finding.
PROMPT   FESTIVAL DAY is negative in every year too, 2018 through 2025,
PROMPT   no exceptions. Shops are genuinely quieter on the gazetted day
PROMPT   itself; the run-up is where the season's revenue actually is.
PROMPT


-- ###################################################################
-- SECTION 3 - FOCUS YEAR: THE DAILY SHAPE AROUND ONE FESTIVAL
-- OLAP: SLICE (date_dim fixed to one festival window in one year)
--       + DRILL-DOWN to the finest grain in the report, the DAY
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. &fest_label IN &focus_y: DAY BY DAY' SKIP 1 -
       CENTER 'DAY 0 IS THE FESTIVAL. NEGATIVE DAYS ARE THE RUN-UP.' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN day_offset HEADING 'DAY'              FORMAT S990
COLUMN cal_date   HEADING 'DATE'             FORMAT A12
COLUMN day_week   HEADING 'DAY'              FORMAT A10
COLUMN rev        HEADING 'REVENUE (RM)'     FORMAT 999,990.00
COLUMN vs_normal  HEADING 'VS NORMAL|DAY %'  FORMAT S9990.0
COLUMN bar        HEADING 'SHAPE'            FORMAT A32

WITH fest_map AS (
    SELECT cal_date,
           CASE
               WHEN UPPER(holiday_name) LIKE '%CHINESE NEW YEAR%'
                 OR UPPER(holiday_name) LIKE '%TAHUN BAHARU CINA%'
                   THEN 'Chinese New Year'
               WHEN (   UPPER(holiday_name) LIKE '%EID AL-FITR%'
                     OR UPPER(holiday_name) LIKE '%AIDILFITRI%'
                     OR UPPER(holiday_name) LIKE '%RAYA PUASA%'
                     OR UPPER(holiday_name) LIKE '%HARI RAYA%')
                    AND UPPER(holiday_name) NOT LIKE '%HAJI%'
                    AND UPPER(holiday_name) NOT LIKE '%QURBAN%'
                    AND UPPER(holiday_name) NOT LIKE '%ADHA%'
                   THEN 'Hari Raya Aidilfitri'
               WHEN UPPER(holiday_name) LIKE '%CHRISTMAS%'
                 OR UPPER(holiday_name) LIKE '%KRISMAS%'
                   THEN 'Christmas Day'
               WHEN UPPER(holiday_name) LIKE '%DEEPAVALI%'
                 OR UPPER(holiday_name) LIKE '%DIWALI%'
                   THEN 'Deepavali'
           END AS festival
    FROM   date_dim
    WHERE  holiday_ind = 'Y'
),
fest AS (
    SELECT cal_date AS f_date,
           CASE festival
               WHEN 'Hari Raya Aidilfitri' THEN 25
               WHEN 'Chinese New Year'     THEN 18
               WHEN 'Christmas Day'        THEN 16
               ELSE 14
           END AS runup_days
    FROM   fest_map WHERE festival IS NOT NULL
),
day_type AS (
    SELECT d.date_key, d.cal_date, d.cal_year,
           CASE
               WHEN EXISTS (SELECT 1 FROM fest f
                            WHERE f.f_date = d.cal_date)
                   THEN 'FESTIVAL'
               WHEN EXISTS (SELECT 1 FROM fest f
                            WHERE d.cal_date BETWEEN f.f_date - f.runup_days
                                                 AND f.f_date - 1)
                   THEN 'RUNUP'
               ELSE 'NORMAL'
           END AS day_type
    FROM   date_dim d
    WHERE  d.date_key <> 0
),
sales AS (
    SELECT f.date_key,
           -- order_fact no longer stores gross or unit price (the
           -- price now lives only in product_dim, version-in-force).
           -- order_total_amt = qty*price - discount + tax, so
           -- subtracting tax alone reconstructs gross - discount
           -- without a product_dim join.
           SUM(f.order_total_amt - f.order_tax_amt) AS rev
    FROM   order_fact f
    WHERE  f.order_status = 'Completed'
    GROUP  BY f.date_key
),
daily AS (
    SELECT t.cal_year, t.day_type, t.cal_date, NVL(s.rev, 0) AS rev
    FROM   day_type t
    LEFT   JOIN sales s ON s.date_key = t.date_key
),
baseline AS (
    -- the normal-day average for the focus year: what a day is
    -- "worth" when no festival is pulling on it
    SELECT AVG(rev) AS normal_avg
    FROM   daily
    WHERE  cal_year = &focus_year
    AND    day_type = 'NORMAL'
),
anchor AS (
    -- the FIRST gazetted day of the chosen festival in the focus
    -- year. MIN because CNY and Raya are flagged for two days.
    SELECT MIN(cal_date) AS f_date,
           CASE '&fest_label'
               WHEN 'Hari Raya Aidilfitri' THEN 25
               WHEN 'Chinese New Year'     THEN 18
               WHEN 'Christmas Day'        THEN 16
               ELSE 14
           END AS runup_days
    FROM   fest_map
    WHERE  festival = '&fest_label'
    AND    TO_CHAR(cal_date, 'YYYY') = TO_CHAR(&focus_year)
)
SELECT dl.cal_date - a.f_date                                 AS day_offset,
       TO_CHAR(dl.cal_date, 'YYYY-MM-DD')                     AS cal_date,
       TRIM(TO_CHAR(dl.cal_date, 'Day'))                      AS day_week,
       dl.rev,
       ROUND(dl.rev / NULLIF(b.normal_avg, 0) * 100 - 100, 1) AS vs_normal,
       -- Bar scaled to the BUSIEST day in this window, which always
       -- draws the full 30 characters; every other day is drawn in
       -- proportion to it. Scaling against the normal-day average
       -- instead needs an arbitrary cap, and every day above that cap
       -- then draws an identical bar - which hides exactly the peak
       -- days this section exists to show.
       -- MAX() OVER () is evaluated AFTER the WHERE clause, so the
       -- maximum is the window's own, not the whole year's.
       RPAD('#', GREATEST(1,
            ROUND(dl.rev / NULLIF(MAX(dl.rev) OVER (), 0) * 30)), '#') AS bar
FROM   daily dl
CROSS  JOIN baseline b
CROSS  JOIN anchor   a
WHERE  dl.cal_date BETWEEN a.f_date - a.runup_days AND a.f_date + 3
ORDER  BY day_offset;

PROMPT
PROMPT   Read the SHAPE column top to bottom: a steady climb through
PROMPT   the run-up, then what happens on day 0. The longest bar is
PROMPT   the busiest day of this window; the rest are in proportion.
PROMPT   Watch the DAY column too - Saturdays and Sundays run high on
PROMPT   their own, so part of the sawtooth is the weekly cycle, not
PROMPT   the festival. The run-up climb and the day-0 drop described in
PROMPT   section 2 hold in every year - try 2021 (widest run-up) or
PROMPT   2025 (deepest day-0 drop) to see them most clearly.
PROMPT


-- ###################################################################
-- SECTION 4 - FOCUS YEAR: IS THE UPLIFT COMPANY-WIDE?
-- OLAP: SLICE (date_dim fixed to the focus year), rolled up by branch
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. FOCUS YEAR &focus_y: RUN-UP UPLIFT BY BRANCH' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city     HEADING 'BRANCH'              FORMAT A15
COLUMN runup_avg   HEADING 'RUN-UP|AVG/DAY (RM)' FORMAT 99,990.00
COLUMN normal_avg  HEADING 'NORMAL|AVG/DAY (RM)' FORMAT 99,990.00
COLUMN uplift_pct  HEADING 'RUN-UP|UPLIFT %'     FORMAT S9990.0
-- wide enough for the COMPUTE SUM row: the all-branch year total is
-- eight figures, and a narrow format prints ##### instead
COLUMN runup_total HEADING 'RUN-UP|REVENUE (RM)' FORMAT 99,999,990.00
COLUMN year_total  HEADING 'YEAR|REVENUE (RM)'   FORMAT 99,999,990.00
COLUMN runup_share HEADING 'RUN-UP SHARE|OF YEAR %' FORMAT 990.0
COLUMN br_ID       NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF runup_total year_total ON REPORT

WITH fest AS (
    SELECT cal_date AS f_date,
           CASE festival
               WHEN 'Hari Raya Aidilfitri' THEN 25
               WHEN 'Chinese New Year'     THEN 18
               WHEN 'Christmas Day'        THEN 16
               ELSE 14
           END AS runup_days
    FROM (
        SELECT cal_date,
               CASE
                   WHEN UPPER(holiday_name) LIKE '%CHINESE NEW YEAR%'
                     OR UPPER(holiday_name) LIKE '%TAHUN BAHARU CINA%'
                       THEN 'Chinese New Year'
                   WHEN (   UPPER(holiday_name) LIKE '%EID AL-FITR%'
                         OR UPPER(holiday_name) LIKE '%AIDILFITRI%'
                         OR UPPER(holiday_name) LIKE '%RAYA PUASA%'
                         OR UPPER(holiday_name) LIKE '%HARI RAYA%')
                        AND UPPER(holiday_name) NOT LIKE '%HAJI%'
                        AND UPPER(holiday_name) NOT LIKE '%QURBAN%'
                        AND UPPER(holiday_name) NOT LIKE '%ADHA%'
                       THEN 'Hari Raya Aidilfitri'
                   WHEN UPPER(holiday_name) LIKE '%CHRISTMAS%'
                     OR UPPER(holiday_name) LIKE '%KRISMAS%'
                       THEN 'Christmas Day'
                   WHEN UPPER(holiday_name) LIKE '%DEEPAVALI%'
                     OR UPPER(holiday_name) LIKE '%DIWALI%'
                       THEN 'Deepavali'
               END AS festival
        FROM   date_dim
        WHERE  holiday_ind = 'Y'
    )
    WHERE festival IS NOT NULL
),
day_type AS (
    SELECT d.date_key, d.cal_date,
           CASE
               WHEN EXISTS (SELECT 1 FROM fest f
                            WHERE f.f_date = d.cal_date)
                   THEN 'FESTIVAL'
               WHEN EXISTS (SELECT 1 FROM fest f
                            WHERE d.cal_date BETWEEN f.f_date - f.runup_days
                                                 AND f.f_date - 1)
                   THEN 'RUNUP'
               ELSE 'NORMAL'
           END AS day_type
    FROM   date_dim d
    WHERE  d.date_key <> 0
    AND    d.cal_year = &focus_year
),
branches AS (
    -- natural key only: branch_dim is SCD2, so one branch can own
    -- several surrogate rows and must still roll up as one line
    SELECT DISTINCT br_ID, br_city FROM branch_dim
),
sales AS (
    -- aggregate the fact ONCE per branch per day, joined through the
    -- dimension, then attach to the scaffold below
    SELECT b.br_ID, f.date_key,
           -- order_fact no longer stores gross or unit price (the
           -- price now lives only in product_dim, version-in-force).
           -- order_total_amt = qty*price - discount + tax, so
           -- subtracting tax alone reconstructs gross - discount
           -- without a product_dim join.
           SUM(f.order_total_amt - f.order_tax_amt) AS rev
    FROM   order_fact f
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY b.br_ID, f.date_key
),
branch_day AS (
    -- every branch gets a row for every day, including days it sold
    -- nothing - otherwise a quiet branch would have its average
    -- computed over fewer days and look stronger than it is
    SELECT br.br_ID, br.br_city, t.day_type, NVL(s.rev, 0) AS rev
    FROM   day_type t
    CROSS  JOIN branches br
    LEFT   JOIN sales s ON s.date_key = t.date_key
                       AND s.br_ID    = br.br_ID
)
SELECT br_city,
       AVG(CASE WHEN day_type = 'RUNUP'  THEN rev END)          AS runup_avg,
       AVG(CASE WHEN day_type = 'NORMAL' THEN rev END)          AS normal_avg,
       ROUND(AVG(CASE WHEN day_type = 'RUNUP'  THEN rev END)
           / NULLIF(AVG(CASE WHEN day_type = 'NORMAL' THEN rev END), 0)
             * 100 - 100, 1)                                    AS uplift_pct,
       SUM(CASE WHEN day_type = 'RUNUP' THEN rev ELSE 0 END)    AS runup_total,
       SUM(rev)                                                 AS year_total,
       ROUND(SUM(CASE WHEN day_type = 'RUNUP' THEN rev ELSE 0 END)
           / NULLIF(SUM(rev), 0) * 100, 1)                      AS runup_share,
       br_ID
FROM   branch_day
GROUP  BY br_ID, br_city
HAVING SUM(rev) > 0            -- a branch not yet open in this year
ORDER  BY uplift_pct DESC;


-- ###################################################################
-- SECTION 5 - DICE: CHOSEN BRANCH x CHOSEN FESTIVAL, BY CATEGORY
-- OLAP: DICE - a selection on TWO dimensions at once
--         branch_dim  restricted to &branch
--         date_dim    restricted to &fest_label's run-up in &focus_y
--       then rolled up by product_dim category.
--       This is the only section that touches product_dim: it asks
--       whether festive demand shifts the MIX or lifts everything.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. &branch, &fest_label &focus_y: UPLIFT BY CATEGORY' SKIP 1 -
       CENTER 'DOES FESTIVE DEMAND SHIFT THE MIX, OR LIFT THE WHOLE BASKET?' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN product_category HEADING 'CATEGORY'            FORMAT A20
COLUMN runup_avg        HEADING 'RUN-UP|AVG/DAY (RM)' FORMAT 99,990.00
COLUMN normal_avg       HEADING 'NORMAL|AVG/DAY (RM)' FORMAT 99,990.00
COLUMN uplift_pct       HEADING 'RUN-UP|UPLIFT %'     FORMAT S9990.0
COLUMN runup_total      HEADING 'RUN-UP|REVENUE (RM)' FORMAT 999,990.00
COLUMN mix_normal       HEADING 'MIX ON|NORMAL %'     FORMAT 990.0
COLUMN mix_runup        HEADING 'MIX IN|RUN-UP %'     FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF runup_total ON REPORT

WITH fest_map AS (
    SELECT cal_date,
           CASE
               WHEN UPPER(holiday_name) LIKE '%CHINESE NEW YEAR%'
                 OR UPPER(holiday_name) LIKE '%TAHUN BAHARU CINA%'
                   THEN 'Chinese New Year'
               WHEN (   UPPER(holiday_name) LIKE '%EID AL-FITR%'
                     OR UPPER(holiday_name) LIKE '%AIDILFITRI%'
                     OR UPPER(holiday_name) LIKE '%RAYA PUASA%'
                     OR UPPER(holiday_name) LIKE '%HARI RAYA%')
                    AND UPPER(holiday_name) NOT LIKE '%HAJI%'
                    AND UPPER(holiday_name) NOT LIKE '%QURBAN%'
                    AND UPPER(holiday_name) NOT LIKE '%ADHA%'
                   THEN 'Hari Raya Aidilfitri'
               WHEN UPPER(holiday_name) LIKE '%CHRISTMAS%'
                 OR UPPER(holiday_name) LIKE '%KRISMAS%'
                   THEN 'Christmas Day'
               WHEN UPPER(holiday_name) LIKE '%DEEPAVALI%'
                 OR UPPER(holiday_name) LIKE '%DIWALI%'
                   THEN 'Deepavali'
           END AS festival
    FROM   date_dim
    WHERE  holiday_ind = 'Y'
),
anchor AS (
    -- the chosen festival's run-up window in the focus year only
    SELECT MIN(cal_date) AS f_date,
           CASE '&fest_label'
               WHEN 'Hari Raya Aidilfitri' THEN 25
               WHEN 'Chinese New Year'     THEN 18
               WHEN 'Christmas Day'        THEN 16
               ELSE 14
           END AS runup_days
    FROM   fest_map
    WHERE  festival = '&fest_label'
    AND    TO_CHAR(cal_date, 'YYYY') = TO_CHAR(&focus_year)
),
fest AS (
    SELECT cal_date AS f_date,
           CASE festival
               WHEN 'Hari Raya Aidilfitri' THEN 25
               WHEN 'Chinese New Year'     THEN 18
               WHEN 'Christmas Day'        THEN 16
               ELSE 14
           END AS runup_days
    FROM   fest_map WHERE festival IS NOT NULL
),
day_type AS (
    -- two labels only here: days inside the CHOSEN festival's run-up,
    -- and normal days of the same year (the comparison baseline).
    -- Days belonging to any OTHER festival are excluded entirely, so
    -- Christmas cannot contaminate the CNY baseline.
    SELECT d.date_key, d.cal_date,
           CASE WHEN d.cal_date BETWEEN a.f_date - a.runup_days
                                    AND a.f_date - 1
                THEN 'RUNUP' ELSE 'NORMAL' END AS day_type
    FROM   date_dim d
    CROSS  JOIN anchor a
    WHERE  d.date_key <> 0
    AND    d.cal_year = &focus_year
    AND   (   d.cal_date BETWEEN a.f_date - a.runup_days AND a.f_date - 1
           OR NOT EXISTS (SELECT 1 FROM fest f
                          WHERE d.cal_date BETWEEN f.f_date - f.runup_days
                                               AND f.f_date))
),
cats AS (
    SELECT DISTINCT product_category FROM product_dim
),
sales AS (
    -- aggregate ONCE per category per day for the chosen branch
    SELECT p.product_category, f.date_key,
           -- order_fact no longer stores gross or unit price (the
           -- price now lives only in product_dim, version-in-force).
           -- order_total_amt = qty*price - discount + tax, so
           -- subtracting tax alone reconstructs gross - discount
           -- without a product_dim join.
           SUM(f.order_total_amt - f.order_tax_amt) AS rev
    FROM   order_fact  f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    UPPER(b.br_city) = UPPER('&branch')
    GROUP  BY p.product_category, f.date_key
),
cat_day AS (
    -- scaffold again: a category that sold nothing on a given day
    -- counts as a zero, not as a missing row
    SELECT c.product_category, t.day_type, NVL(s.rev, 0) AS rev
    FROM   day_type t
    CROSS  JOIN cats c
    LEFT   JOIN sales s ON s.date_key         = t.date_key
                       AND s.product_category = c.product_category
),
by_cat AS (
    SELECT product_category,
           AVG(CASE WHEN day_type = 'RUNUP'  THEN rev END) AS runup_avg,
           AVG(CASE WHEN day_type = 'NORMAL' THEN rev END) AS normal_avg,
           SUM(CASE WHEN day_type = 'RUNUP'  THEN rev ELSE 0 END) AS runup_total,
           SUM(CASE WHEN day_type = 'NORMAL' THEN rev ELSE 0 END) AS normal_total
    FROM   cat_day
    GROUP  BY product_category
)
SELECT product_category, runup_avg, normal_avg,
       ROUND(runup_avg / NULLIF(normal_avg, 0) * 100 - 100, 1)  AS uplift_pct,
       runup_total,
       -- mix: if festive demand shifted the basket, these two
       -- percentages would differ. They do not.
       ROUND(RATIO_TO_REPORT(normal_total) OVER () * 100, 1)    AS mix_normal,
       ROUND(RATIO_TO_REPORT(runup_total)  OVER () * 100, 1)    AS mix_runup
FROM   by_cat
ORDER  BY uplift_pct DESC;

PROMPT
PROMPT   Compare the last two columns. A category whose MIX IN RUN-UP
PROMPT   sits above its MIX ON NORMAL is taking a bigger slice of the
PROMPT   basket during the run-up, not just riding the overall lift.
PROMPT   Serum typically shows the widest gap here.
PROMPT


-- ###################################################################
-- SECTION 6 - SUMMARY STATISTICS
-- OLAP: ROLL-UP to a single company-wide row per metric
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 6. FESTIVE DEMAND SUMMARY STATISTICS' SKIP 1 -
       CENTER 'ALL BRANCHES 2018 - 2025, FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC'  FORMAT A38
COLUMN metric_value HEADING 'VALUE'   FORMAT A34

WITH fest_map AS (
    SELECT cal_date,
           CASE
               WHEN UPPER(holiday_name) LIKE '%CHINESE NEW YEAR%'
                 OR UPPER(holiday_name) LIKE '%TAHUN BAHARU CINA%'
                   THEN 'Chinese New Year'
               WHEN (   UPPER(holiday_name) LIKE '%EID AL-FITR%'
                     OR UPPER(holiday_name) LIKE '%AIDILFITRI%'
                     OR UPPER(holiday_name) LIKE '%RAYA PUASA%'
                     OR UPPER(holiday_name) LIKE '%HARI RAYA%')
                    AND UPPER(holiday_name) NOT LIKE '%HAJI%'
                    AND UPPER(holiday_name) NOT LIKE '%QURBAN%'
                    AND UPPER(holiday_name) NOT LIKE '%ADHA%'
                   THEN 'Hari Raya Aidilfitri'
               WHEN UPPER(holiday_name) LIKE '%CHRISTMAS%'
                 OR UPPER(holiday_name) LIKE '%KRISMAS%'
                   THEN 'Christmas Day'
               WHEN UPPER(holiday_name) LIKE '%DEEPAVALI%'
                 OR UPPER(holiday_name) LIKE '%DIWALI%'
                   THEN 'Deepavali'
           END AS festival
    FROM   date_dim
    WHERE  holiday_ind = 'Y'
),
fest AS (
    SELECT cal_date AS f_date,
           CASE festival
               WHEN 'Hari Raya Aidilfitri' THEN 25
               WHEN 'Chinese New Year'     THEN 18
               WHEN 'Christmas Day'        THEN 16
               ELSE 14
           END AS runup_days
    FROM   fest_map WHERE festival IS NOT NULL
),
day_type AS (
    SELECT d.date_key, d.cal_date, d.cal_year,
           CASE
               WHEN EXISTS (SELECT 1 FROM fest f
                            WHERE f.f_date = d.cal_date)
                   THEN 'FESTIVAL'
               WHEN EXISTS (SELECT 1 FROM fest f
                            WHERE d.cal_date BETWEEN f.f_date - f.runup_days
                                                 AND f.f_date - 1)
                   THEN 'RUNUP'
               ELSE 'NORMAL'
           END AS day_type
    FROM   date_dim d
    WHERE  d.date_key <> 0
),
sales AS (
    SELECT f.date_key,
           -- order_fact no longer stores gross or unit price (the
           -- price now lives only in product_dim, version-in-force).
           -- order_total_amt = qty*price - discount + tax, so
           -- subtracting tax alone reconstructs gross - discount
           -- without a product_dim join.
           SUM(f.order_total_amt - f.order_tax_amt) AS rev
    FROM   order_fact f
    WHERE  f.order_status = 'Completed'
    GROUP  BY f.date_key
),
daily AS (
    SELECT t.cal_year, t.day_type, t.cal_date, NVL(s.rev, 0) AS rev
    FROM   day_type t
    LEFT   JOIN sales s ON s.date_key = t.date_key
),
by_year AS (
    SELECT cal_year,
           AVG(CASE WHEN day_type = 'RUNUP'  THEN rev END) AS runup_avg,
           AVG(CASE WHEN day_type = 'NORMAL' THEN rev END) AS normal_avg
    FROM   daily
    GROUP  BY cal_year
),
-- one-row helper blocks; CROSS JOINed below instead of used as
-- scalar subqueries, which Oracle 11g rejects inside an aggregate
-- SELECT list (ORA-00937)
overall AS (
    SELECT AVG(CASE WHEN day_type = 'RUNUP'    THEN rev END) AS runup_avg,
           AVG(CASE WHEN day_type = 'FESTIVAL' THEN rev END) AS fest_avg,
           AVG(CASE WHEN day_type = 'NORMAL'   THEN rev END) AS normal_avg,
           SUM(CASE WHEN day_type = 'RUNUP' THEN rev ELSE 0 END) AS runup_total,
           SUM(rev)                                              AS all_total,
           COUNT(CASE WHEN day_type = 'RUNUP'    THEN 1 END)     AS runup_days,
           COUNT(CASE WHEN day_type = 'FESTIVAL' THEN 1 END)     AS fest_days,
           COUNT(*)                                              AS all_days
    FROM   daily
),
best AS (
    SELECT MAX(cal_year) KEEP (DENSE_RANK FIRST
               ORDER BY runup_avg / NULLIF(normal_avg, 0) DESC) AS best_year,
           MAX(ROUND(runup_avg / NULLIF(normal_avg, 0) * 100 - 100, 1)) AS best_uplift,
           MIN(cal_year) KEEP (DENSE_RANK LAST
               ORDER BY runup_avg / NULLIF(normal_avg, 0) DESC) AS worst_year,
           MIN(ROUND(runup_avg / NULLIF(normal_avg, 0) * 100 - 100, 1)) AS worst_uplift
    FROM   by_year
),
focus AS (
    SELECT runup_avg AS f_runup, normal_avg AS f_normal,
           ROUND(runup_avg / NULLIF(normal_avg, 0) * 100 - 100, 1) AS f_uplift
    FROM   by_year WHERE cal_year = &focus_year
),
cal AS (
    SELECT COUNT(DISTINCT festival) AS fests, COUNT(*) AS fest_day_rows
    FROM   fest_map WHERE festival IS NOT NULL
),
stats AS (
    SELECT o.*, b.*, f.*, c.*
    FROM   overall o CROSS JOIN best b CROSS JOIN focus f CROSS JOIN cal c
)
SELECT 'Festivals matched in date_dim'          AS metric_name,
       TO_CHAR(fests)                                                AS metric_value FROM stats
UNION ALL SELECT 'Gazetted festival days flagged',
       TO_CHAR(fest_day_rows)                                        FROM stats
UNION ALL SELECT 'Run-up days 2018-2025',
       TO_CHAR(runup_days) || ' of ' || TO_CHAR(all_days) || ' days' FROM stats
UNION ALL SELECT 'Avg revenue, NORMAL day (RM)',
       TRIM(TO_CHAR(normal_avg, '999,990.00'))                       FROM stats
UNION ALL SELECT 'Avg revenue, RUN-UP day (RM)',
       TRIM(TO_CHAR(runup_avg,  '999,990.00'))                       FROM stats
UNION ALL SELECT 'Avg revenue, FESTIVAL day (RM)',
       TRIM(TO_CHAR(fest_avg,   '999,990.00'))                       FROM stats
UNION ALL SELECT 'Overall run-up uplift',
       TRIM(TO_CHAR(runup_avg / NULLIF(normal_avg, 0) * 100 - 100, 'S9990.0')) || '%' FROM stats
UNION ALL SELECT 'Run-up share of all revenue',
       TRIM(TO_CHAR(runup_total / NULLIF(all_total, 0) * 100, '990.0')) || '%' FROM stats
UNION ALL SELECT 'Strongest uplift year',
       TO_CHAR(best_year)  || '  (' || TRIM(TO_CHAR(best_uplift,  'S9990.0')) || '%)' FROM stats
UNION ALL SELECT 'Weakest uplift year',
       TO_CHAR(worst_year) || '  (' || TRIM(TO_CHAR(worst_uplift, 'S9990.0')) || '%)' FROM stats
UNION ALL SELECT 'Focus year &focus_y normal day (RM)',
       TRIM(TO_CHAR(f_normal, '999,990.00'))                         FROM stats
UNION ALL SELECT 'Focus year &focus_y run-up day (RM)',
       TRIM(TO_CHAR(f_runup,  '999,990.00'))                         FROM stats
UNION ALL SELECT 'Focus year &focus_y uplift',
       TRIM(TO_CHAR(f_uplift, 'S9990.0')) || '%'                     FROM stats;

PROMPT
PROMPT +==========================================================+
PROMPT |          END OF FESTIVE AND HOLIDAY DEMAND REPORT        |
PROMPT +==========================================================+
PROMPT

-- ===================================================================
-- tidy up so the next script starts clean
-- ===================================================================
SPOOL OFF
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE focus_year
UNDEFINE festival
UNDEFINE fest_label
UNDEFINE branch
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
