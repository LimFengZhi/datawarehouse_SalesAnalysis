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

ACCEPT start_year NUMBER DEFAULT 2019  PROMPT 'Enter the START year of the analysis (default 2019): '
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

COLUMN cal_year       HEADING 'YEAR'                    FORMAT 9999
COLUMN branches       HEADING 'BRANCHES'              FORMAT 99
COLUMN payroll_cost   HEADING 'PAYROLL (RM)'            FORMAT 99,999,990.00
COLUMN inventory_cost HEADING 'INVENTORY (RM)'          FORMAT 99,999,990.00
COLUMN overhead_cost  HEADING 'OVERHEAD (RM)'           FORMAT 99,999,990.00
COLUMN total_cost     HEADING 'TOTAL COST (RM)'         FORMAT 999,999,990.00
COLUMN avg_per_branch HEADING 'AVG MONTHLY COST|PER BRANCH'  FORMAT 999,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF payroll_cost inventory_cost overhead_cost total_cost ON REPORT

WITH cost_lines AS (
    SELECT b.br_ID, d.cal_year, d.cal_year_month,
           'Overhead' AS cost_stream, f.payment_amount AS amt
    FROM   branch_utils_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    UNION ALL
    SELECT b.br_ID, d.cal_year, d.cal_year_month,
           'Payroll', s.base_amount + s.bonus_amount
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
       SUM(amt)      
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
       CENTER 'GLOW BEAUTY - B. COST EFFICIENCY BY BRANCH, RANKED PER YEAR' SKIP 1 -
       CENTER 'REVENUE VS TOTAL COST, &yr_range   (POSITIVE = REVENUE AHEAD)' SKIP 1 -
       CENTER '&st_label' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year       HEADING 'YEAR'            FORMAT A5
COLUMN rnk            HEADING 'RANK'            FORMAT A5
COLUMN br_city        HEADING 'BRANCH'          FORMAT A14
COLUMN payroll_cost   HEADING 'PAYROLL (RM)'    FORMAT 99,999,990.00
COLUMN inventory_cost HEADING 'INVENTORY (RM)'  FORMAT 99,999,990.00
COLUMN overhead_cost  HEADING 'OVERHEAD (RM)'   FORMAT 99,999,990.00
COLUMN year_cost      HEADING 'TOTAL COST (RM)' FORMAT 99,999,990.00
COLUMN year_revenue   HEADING 'REVENUE (RM)'    FORMAT 99,999,990.00
COLUMN rev_vs_cost    HEADING 'REV VS COST %'   FORMAT S990.0

BREAK ON cal_year SKIP 1
COMPUTE SUM LABEL 'TOTAL' OF payroll_cost inventory_cost overhead_cost -
                             year_cost year_revenue ON cal_year

WITH cost_by_year AS (
    SELECT br_ID, cal_year,
           SUM(CASE WHEN cost_stream = 'Payroll'   THEN amt ELSE 0 END) AS payroll_cost,
           SUM(CASE WHEN cost_stream = 'Inventory' THEN amt ELSE 0 END) AS inventory_cost,
           SUM(CASE WHEN cost_stream = 'Overhead'  THEN amt ELSE 0 END) AS overhead_cost,
           SUM(amt)                                                     AS year_cost
    FROM  (SELECT b.br_ID, d.cal_year, 'Overhead' AS cost_stream,
                  f.payment_amount AS amt
           FROM   branch_utils_fact f
           JOIN   date_dim   d ON d.date_key   = f.date_key
           JOIN   branch_dim b ON b.branch_key = f.branch_key
           WHERE  d.cal_year BETWEEN &start_year AND &end_year
           AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
                  OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
           UNION ALL
           SELECT b.br_ID, d.cal_year, 'Payroll', s.base_amount + s.bonus_amount
           FROM   salary_payment_fact s
           JOIN   date_dim   d ON d.date_key   = s.date_key
           JOIN   branch_dim b ON b.branch_key = s.branch_key
           WHERE  d.cal_year BETWEEN &start_year AND &end_year
           AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
                  OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
           UNION ALL
           SELECT b.br_ID, d.cal_year, 'Inventory', p.purchase_total_cost
           FROM   purchase_fact p
           JOIN   date_dim   d ON d.date_key   = p.date_key
           JOIN   branch_dim b ON b.branch_key = p.branch_key
           WHERE  d.cal_year BETWEEN &start_year AND &end_year
           AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
                  OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%'))
    GROUP  BY br_ID, cal_year
),
revenue_by_year AS (
    SELECT b.br_ID, d.cal_year, SUM(v.amt) AS year_revenue
    FROM  (SELECT o.branch_key AS bk, o.date_key AS dk, o.order_net_amt AS amt
           FROM   order_fact o WHERE o.order_status = 'Completed'
           UNION ALL
           SELECT r.branch_key, r.date_key, r.serv_net_amt
           FROM   reservation_fact r WHERE r.res_status = 'Completed') v
    JOIN   branch_dim b ON b.branch_key = v.bk
    JOIN   date_dim   d ON d.date_key   = v.dk
    WHERE  d.cal_year BETWEEN &start_year AND &end_year
    AND   (UPPER(TRIM('&state')) IN ('', 'ALL')
           OR UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&state')) || '%')
    GROUP  BY b.br_ID, d.cal_year
),
ranked AS (
    SELECT c.cal_year, b.br_city,
           c.payroll_cost, c.inventory_cost, c.overhead_cost, c.year_cost,
           NVL(r.year_revenue, 0) AS year_revenue,
           RANK() OVER (PARTITION BY c.cal_year
                        ORDER BY (NVL(r.year_revenue, 0) - c.year_cost)
                                 / NULLIF(c.year_cost, 0) DESC NULLS LAST) AS rank_num
    FROM   cost_by_year c
    JOIN   branch_dim b ON b.br_ID = c.br_ID AND b.is_current_flag = 'Y'
    LEFT   JOIN revenue_by_year r ON r.br_ID = c.br_ID AND r.cal_year = c.cal_year
)
SELECT TO_CHAR(cal_year)                                             AS cal_year,
       TO_CHAR(rank_num)                                             AS rnk,
       br_city,
       payroll_cost,
       inventory_cost,
       overhead_cost,
       year_cost,
       year_revenue,
       ROUND((year_revenue - year_cost) / NULLIF(year_cost, 0) * 100, 1) AS rev_vs_cost
FROM   ranked
ORDER  BY cal_year, rank_num;

PROMPT
PROMPT +==========================================================+
PROMPT |  END OF BRANCH OPERATING COST AND EFFICIENCY REPORT      |
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
