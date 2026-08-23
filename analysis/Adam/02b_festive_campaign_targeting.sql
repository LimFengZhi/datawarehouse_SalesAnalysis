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

SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL festive_campaign_targeting_output.txt


TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. FESTIVE DEMAND TREND, 2019 - 2025' SKIP 1 -
       CENTER 'STEP 1: IS THIS FESTIVE SEASON WORTH A CAMPAIGN AT ALL?' SKIP 1 -
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
           SUM(f.order_total_amt) AS rev
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


TTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
PROMPT
ACCEPT focus_year NUMBER DEFAULT 2024 PROMPT 'Focus year (default 2024): '
ACCEPT festival   CHAR   DEFAULT 'Chinese New Year' PROMPT 'Festival - CNY / Raya / Christmas (default CNY): '
PROMPT

SET TERMOUT OFF
COLUMN focus_y NEW_VALUE focus_y NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;

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

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. &fest_label IN &focus_y: DAY BY DAY' SKIP 1 -
       CENTER 'STEP 2: WHEN SHOULD THE CAMPAIGN BE LIVE?' SKIP 1 -
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
           SUM(f.order_total_amt) AS rev
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
    SELECT AVG(rev) AS normal_avg
    FROM   daily
    WHERE  cal_year = &focus_year
    AND    day_type = 'NORMAL'
),
anchor AS (
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
       RPAD('#', GREATEST(1,
            ROUND(dl.rev / NULLIF(MAX(dl.rev) OVER (), 0) * 30)), '#') AS bar
FROM   daily dl
CROSS  JOIN baseline b
CROSS  JOIN anchor   a
WHERE  dl.cal_date BETWEEN a.f_date - a.runup_days AND a.f_date + 3
ORDER  BY day_offset;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
PROMPT
ACCEPT area CHAR DEFAULT 'ALL' PROMPT 'State/area for section 3, or ALL (default ALL): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. FOCUS YEAR &focus_y, &area: WHICH BRANCH TO TARGET' SKIP 1 -
       CENTER 'STEP 3: RANKED BY RUN-UP UPLIFT WITHIN THE CHOSEN AREA' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN priority    HEADING 'CAMPAIGN|PRIORITY'    FORMAT A17
COLUMN br_city     HEADING 'BRANCH'              FORMAT A15
COLUMN runup_avg   HEADING 'RUN-UP|AVG/DAY (RM)' FORMAT 99,990.00
COLUMN normal_avg  HEADING 'NORMAL|AVG/DAY (RM)' FORMAT 99,990.00
COLUMN uplift_pct  HEADING 'RUN-UP|UPLIFT %'     FORMAT S9990.0
COLUMN runup_total HEADING 'RUN-UP|REVENUE (RM)' FORMAT 99,999,990.00
COLUMN year_total  HEADING 'YEAR|REVENUE (RM)'   FORMAT 99,999,990.00
COLUMN runup_share HEADING 'RUN-UP SHARE|OF YEAR %' FORMAT 990.0
COLUMN br_ID       NOPRINT

BREAK ON priority SKIP 1 ON REPORT
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
    SELECT DISTINCT br_ID, br_city
    FROM   branch_dim
    WHERE  UPPER('&area') = 'ALL'
       OR  UPPER(br_state) LIKE '%' || UPPER('&area') || '%'
),
sales AS (
    SELECT b.br_ID, f.date_key,
           SUM(f.order_total_amt) AS rev
    FROM   order_fact f
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY b.br_ID, f.date_key
),
branch_day AS (
    SELECT br.br_ID, br.br_city, t.day_type, NVL(s.rev, 0) AS rev
    FROM   day_type t
    CROSS  JOIN branches br
    LEFT   JOIN sales s ON s.date_key = t.date_key
                       AND s.br_ID    = br.br_ID
),
ranked AS (
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
    HAVING SUM(rev) > 0
)
SELECT CASE
           WHEN uplift_pct  >= AVG(uplift_pct)  OVER ()
            AND runup_total >= AVG(runup_total) OVER () THEN '1. TOP PRIORITY'
           WHEN runup_total >= AVG(runup_total) OVER ()  THEN '2. HIGH VOLUME'
           WHEN uplift_pct  >= AVG(uplift_pct)  OVER ()  THEN '3. HIGH RESPONSE'
           ELSE                                                '4. LOW PRIORITY'
       END AS priority,
       br_city, runup_avg, normal_avg, uplift_pct, runup_total, year_total, runup_share,
       br_ID
FROM   ranked
ORDER  BY priority, uplift_pct DESC;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
PROMPT
ACCEPT branch CHAR DEFAULT 'Kuala Lumpur' PROMPT 'Branch city for section 4 (default Kuala Lumpur): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. &branch, &fest_label &focus_y: WHAT TO PUSH' SKIP 1 -
       CENTER 'STEP 4: UPSELL/BUNDLE CANDIDATES - MIX SHIFT BY CATEGORY' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN product_category HEADING 'CATEGORY'            FORMAT A20
COLUMN runup_avg        HEADING 'RUN-UP|AVG/DAY (RM)' FORMAT 99,990.00
COLUMN normal_avg       HEADING 'NORMAL|AVG/DAY (RM)' FORMAT 99,990.00
COLUMN uplift_pct       HEADING 'RUN-UP|UPLIFT %'     FORMAT S9990.0
COLUMN runup_total      HEADING 'RUN-UP|REVENUE (RM)' FORMAT 999,990.00
COLUMN mix_normal       HEADING 'MIX IN|NORMAL %'     FORMAT 990.0
COLUMN mix_runup        HEADING 'MIX IN|RUN-UP %'     FORMAT 990.0
COLUMN mix_shift        HEADING 'MIX SHIFT|(PP)'      FORMAT S990.0

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
    SELECT p.product_category, f.date_key,
           SUM(f.order_total_amt) AS rev
    FROM   order_fact  f
    JOIN   product_dim p ON p.product_key = f.product_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    UPPER(b.br_city) = UPPER('&branch')
    GROUP  BY p.product_category, f.date_key
),
cat_day AS (
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
),
mix_calc AS (
    SELECT product_category, runup_avg, normal_avg,
           ROUND(runup_avg / NULLIF(normal_avg, 0) * 100 - 100, 1)  AS uplift_pct,
           runup_total,
           ROUND(RATIO_TO_REPORT(normal_total) OVER () * 100, 1)    AS mix_normal,
           ROUND(RATIO_TO_REPORT(runup_total)  OVER () * 100, 1)    AS mix_runup
    FROM   by_cat
)
SELECT product_category, runup_avg, normal_avg, uplift_pct, runup_total,
       mix_normal, mix_runup,
       mix_runup - mix_normal AS mix_shift
FROM   mix_calc
ORDER  BY uplift_pct DESC;

PROMPT
PROMPT +==========================================================+
PROMPT |       END OF FESTIVE CAMPAIGN TARGETING REPORT           |
PROMPT +==========================================================+
PROMPT

SPOOL OFF
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE focus_year
UNDEFINE festival
UNDEFINE fest_label
UNDEFINE area
UNDEFINE branch
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
