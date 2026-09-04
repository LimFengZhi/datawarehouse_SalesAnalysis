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

SPOOL staff_promotion_readiness_b_output.txt

PROMPT
ACCEPT from_year CHAR DEFAULT 2019 PROMPT 'From year (default 2019): '
ACCEPT to_year   CHAR DEFAULT 2025 PROMPT 'To year   (default 2025): '
PROMPT


TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. BRANCHES RANKED BY % READY FOR PROMOTION' SKIP 1 -
       CENTER '&from_year - &to_year' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city         HEADING 'BRANCH'              FORMAT A15
COLUMN ready_count     HEADING 'READY FOR|PROMOTION' FORMAT 9990
COLUMN total_candidates HEADING 'TOTAL|CANDIDATES'   FORMAT 9990
COLUMN pct_ready       HEADING 'PCT READY|FOR PROMO %' FORMAT 990.0

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
    AND    d.cal_year BETWEEN TO_NUMBER('&from_year') AND TO_NUMBER('&to_year')
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
    JOIN   date_dim  d  ON d.date_key   = f.date_key
    WHERE  f.res_status = 'Completed'
    AND    d.date_key <> 0
    AND    d.cal_year BETWEEN TO_NUMBER('&from_year') AND TO_NUMBER('&to_year')
    GROUP  BY sd.st_ID
),
cost AS (
    SELECT sd.st_ID, SUM(sp.base_amt + sp.bonus_amt) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   staff_dim sd ON sd.staff_key = sp.staff_key
    JOIN   date_dim  d  ON d.date_key   = sp.date_key
    WHERE  d.date_key <> 0
    AND    d.cal_year BETWEEN TO_NUMBER('&from_year') AND TO_NUMBER('&to_year')
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
        AND    d.cal_year BETWEEN TO_NUMBER('&from_year') AND TO_NUMBER('&to_year')
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
),
branch_totals AS (
    SELECT br_city, COUNT(*) AS total_candidates
    FROM   ranked
    GROUP  BY br_city
),
branch_ready AS (
    SELECT br_city, COUNT(*) AS ready_count
    FROM   ranked
    WHERE  priority = '1. READY FOR PROMOTION'
    GROUP  BY br_city
)
SELECT bt.br_city,
       NVL(br.ready_count, 0)                                          AS ready_count,
       bt.total_candidates,
       ROUND(NVL(br.ready_count, 0) * 100.0 / bt.total_candidates, 1)  AS pct_ready
FROM   branch_totals bt
LEFT   JOIN branch_ready br ON br.br_city = bt.br_city
ORDER  BY pct_ready DESC;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
PROMPT
ACCEPT branch CHAR DEFAULT 'ALL' PROMPT 'Branch city to drill down to, or ALL (default ALL): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. &branch: PROMOTION CANDIDATES AT THIS BRANCH' SKIP 1 -
       CENTER '&from_year - &to_year' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN priority      HEADING 'PROMOTION PRIORITY'  FORMAT A30
COLUMN st_name       HEADING 'STAFF NAME'          FORMAT A22
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
    AND    d.cal_year BETWEEN TO_NUMBER('&from_year') AND TO_NUMBER('&to_year')
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
    JOIN   date_dim  d  ON d.date_key   = f.date_key
    WHERE  f.res_status = 'Completed'
    AND    d.date_key <> 0
    AND    d.cal_year BETWEEN TO_NUMBER('&from_year') AND TO_NUMBER('&to_year')
    GROUP  BY sd.st_ID
),
cost AS (
    SELECT sd.st_ID, SUM(sp.base_amt + sp.bonus_amt) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   staff_dim sd ON sd.staff_key = sp.staff_key
    JOIN   date_dim  d  ON d.date_key   = sp.date_key
    WHERE  d.date_key <> 0
    AND    d.cal_year BETWEEN TO_NUMBER('&from_year') AND TO_NUMBER('&to_year')
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
        AND    d.cal_year BETWEEN TO_NUMBER('&from_year') AND TO_NUMBER('&to_year')
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
SELECT priority, st_name, tenure_years, rcr
FROM   ranked
WHERE  UPPER('&branch') = 'ALL' OR UPPER(br_city) = UPPER('&branch')
ORDER  BY priority, rcr DESC;

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
UNDEFINE from_year
UNDEFINE to_year
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
