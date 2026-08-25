SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 132
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL staff_promotion_readiness_output.txt


TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. BEAUTY THERAPIST CANDIDATE POOL BASELINE' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC' FORMAT A50
COLUMN metric_value HEADING 'VALUE'  FORMAT A28

WITH hire AS (
    SELECT sd.st_ID, MIN(d.cal_date) AS hire_date
    FROM   salary_payment_fact sp
    JOIN   staff_dim sd ON sd.staff_key = sp.staff_key
    JOIN   date_dim   d ON d.date_key   = sp.date_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID
),
ref_date AS (
    SELECT MAX(d.cal_date) AS ref_date
    FROM   salary_payment_fact sp
    JOIN   date_dim d ON d.date_key = sp.date_key
    WHERE  d.date_key <> 0
),
current_bt AS (
    SELECT DISTINCT sd.st_ID, sd.st_name
    FROM   staff_dim sd
    WHERE  sd.st_position = 'Beauty Therapist'
    AND    sd.is_current_flag = 'Y'
    AND    sd.st_status = 'Active'
),
rev AS (
    SELECT sd.st_ID, SUM(f.serv_net_amt) AS revenue
    FROM   reservation_fact f
    JOIN   staff_dim sd ON sd.staff_key = f.staff_key
    WHERE  f.res_status = 'Completed'
    GROUP  BY sd.st_ID
),
cost AS (
    SELECT sd.st_ID, SUM(sp.base_amt + sp.bonus_amt) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   staff_dim sd ON sd.staff_key = sp.staff_key
    GROUP  BY sd.st_ID
),
candidates AS (
    SELECT c.st_ID,
           GREATEST(0, ROUND(MONTHS_BETWEEN(rd.ref_date, h.hire_date) / 12, 1)) AS tenure_years,
           ROUND(NVL(r.revenue, 0) / NULLIF(co.labor_cost, 0), 2)              AS rcr
    FROM   current_bt c
    JOIN   hire h  ON h.st_ID  = c.st_ID
    CROSS  JOIN ref_date rd
    JOIN   cost co ON co.st_ID = c.st_ID
    LEFT   JOIN rev r ON r.st_ID = c.st_ID
),
stats AS (
    SELECT COUNT(*)          AS heads,
           AVG(rcr)          AS avg_rcr,
           MIN(rcr)          AS min_rcr,
           MAX(rcr)          AS max_rcr,
           AVG(tenure_years) AS avg_tenure,
           MIN(tenure_years) AS min_tenure,
           MAX(tenure_years) AS max_tenure
    FROM   candidates
)
SELECT 'Active Beauty Therapists (candidate pool)' AS metric_name,
       TO_CHAR(heads)                                                        AS metric_value FROM stats
UNION ALL SELECT 'Average RCR (revenue / labor cost)',
       TRIM(TO_CHAR(avg_rcr, '990.00'))                                                       FROM stats
UNION ALL SELECT 'RCR range, lowest to highest',
       TRIM(TO_CHAR(min_rcr, '990.00')) || ' - ' || TRIM(TO_CHAR(max_rcr, '990.00'))           FROM stats
UNION ALL SELECT 'Average tenure (years)',
       TRIM(TO_CHAR(avg_tenure, '990.0'))                                                     FROM stats
UNION ALL SELECT 'Tenure range, newest to longest-serving (years)',
       TRIM(TO_CHAR(min_tenure, '990.0')) || ' - ' || TRIM(TO_CHAR(max_tenure, '990.0'))       FROM stats;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. INDIVIDUAL PROMOTION PRIORITY' SKIP 1 -
       CENTER 'BEAUTY THERAPIST -> SENIOR THERAPIST CANDIDATES' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN priority      HEADING 'PROMOTION PRIORITY'  FORMAT A30
COLUMN st_name       HEADING 'STAFF NAME'          FORMAT A22
COLUMN br_city       HEADING 'BRANCH'              FORMAT A15
COLUMN tenure_years  HEADING 'TENURE|(YEARS)'      FORMAT 990.0
COLUMN rcr           HEADING 'RCR'                 FORMAT 990.00

BREAK ON priority SKIP 1

WITH hire AS (
    SELECT sd.st_ID, MIN(d.cal_date) AS hire_date
    FROM   salary_payment_fact sp
    JOIN   staff_dim sd ON sd.staff_key = sp.staff_key
    JOIN   date_dim   d ON d.date_key   = sp.date_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID
),
ref_date AS (
    SELECT MAX(d.cal_date) AS ref_date
    FROM   salary_payment_fact sp
    JOIN   date_dim d ON d.date_key = sp.date_key
    WHERE  d.date_key <> 0
),
current_bt AS (
    SELECT DISTINCT sd.st_ID, sd.st_name
    FROM   staff_dim sd
    WHERE  sd.st_position = 'Beauty Therapist'
    AND    sd.is_current_flag = 'Y'
    AND    sd.st_status = 'Active'
),
rev AS (
    SELECT sd.st_ID, SUM(f.serv_net_amt) AS revenue
    FROM   reservation_fact f
    JOIN   staff_dim sd ON sd.staff_key = f.staff_key
    WHERE  f.res_status = 'Completed'
    GROUP  BY sd.st_ID
),
cost AS (
    SELECT sd.st_ID, SUM(sp.base_amt + sp.bonus_amt) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   staff_dim sd ON sd.staff_key = sp.staff_key
    GROUP  BY sd.st_ID
),
home_branch AS (
    SELECT st_ID, br_city FROM (
        SELECT sd.st_ID, b.br_city,
               ROW_NUMBER() OVER (PARTITION BY sd.st_ID ORDER BY d.cal_date DESC) AS rn
        FROM   salary_payment_fact sp
        JOIN   staff_dim  sd ON sd.staff_key  = sp.staff_key
        JOIN   branch_dim b  ON b.branch_key  = sp.branch_key
        JOIN   date_dim   d  ON d.date_key    = sp.date_key
        WHERE  d.date_key <> 0
    )
    WHERE rn = 1
),
candidates AS (
    SELECT c.st_ID, c.st_name, hb.br_city,
           GREATEST(0, ROUND(MONTHS_BETWEEN(rd.ref_date, h.hire_date) / 12, 1)) AS tenure_years,
           ROUND(NVL(r.revenue, 0) / NULLIF(co.labor_cost, 0), 2)              AS rcr
    FROM   current_bt c
    JOIN   hire h  ON h.st_ID  = c.st_ID
    CROSS  JOIN ref_date rd
    JOIN   cost co ON co.st_ID = c.st_ID
    LEFT   JOIN rev r ON r.st_ID = c.st_ID
    JOIN   home_branch hb ON hb.st_ID = c.st_ID
)
SELECT CASE
           WHEN rcr >= AVG(rcr) OVER () AND tenure_years >= AVG(tenure_years) OVER () THEN '1. READY FOR PROMOTION'
           WHEN rcr >= AVG(rcr) OVER ()                                               THEN '2. FAST-TRACK CANDIDATE'
           WHEN tenure_years >= AVG(tenure_years) OVER ()                             THEN '3. TENURE WITHOUT PERFORMANCE'
           ELSE                                                                            '4. DEVELOPING'
       END AS priority,
       st_name, br_city, tenure_years, rcr
FROM   candidates
ORDER  BY priority, rcr DESC;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
PROMPT
ACCEPT branch CHAR DEFAULT 'ALL' PROMPT 'Branch city to narrow section 3 to, or ALL (default ALL): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. &branch: PROMOTION CANDIDATES AT THIS BRANCH' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN priority      HEADING 'PROMOTION PRIORITY'  FORMAT A30
COLUMN st_name       HEADING 'STAFF NAME'          FORMAT A22
COLUMN br_city       HEADING 'BRANCH'              FORMAT A15
COLUMN tenure_years  HEADING 'TENURE|(YEARS)'      FORMAT 990.0
COLUMN rcr           HEADING 'RCR'                 FORMAT 990.00

BREAK ON priority SKIP 1

WITH hire AS (
    SELECT sd.st_ID, MIN(d.cal_date) AS hire_date
    FROM   salary_payment_fact sp
    JOIN   staff_dim sd ON sd.staff_key = sp.staff_key
    JOIN   date_dim   d ON d.date_key   = sp.date_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID
),
ref_date AS (
    SELECT MAX(d.cal_date) AS ref_date
    FROM   salary_payment_fact sp
    JOIN   date_dim d ON d.date_key = sp.date_key
    WHERE  d.date_key <> 0
),
current_bt AS (
    SELECT DISTINCT sd.st_ID, sd.st_name
    FROM   staff_dim sd
    WHERE  sd.st_position = 'Beauty Therapist'
    AND    sd.is_current_flag = 'Y'
    AND    sd.st_status = 'Active'
),
rev AS (
    SELECT sd.st_ID, SUM(f.serv_net_amt) AS revenue
    FROM   reservation_fact f
    JOIN   staff_dim sd ON sd.staff_key = f.staff_key
    WHERE  f.res_status = 'Completed'
    GROUP  BY sd.st_ID
),
cost AS (
    SELECT sd.st_ID, SUM(sp.base_amt + sp.bonus_amt) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   staff_dim sd ON sd.staff_key = sp.staff_key
    GROUP  BY sd.st_ID
),
home_branch AS (
    SELECT st_ID, br_city FROM (
        SELECT sd.st_ID, b.br_city,
               ROW_NUMBER() OVER (PARTITION BY sd.st_ID ORDER BY d.cal_date DESC) AS rn
        FROM   salary_payment_fact sp
        JOIN   staff_dim  sd ON sd.staff_key  = sp.staff_key
        JOIN   branch_dim b  ON b.branch_key  = sp.branch_key
        JOIN   date_dim   d  ON d.date_key    = sp.date_key
        WHERE  d.date_key <> 0
    )
    WHERE rn = 1
),
candidates AS (
    SELECT c.st_ID, c.st_name, hb.br_city,
           GREATEST(0, ROUND(MONTHS_BETWEEN(rd.ref_date, h.hire_date) / 12, 1)) AS tenure_years,
           ROUND(NVL(r.revenue, 0) / NULLIF(co.labor_cost, 0), 2)              AS rcr
    FROM   current_bt c
    JOIN   hire h  ON h.st_ID  = c.st_ID
    CROSS  JOIN ref_date rd
    JOIN   cost co ON co.st_ID = c.st_ID
    LEFT   JOIN rev r ON r.st_ID = c.st_ID
    JOIN   home_branch hb ON hb.st_ID = c.st_ID
),
ranked AS (
    SELECT st_ID, st_name, br_city, tenure_years, rcr,
           CASE
               WHEN rcr >= AVG(rcr) OVER () AND tenure_years >= AVG(tenure_years) OVER () THEN '1. READY FOR PROMOTION'
               WHEN rcr >= AVG(rcr) OVER ()                                               THEN '2. FAST-TRACK CANDIDATE'
               WHEN tenure_years >= AVG(tenure_years) OVER ()                             THEN '3. TENURE WITHOUT PERFORMANCE'
               ELSE                                                                            '4. DEVELOPING'
           END AS priority
    FROM   candidates
)
SELECT priority, st_name, br_city, tenure_years, rcr
FROM   ranked
WHERE  UPPER('&branch') = 'ALL' OR UPPER(br_city) = UPPER('&branch')
ORDER  BY priority, rcr DESC;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. PROMOTION PRIORITY SUMMARY STATISTICS' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN priority      HEADING 'PROMOTION PRIORITY'  FORMAT A30
COLUMN heads         HEADING 'HEADS'               FORMAT 990
COLUMN avg_rcr       HEADING 'AVG RCR'              FORMAT 990.00
COLUMN avg_tenure    HEADING 'AVG TENURE|(YEARS)'   FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF heads ON REPORT

WITH hire AS (
    SELECT sd.st_ID, MIN(d.cal_date) AS hire_date
    FROM   salary_payment_fact sp
    JOIN   staff_dim sd ON sd.staff_key = sp.staff_key
    JOIN   date_dim   d ON d.date_key   = sp.date_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID
),
ref_date AS (
    SELECT MAX(d.cal_date) AS ref_date
    FROM   salary_payment_fact sp
    JOIN   date_dim d ON d.date_key = sp.date_key
    WHERE  d.date_key <> 0
),
current_bt AS (
    SELECT DISTINCT sd.st_ID, sd.st_name
    FROM   staff_dim sd
    WHERE  sd.st_position = 'Beauty Therapist'
    AND    sd.is_current_flag = 'Y'
    AND    sd.st_status = 'Active'
),
rev AS (
    SELECT sd.st_ID, SUM(f.serv_net_amt) AS revenue
    FROM   reservation_fact f
    JOIN   staff_dim sd ON sd.staff_key = f.staff_key
    WHERE  f.res_status = 'Completed'
    GROUP  BY sd.st_ID
),
cost AS (
    SELECT sd.st_ID, SUM(sp.base_amt + sp.bonus_amt) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   staff_dim sd ON sd.staff_key = sp.staff_key
    GROUP  BY sd.st_ID
),
candidates AS (
    SELECT c.st_ID,
           GREATEST(0, ROUND(MONTHS_BETWEEN(rd.ref_date, h.hire_date) / 12, 1)) AS tenure_years,
           ROUND(NVL(r.revenue, 0) / NULLIF(co.labor_cost, 0), 2)              AS rcr
    FROM   current_bt c
    JOIN   hire h  ON h.st_ID  = c.st_ID
    CROSS  JOIN ref_date rd
    JOIN   cost co ON co.st_ID = c.st_ID
    LEFT   JOIN rev r ON r.st_ID = c.st_ID
),
ranked AS (
    SELECT tenure_years, rcr,
           CASE
               WHEN rcr >= AVG(rcr) OVER () AND tenure_years >= AVG(tenure_years) OVER () THEN '1. READY FOR PROMOTION'
               WHEN rcr >= AVG(rcr) OVER ()                                               THEN '2. FAST-TRACK CANDIDATE'
               WHEN tenure_years >= AVG(tenure_years) OVER ()                             THEN '3. TENURE WITHOUT PERFORMANCE'
               ELSE                                                                            '4. DEVELOPING'
           END AS priority
    FROM   candidates
)
SELECT priority,
       COUNT(*)                    AS heads,
       ROUND(AVG(rcr), 2)          AS avg_rcr,
       ROUND(AVG(tenure_years), 1) AS avg_tenure
FROM   ranked
GROUP  BY priority
ORDER  BY priority;

PROMPT
PROMPT +==========================================================+
PROMPT |      END OF STAFF PROMOTION READINESS REPORT             |
PROMPT +==========================================================+
PROMPT

SPOOL OFF
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE branch
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
