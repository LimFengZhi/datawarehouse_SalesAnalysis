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
SET SQLBLANKLINES ON

PROMPT
ACCEPT p_from CHAR DEFAULT 2019 PROMPT 'Start year (default 2019): '
ACCEPT p_to   CHAR DEFAULT 2025 PROMPT 'End year   (default 2025): '
PROMPT


COLUMN rnk       HEADING 'RANK'                 FORMAT 9990
COLUMN category  HEADING 'SERVICE CATEGORY'     FORMAT A18
COLUMN yrs       HEADING 'YRS'                  FORMAT 90
COLUMN avg_custs HEADING 'AVG CUSTOMERS|PER YEAR' FORMAT 99,990
COLUMN avg_spend HEADING 'AVG SPEND|PER CUST'   FORMAT 9,990.00
COLUMN avg_disc  HEADING 'AVG DISCOUNT|PER YEAR' FORMAT 999,990
COLUMN avg_rev   HEADING 'AVG REVENUE|PER YEAR' FORMAT 9,999,990

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF avg_custs avg_spend avg_disc avg_rev ON REPORT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - A. SERVICE CATEGORIES, THE AVERAGE YEAR' SKIP 1 -
       CENTER 'PER TRADING YEAR, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

WITH cat_year AS (
    SELECT s.serv_category         AS category,
           d.cal_year              AS cal_year,
           SUM(f.serv_net_amt)     AS revenue,
           COUNT(DISTINCT c.cus_ID) AS custs,
           SUM(f.serv_discount_amt) AS discount
    FROM   reservation_fact f
    JOIN   service_dim  s ON s.service_key  = f.service_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   date_dim     d ON d.date_key     = f.date_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    GROUP  BY s.serv_category, d.cal_year
)
SELECT RANK() OVER (ORDER BY AVG(cy.revenue) DESC)          AS rnk,
       cy.category                                          AS category,
       COUNT(*)                                             AS yrs,
       AVG(cy.custs)                                        AS avg_custs,
       AVG(cy.revenue / NULLIF(cy.custs, 0))                AS avg_spend,
       AVG(cy.discount)                                     AS avg_disc,
       AVG(cy.revenue)                                      AS avg_rev
FROM   cat_year cy
GROUP  BY cy.category
ORDER  BY AVG(cy.revenue) DESC;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_category CHAR DEFAULT 'Anti Aging' PROMPT 'Category to open up (default Anti Aging): '
PROMPT

COLUMN rnk        HEADING 'RANK'                 FORMAT 9990
COLUMN service    HEADING 'SERVICE'              FORMAT A32
COLUMN yrs        HEADING 'YRS'                  FORMAT 90
COLUMN avg_custs  HEADING 'AVG CUSTOMERS|PER YEAR' FORMAT 99,990
COLUMN avg_spend  HEADING 'AVG SPEND|PER CUST'   FORMAT 9,990.00
COLUMN list_price HEADING 'LIST PRICE|(CURRENT)' FORMAT 9,990.00
COLUMN avg_disc   HEADING 'AVG DISCOUNT|PER YEAR' FORMAT 999,990
COLUMN avg_rev    HEADING 'AVG REVENUE|PER YEAR' FORMAT 9,999,990

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF avg_custs avg_spend list_price avg_disc avg_rev ON REPORT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - B. SERVICES IN &p_category, THE AVERAGE YEAR' SKIP 1 -
       CENTER 'PER TRADING YEAR, &p_from - &p_to  (DRILL-DOWN)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

WITH svc_year AS (
    SELECT s.serv_ID              AS serv_id,
           MAX(s.serv_name)       AS service,
           d.cal_year             AS cal_year,
           SUM(f.serv_net_amt)    AS revenue,
           COUNT(DISTINCT c.cus_ID) AS custs,
           SUM(f.serv_discount_amt) AS discount
    FROM   reservation_fact f
    JOIN   service_dim  s ON s.service_key  = f.service_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   date_dim     d ON d.date_key     = f.date_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    AND    UPPER(s.serv_category) LIKE '%' || UPPER(TRIM('&p_category')) || '%'
    GROUP  BY s.serv_ID, d.cal_year
),
svc_price AS (
    SELECT serv_ID, serv_price
    FROM   service_dim
    WHERE  is_current_flag = 'Y'
)
SELECT RANK() OVER (ORDER BY AVG(sy.revenue) DESC)          AS rnk,
       MAX(sy.service)                                      AS service,
       COUNT(*)                                             AS yrs,
       AVG(sy.custs)                                        AS avg_custs,
       AVG(sy.revenue / NULLIF(sy.custs, 0))                AS avg_spend,
       MAX(sp.serv_price)                                   AS list_price,
       AVG(sy.discount)                                     AS avg_disc,
       AVG(sy.revenue)                                      AS avg_rev
FROM   svc_year sy
JOIN   svc_price sp ON sp.serv_ID = sy.serv_id
GROUP  BY sy.serv_id
ORDER  BY AVG(sy.revenue) DESC;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_service CHAR DEFAULT 'Microneedling' PROMPT 'Service to open up (default Microneedling): '
PROMPT

COLUMN service     HEADING 'SERVICE'            FORMAT A32
COLUMN period      HEADING 'YEAR'               FORMAT A9
COLUMN custs       HEADING 'CUSTOMERS'          FORMAT 99,990
COLUMN cust_growth HEADING 'CUSTOMER|GROWTH %'  FORMAT S990.9
COLUMN spend       HEADING 'SPEND|PER CUST'     FORMAT 9,990.00
COLUMN price       HEADING 'PRICE|PER VISIT'    FORMAT 9,990.00
COLUMN discount    HEADING 'DISCOUNT|(RM)'      FORMAT 999,990
COLUMN revenue     HEADING 'REVENUE|(RM)'       FORMAT 9,999,990
COLUMN rev_growth  HEADING 'REVENUE|GROWTH %'   FORMAT S990.9

BREAK ON service SKIP 1
COMPUTE AVG LABEL 'AVG/YEAR' OF custs cust_growth spend price discount revenue rev_growth ON service

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - C. &p_service YEAR BY YEAR' SKIP 1 -
       CENTER 'THE YEARS BEHIND THE AVERAGE, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

WITH svc_year AS (
    SELECT s.serv_ID               AS serv_id,
           MAX(s.serv_name)        AS service,
           d.cal_year              AS cal_year,
           SUM(f.serv_net_amt)     AS revenue,
           COUNT(DISTINCT c.cus_ID) AS custs,
           COUNT(*)                AS bookings,
           SUM(f.serv_discount_amt) AS discount
    FROM   reservation_fact f
    JOIN   service_dim  s ON s.service_key  = f.service_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   date_dim     d ON d.date_key     = f.date_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    GROUP  BY s.serv_ID, d.cal_year
)
SELECT sy.service                                           AS service,
       TO_CHAR(sy.cal_year)                                 AS period,
       sy.custs                                             AS custs,
       (sy.custs - LAG(sy.custs) OVER (PARTITION BY sy.serv_id
                                       ORDER BY sy.cal_year))
         / NULLIF(LAG(sy.custs) OVER (PARTITION BY sy.serv_id
                                      ORDER BY sy.cal_year), 0) * 100
                                                            AS cust_growth,
       sy.revenue / NULLIF(sy.custs, 0)                     AS spend,
       sy.revenue / NULLIF(sy.bookings, 0)                  AS price,
       sy.discount                                          AS discount,
       sy.revenue                                           AS revenue,
       (sy.revenue - LAG(sy.revenue) OVER (PARTITION BY sy.serv_id
                                           ORDER BY sy.cal_year))
         / NULLIF(LAG(sy.revenue) OVER (PARTITION BY sy.serv_id
                                        ORDER BY sy.cal_year), 0) * 100
                                                            AS rev_growth
FROM   svc_year sy
WHERE  UPPER(sy.service) LIKE '%' || UPPER(TRIM('&p_service')) || '%'
ORDER  BY sy.service, sy.cal_year;

PROMPT
PROMPT +==========================================================+
PROMPT |   END OF SERVICE REVENUE AVERAGE  REPORT                 |
PROMPT +==========================================================+
PROMPT

TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE p_from
UNDEFINE p_to
UNDEFINE p_category
UNDEFINE p_service
SET FEEDBACK ON
SET VERIFY ON
SET SQLBLANKLINES OFF
