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

ACCEPT branch CHAR DEFAULT 'Kuala Lumpur' PROMPT 'Branch city for sections 3-4 (default Kuala Lumpur): '

SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL staff_productivity_profit_output.txt


TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. REVENUE vs LABOR COST, BY POSITION' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN st_position   HEADING 'POSITION'           FORMAT A18
COLUMN heads         HEADING 'THERA-|PISTS'       FORMAT 990
COLUMN hours         HEADING 'HOURS'              FORMAT 999,990.0
COLUMN revenue       HEADING 'REVENUE (RM)'       FORMAT 99,999,990.00
COLUMN rev_hr        HEADING 'REV PER|HOUR (RM)'  FORMAT 9,990.00
COLUMN labor_cost    HEADING 'LABOR COST (RM)'    FORMAT 99,999,990.00
COLUMN cost_hr       HEADING 'COST PER|HOUR (RM)' FORMAT 9,990.00
COLUMN rcr           HEADING 'RCR'                FORMAT 990.00

WITH hrs AS (
    SELECT sd.st_ID, sd.st_position, d.cal_year_month,
           SUM(f.res_duration) / 60                    AS hours,
           SUM(f.serv_net_amt)                          AS revenue
    FROM   reservation_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    WHERE  f.res_status = 'Completed' AND d.date_key <> 0
    GROUP  BY sd.st_ID, sd.st_position, d.cal_year_month
),
cost AS (
    SELECT sd.st_ID, d.cal_year_month,
           SUM(sp.base_amt + sp.bonus_amt) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   date_dim   d  ON d.date_key   = sp.date_key
    JOIN   staff_dim  sd ON sd.staff_key = sp.staff_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID, d.cal_year_month
),
joined AS (
    SELECT h.st_position, h.st_ID, h.hours, h.revenue, c.labor_cost
    FROM   hrs h
    JOIN   cost c ON c.st_ID = h.st_ID AND c.cal_year_month = h.cal_year_month
)
SELECT st_position,
       COUNT(DISTINCT st_ID)                              AS heads,
       SUM(hours)                                         AS hours,
       SUM(revenue)                                       AS revenue,
       SUM(revenue) / NULLIF(SUM(hours),0)                AS rev_hr,
       SUM(labor_cost)                                    AS labor_cost,
       SUM(labor_cost) / NULLIF(SUM(hours),0)              AS cost_hr,
       ROUND(SUM(revenue) / NULLIF(SUM(labor_cost),0), 2) AS rcr
FROM   joined
GROUP  BY st_position
ORDER  BY rcr DESC;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. REVENUE vs LABOR COST, BY BRANCH' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city    HEADING 'BRANCH'              FORMAT A15
COLUMN heads      HEADING 'THERA-|PISTS'        FORMAT 990
COLUMN hours      HEADING 'HOURS'               FORMAT 99,990.0
COLUMN revenue    HEADING 'REVENUE (RM)'        FORMAT 9,999,990.00
COLUMN rev_hr     HEADING 'REV PER|HOUR (RM)'   FORMAT 9,990.00
COLUMN labor_cost HEADING 'LABOR COST (RM)'     FORMAT 9,999,990.00
COLUMN cost_hr    HEADING 'COST PER|HOUR (RM)'  FORMAT 9,990.00
COLUMN rcr        HEADING 'RCR'                 FORMAT 990.00

WITH hrs AS (
    SELECT b.br_ID, b.br_city, sd.st_ID, d.cal_year_month,
           SUM(f.res_duration) / 60                    AS hours,
           SUM(f.serv_net_amt)                          AS revenue
    FROM   reservation_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    JOIN   branch_dim b  ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed' AND d.date_key <> 0
    GROUP  BY b.br_ID, b.br_city, sd.st_ID, d.cal_year_month
),
cost AS (
    SELECT sd.st_ID, d.cal_year_month,
           SUM(sp.base_amt + sp.bonus_amt) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   date_dim   d  ON d.date_key   = sp.date_key
    JOIN   staff_dim  sd ON sd.staff_key = sp.staff_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID, d.cal_year_month
),
joined AS (
    SELECT h.br_ID, h.br_city, h.st_ID, h.hours, h.revenue, c.labor_cost
    FROM   hrs h
    JOIN   cost c ON c.st_ID = h.st_ID AND c.cal_year_month = h.cal_year_month
)
SELECT br_city,
       COUNT(DISTINCT st_ID)                              AS heads,
       SUM(hours)                                         AS hours,
       SUM(revenue)                                       AS revenue,
       SUM(revenue) / NULLIF(SUM(hours),0)                AS rev_hr,
       SUM(labor_cost)                                    AS labor_cost,
       SUM(labor_cost) / NULLIF(SUM(hours),0)              AS cost_hr,
       ROUND(SUM(revenue) / NULLIF(SUM(labor_cost),0), 2) AS rcr
FROM   joined
GROUP  BY br_ID, br_city
ORDER  BY rcr DESC;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. &branch: EVERY THERAPIST, RANKED' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN st_id       HEADING 'STAFF|ID'          FORMAT 99990
COLUMN st_position HEADING 'POSITION'          FORMAT A16
COLUMN hours       HEADING 'HOURS'             FORMAT 9,990.0
COLUMN services    HEADING 'SERVICES'          FORMAT 9,990
COLUMN revenue     HEADING 'REVENUE (RM)'      FORMAT 999,990.00
COLUMN rev_hr      HEADING 'REV PER|HOUR (RM)' FORMAT 9,990.00
COLUMN rcr         HEADING 'RCR'               FORMAT 990.00

WITH hrs AS (
    SELECT sd.st_ID, sd.st_position, d.cal_year_month,
           SUM(f.res_duration) / 60                    AS hours,
           COUNT(*)                                     AS services,
           SUM(f.serv_net_amt)                          AS revenue
    FROM   reservation_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    JOIN   branch_dim b  ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed' AND d.date_key <> 0
    AND    UPPER(b.br_city) = UPPER('&branch')
    GROUP  BY sd.st_ID, sd.st_position, d.cal_year_month
),
cost AS (
    SELECT sd.st_ID, d.cal_year_month,
           SUM(sp.base_amt + sp.bonus_amt) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   date_dim   d  ON d.date_key   = sp.date_key
    JOIN   staff_dim  sd ON sd.staff_key = sp.staff_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID, d.cal_year_month
),
joined AS (
    SELECT h.st_ID, h.st_position, h.hours, h.services, h.revenue,
           c.labor_cost
    FROM   hrs h
    JOIN   cost c ON c.st_ID = h.st_ID AND c.cal_year_month = h.cal_year_month
)
SELECT st_ID, st_position,
       SUM(hours)                                          AS hours,
       SUM(services)                                        AS services,
       SUM(revenue)                                        AS revenue,
       SUM(revenue) / NULLIF(SUM(hours),0)                 AS rev_hr,
       ROUND(SUM(revenue) / NULLIF(SUM(labor_cost),0), 2)  AS rcr
FROM   joined
GROUP  BY st_ID, st_position
ORDER  BY rev_hr DESC;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. &branch: WASTED HOURS BY THERAPIST' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN flag         HEADING 'FLAG'             FORMAT A31
COLUMN st_id        HEADING 'STAFF|ID'         FORMAT 99990
COLUMN st_position  HEADING 'POSITION'         FORMAT A16
COLUMN wasted_pct   HEADING 'WASTED|HOURS %'   FORMAT 990.0
COLUMN wasted_hours HEADING 'WASTED|HOURS'     FORMAT 9,990.0
COLUMN all_hours    HEADING 'SCHEDULED|HOURS'  FORMAT 9,990.0
COLUMN rcr          HEADING 'RCR'              FORMAT 990.00

BREAK ON flag SKIP 1

WITH branch_activity AS (
    SELECT sd.st_ID, sd.st_position, d.cal_year_month, f.res_status, f.res_duration,
           CASE WHEN f.res_status = 'Completed' THEN f.serv_net_amt ELSE 0 END AS revenue
    FROM   reservation_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    JOIN   branch_dim b  ON b.branch_key = f.branch_key
    WHERE  d.date_key <> 0
    AND    UPPER(b.br_city) = UPPER('&branch')
),
per_therapist AS (
    SELECT st_ID, st_position,
           SUM(res_duration) / 60                                                                 AS all_hours,
           SUM(CASE WHEN res_status IN ('Cancelled','No-Show') THEN res_duration ELSE 0 END) / 60  AS wasted_hours,
           SUM(revenue)                                                                            AS revenue
    FROM   branch_activity
    GROUP  BY st_ID, st_position
),
cost AS (
    SELECT sd.st_ID, d.cal_year_month,
           SUM(sp.base_amt + sp.bonus_amt) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   date_dim   d  ON d.date_key   = sp.date_key
    JOIN   staff_dim  sd ON sd.staff_key = sp.staff_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID, d.cal_year_month
),
therapist_cost AS (
    SELECT ba.st_ID, SUM(c.labor_cost) AS labor_cost
    FROM   (SELECT DISTINCT st_ID, cal_year_month FROM branch_activity) ba
    JOIN   cost c ON c.st_ID = ba.st_ID AND c.cal_year_month = ba.cal_year_month
    GROUP  BY ba.st_ID
),
by_therapist AS (
    SELECT pt.st_ID, pt.st_position,
           ROUND(pt.wasted_hours / NULLIF(pt.all_hours,0) * 100, 1) AS wasted_pct,
           pt.wasted_hours,
           pt.all_hours,
           ROUND(pt.revenue / NULLIF(tc.labor_cost,0), 2)           AS rcr
    FROM   per_therapist pt
    JOIN   therapist_cost tc ON tc.st_ID = pt.st_ID
)
SELECT CASE
           WHEN rcr <  AVG(rcr) OVER () AND wasted_pct <= AVG(wasted_pct) OVER () THEN 'NEEDS COACHING'
           WHEN rcr <  AVG(rcr) OVER () AND wasted_pct >  AVG(wasted_pct) OVER () THEN 'CHECK SCHEDULING'
           WHEN rcr >= AVG(rcr) OVER () AND wasted_pct >  AVG(wasted_pct) OVER () THEN 'STRONG DESPITE CANCELLATIONS'
           ELSE                                                                        'PERFORMING WELL'
       END AS flag,
       st_id, st_position, wasted_pct, wasted_hours, all_hours, rcr
FROM   by_therapist
ORDER  BY flag, wasted_pct DESC;

PROMPT +==========================================================+
PROMPT |        END OF STAFF PRODUCTIVITY PROFIT REPORT           |
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
