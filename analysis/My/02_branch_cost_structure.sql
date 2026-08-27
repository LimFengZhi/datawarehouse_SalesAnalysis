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

ACCEPT start_year NUMBER DEFAULT 2023  PROMPT 'Enter the START year of the analysis (default 2023): '
ACCEPT end_year   NUMBER DEFAULT 2025  PROMPT 'Enter the END year of the analysis   (default 2025): '
ACCEPT state      CHAR   DEFAULT 'ALL' PROMPT 'Enter a state (e.g. Selangor) or ALL for every state (default ALL): '

SET TERMOUT OFF
COLUMN run_dt NEW_VALUE run_dt NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN yr_range NEW_VALUE yr_range NOPRINT
SELECT TO_CHAR(&start_year) || ' - ' || TO_CHAR(&end_year) AS yr_range FROM dual;

COLUMN st_label NEW_VALUE st_label NOPRINT
SELECT CASE
         WHEN UPPER(TRIM('&state')) IN ('', 'ALL') THEN 'ALL STATES'
         ELSE NVL(MAX(UPPER(br_state)), 'NO MATCH: ' || UPPER(TRIM('&state')))
       END AS st_label
FROM   branch_dim
WHERE  UPPER(br_state) LIKE '%' || UPPER(TRIM('&state')) || '%';
CLEAR COLUMNS
SET TERMOUT ON

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - A. COST STREAM MIX BY YEAR' SKIP 1 -
       CENTER 'PAYROLL VS INVENTORY VS OVERHEAD, &yr_range' SKIP 1 -
       CENTER '&st_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year       HEADING 'YEAR'                        FORMAT 9999
COLUMN branches       HEADING 'BRANCHES'                    FORMAT 99
COLUMN payroll_cost   HEADING 'PAYROLL (RM)'                FORMAT 99,999,990
COLUMN inventory_cost HEADING 'INVENTORY (RM)'              FORMAT 99,999,990
COLUMN overhead_cost  HEADING 'OVERHEAD (RM)'               FORMAT 99,999,990
COLUMN total_cost     HEADING 'TOTAL COST (RM)'             FORMAT 999,999,990
COLUMN avg_per_branch HEADING 'AVG MONTHLY COST|PER BRANCH' FORMAT 999,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF payroll_cost inventory_cost overhead_cost total_cost ON REPORT

WITH cost_lines AS (
    SELECT b.br_ID, d.cal_year, d.cal_year_month,
           'Overhead' AS cost_stream, f.payment_amt AS amt
    FROM   branch_utils_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    UNION ALL
    SELECT b.br_ID, d.cal_year, d.cal_year_month,
           'Payroll', s.base_amt + s.bonus_amt
    FROM   salary_payment_fact s
    JOIN   date_dim   d ON d.date_key   = s.date_key
    JOIN   branch_dim b ON b.branch_key = s.branch_key
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    UNION ALL
    SELECT b.br_ID, d.cal_year, d.cal_year_month,
           'Inventory', p.purchase_total_cost
    FROM   purchase_fact p
    JOIN   date_dim   d ON d.date_key   = p.date_key
    JOIN   branch_dim b ON b.branch_key = p.branch_key
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
)
SELECT cal_year,
       COUNT(DISTINCT br_ID)                                              AS branches,
       SUM(CASE WHEN cost_stream = 'Payroll'   THEN amt ELSE 0 END)       AS payroll_cost,
       SUM(CASE WHEN cost_stream = 'Inventory' THEN amt ELSE 0 END)       AS inventory_cost,
       SUM(CASE WHEN cost_stream = 'Overhead'  THEN amt ELSE 0 END)       AS overhead_cost,
       SUM(amt)                                                           AS total_cost,
       ROUND(SUM(amt)
             / NULLIF(COUNT(DISTINCT TO_CHAR(br_ID) || '-'
                                  || TO_CHAR(cal_year_month)), 0), 2)     AS avg_per_branch
FROM   cost_lines
GROUP  BY cal_year
ORDER  BY cal_year;

CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - B. COST STRUCTURE BY BRANCH, RANKED PER YEAR' SKIP 1 -
       CENTER 'RANKED BY TOTAL COST, &yr_range' SKIP 1 -
       CENTER '&st_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year       HEADING 'YEAR'               FORMAT A5
COLUMN rnk            HEADING 'RANK'               FORMAT A5
COLUMN br_city        HEADING 'BRANCH'             FORMAT A14
COLUMN mths           HEADING 'MTHS'               FORMAT 99
COLUMN staff_cnt      HEADING 'STAFF'              FORMAT 999
COLUMN payroll_cost   HEADING 'PAYROLL|(RM)'       FORMAT 99,999,990
COLUMN inventory_cost HEADING 'INVENTORY|(RM)'     FORMAT 99,999,990
COLUMN overhead_cost  HEADING 'OVERHEAD|(RM)'      FORMAT 99,999,990
COLUMN year_cost      HEADING 'TOTAL COST|(RM)'    FORMAT 99,999,990
COLUMN pct_payroll    HEADING 'PAY|% MIX'          FORMAT 990.0
COLUMN pct_invent     HEADING 'INV|% MIX'          FORMAT 990.0
COLUMN pct_ovhd       HEADING 'OVH|% MIX'          FORMAT 990.0
COLUMN cost_per_sm    HEADING 'COST PER|STAFF-MTH' FORMAT 999,990.00
COLUMN vs_avg         HEADING 'VS AVG|%'           FORMAT S990.0

BREAK ON cal_year SKIP 1
COMPUTE SUM LABEL 'TOTAL' OF payroll_cost inventory_cost overhead_cost -
                             year_cost ON cal_year

WITH cost_lines AS (
    SELECT b.br_ID, d.cal_year, d.cal_year_month,
           'Overhead' AS cost_stream, f.payment_amt AS amt
    FROM   branch_utils_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    UNION ALL
    SELECT b.br_ID, d.cal_year, d.cal_year_month,
           'Payroll', s.base_amt + s.bonus_amt
    FROM   salary_payment_fact s
    JOIN   date_dim   d ON d.date_key   = s.date_key
    JOIN   branch_dim b ON b.branch_key = s.branch_key
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    UNION ALL
    SELECT b.br_ID, d.cal_year, d.cal_year_month,
           'Inventory', p.purchase_total_cost
    FROM   purchase_fact p
    JOIN   date_dim   d ON d.date_key   = p.date_key
    JOIN   branch_dim b ON b.branch_key = p.branch_key
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
),
branch_year AS (
    SELECT br_ID, cal_year,
           COUNT(DISTINCT cal_year_month)                               AS mths,
           SUM(CASE WHEN cost_stream = 'Payroll'   THEN amt ELSE 0 END) AS payroll_cost,
           SUM(CASE WHEN cost_stream = 'Inventory' THEN amt ELSE 0 END) AS inventory_cost,
           SUM(CASE WHEN cost_stream = 'Overhead'  THEN amt ELSE 0 END) AS overhead_cost,
           SUM(amt)                                                     AS year_cost
    FROM   cost_lines
    GROUP  BY br_ID, cal_year
),
headcount AS (
    SELECT b.br_ID, d.cal_year, COUNT(DISTINCT st.st_ID) AS staff_cnt
    FROM   salary_payment_fact s
    JOIN   date_dim   d  ON d.date_key   = s.date_key
    JOIN   branch_dim b  ON b.branch_key = s.branch_key
    JOIN   staff_dim  st ON st.staff_key = s.staff_key
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    GROUP  BY b.br_ID, d.cal_year
),
per_unit AS (
    SELECT c.cal_year, b.br_city, c.mths, h.staff_cnt,
           c.payroll_cost, c.inventory_cost, c.overhead_cost, c.year_cost,
           c.year_cost / NULLIF(c.mths * h.staff_cnt, 0) AS cost_per_sm
    FROM   branch_year c
    JOIN   branch_dim b ON b.br_ID = c.br_ID AND b.is_current_flag = 'Y'
    LEFT   JOIN headcount h ON h.br_ID = c.br_ID AND h.cal_year = c.cal_year
),
ranked AS (
    SELECT u.cal_year, u.br_city, u.mths, u.staff_cnt,
           u.payroll_cost, u.inventory_cost, u.overhead_cost, u.year_cost,
           u.cost_per_sm,
           RANK() OVER (PARTITION BY u.cal_year ORDER BY u.year_cost DESC) AS rank_num,
           (u.cost_per_sm - AVG(u.cost_per_sm) OVER (PARTITION BY u.cal_year))
           / NULLIF(AVG(u.cost_per_sm) OVER (PARTITION BY u.cal_year), 0) * 100 AS vs_avg
    FROM   per_unit u
)
SELECT TO_CHAR(cal_year)                                                AS cal_year,
       TO_CHAR(rank_num)                                                AS rnk,
       br_city,
       mths,
       staff_cnt,
       payroll_cost,
       inventory_cost,
       overhead_cost,
       year_cost,
       ROUND(payroll_cost   * 100.0 / NULLIF(year_cost, 0), 1)          AS pct_payroll,
       ROUND(inventory_cost * 100.0 / NULLIF(year_cost, 0), 1)          AS pct_invent,
       ROUND(overhead_cost  * 100.0 / NULLIF(year_cost, 0), 1)          AS pct_ovhd,
       ROUND(cost_per_sm, 2)                                            AS cost_per_sm,
       ROUND(vs_avg, 1)                                                 AS vs_avg
FROM   ranked
ORDER  BY cal_year, rank_num;

PROMPT
PROMPT +==========================================================+
PROMPT |  END OF BRANCH OPERATING COST STRUCTURE REPORT           |
PROMPT +==========================================================+
PROMPT

TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE start_year
UNDEFINE end_year
UNDEFINE state
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
