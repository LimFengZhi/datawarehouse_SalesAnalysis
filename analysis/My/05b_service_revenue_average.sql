-- ===================================================================
-- 05b_service_revenue_average.sql
-- GLOW BEAUTY - SERVICE REVENUE: THE AVERAGE YEAR
--   the same service business as report 05, measured a different
--   way. 05 prints every year across the page and totals them; this
--   one collapses the period into ONE average year, so parts of the
--   menu that arrived late are not punished for having traded fewer
--   years (Microneedling and Scalp Detox only opened 2021-04-01).
--
-- THE DRILL PATH
--   1. SERVICE CATEGORIES   all seven, one row each, on the four
--                           averages below
--   2. INSIDE ONE CATEGORY  every service in the category you pick,
--                           the same four averages
--   3. ONE SERVICE, YEAR    pick a service off the section 2 list and
--      BY YEAR              see the years its averages were taken
--                           over. Its AVG/YEAR row reproduces that
--                           service's row in section 2 exactly -
--                           that is the check that the averages are
--                           honest.
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\05b_service_revenue_average.sql
--
-- PARAMETERS (prompted; every one carries a DEFAULT, so Enter through)
--   start year / end year   the analysis period (data runs 2019-2025)
--   category                the category section 2 opens up, matched
--                           on any part of the name (default
--                           'Anti Aging', the biggest earner).
--                           Case-insensitive, so 'anti' finds it.
--   service                 the service section 3 opens up, matched
--                           the same way (default 'Microneedling',
--                           the run-rate winner). The match is a
--                           LIKE, so a loose word such as 'facial'
--                           returns SEVERAL services - each gets its
--                           own block and its own AVG/YEAR row.
--
-- THE MEASURES  (all of them per YEAR, all averaged over the
--                 years the row actually traded)
--   AVG CUSTOMERS      distinct cus_ID counted WITHIN each year, then
--                      averaged. Counting within the year is what
--                      makes this addable-safe: a customer who books
--                      in 2023 and 2024 is one customer in each of
--                      those years, and the average is still a
--                      truthful "people per year".
--   AVG SPEND/CUST     each year's revenue / that year's customers,
--                      then averaged. NOT total revenue / total
--                      customers - that would double-count the
--                      loyal ones.
--   PRICE PER VISIT    (sections 2 and 3) revenue / bookings - the
--                      REALISED price, after discount, of one visit.
--                      Not the menu price: the list price would be a
--                      constant down section 3 and would hide both
--                      the discounting and the 2025 SCD2 rise. Divide
--                      SPEND PER CUST by it and you get visits per
--                      customer, which is why the two sit together.
--   AVG REVENUE/YEAR   the ranking measure. Revenue per trading year.
--   AVG DISCOUNT/YEAR  the whole year's serv_discount_amt added up,
--                      then averaged over the years - the money given
--                      away per year, in the same unit as AVG
--                      REVENUE/YEAR so the two can be read against
--                      each other. Revenue is already NET of it, so
--                      revenue + discount is what the menu price
--                      would have brought in at full list.
--   CUSTOMER GROWTH %  (section 3 only) this year's customers against
--   REVENUE GROWTH %   last year's, and the same for revenue - LAG()
--                      over the service's own years. The first year
--                      of any service is blank because there is
--                      nothing to compare it with, and the AVG/YEAR
--                      row therefore averages one fewer value than
--                      the rows above it. A service that launched
--                      mid-period compares against its own first
--                      trading year, not against a year of zero.
--   YRS                how many years the average covers. A row with
--                      fewer years is a late arrival, not a failure.
--
-- WHY AVERAGE AND NOT TOTAL
--   Totals reward age. Microneedling has earned less than Gold
--   Radiance over 2019-2025 only because it did not exist until
--   April 2021; per trading year it is the strongest service on the
--   Anti Aging menu. Report 05 shows the totals; this one shows the
--   run rate. Use 05 to say what the period earned, 05b to say what
--   the menu is worth going forward.
--
-- OLAP TECHNIQUES USED
--   CTE (WITH)         the fact is read once at year grain, then
--                      averaged - the year grain is also section 3
--   AVG over a
--     derived grain    average-of-yearly-values, not one big ratio
--   RANK               orders the rows by avg revenue per year
--   COUNT(*) AS yrs    the number of years behind each average
--   LAG                section 3's year-on-year growth, partitioned
--                      by service so a loose match never compares one
--                      service against another
--   COMPUTE AVG        section 3's AVG/YEAR row, which must match
--                      the category's row in section 1
--
-- CONVENTIONS (the Fz house rules)
--   revenue = serv_net_amt, never serv_total_amt (that includes SST);
--   'Completed' only; service_dim and customer_dim are SCD2, so both
--   are grouped on their NATURAL keys (serv_ID, cus_ID).
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
SET SQLBLANKLINES ON

PROMPT
ACCEPT p_from CHAR DEFAULT 2019 PROMPT 'Start year (default 2019): '
ACCEPT p_to   CHAR DEFAULT 2025 PROMPT 'End year   (default 2025): '
PROMPT


-- ###################################################################
-- SECTION 1 - THE SEVEN CATEGORIES ON THE AVERAGE YEAR
-- Ranked on avg revenue per year. Read the four columns together:
-- a category can be big because many people buy it (customers) or
-- because the few who do spend heavily (spend per customer), and
-- the two are opposite ends of this menu.
-- ###################################################################
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
       CENTER 'GLOW BEAUTY - 1. SERVICE CATEGORIES, THE AVERAGE YEAR' SKIP 1 -
       CENTER 'PER-YEAR RUN RATE, &p_from - &p_to' SKIP 1 -
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


-- ###################################################################
-- SECTION 2 - THE SERVICES INSIDE ONE CATEGORY, AVERAGE YEAR
-- The same averages one level down, without the share column: a
-- service's share of its category is not comparable between rows
-- here, because a mid-period launch averages its share over its own
-- trading years only. Rank on the run rate instead, and use report
-- 05 if you need shares that add up.
-- AVG DISCOUNT is the year's giveaway on that one service, averaged:
-- read it against AVG REVENUE/YEAR to see what share of the list
-- price never arrived.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_category CHAR DEFAULT 'Anti Aging' PROMPT 'Category to open up (default Anti Aging): '
PROMPT

COLUMN rnk       HEADING 'RANK'                 FORMAT 9990
COLUMN service   HEADING 'SERVICE'              FORMAT A32
COLUMN yrs       HEADING 'YRS'                  FORMAT 90
COLUMN avg_custs HEADING 'AVG CUSTOMERS|PER YEAR' FORMAT 99,990
COLUMN avg_spend HEADING 'AVG SPEND|PER CUST'   FORMAT 9,990.00
COLUMN avg_price HEADING 'AVG PRICE|PER VISIT'  FORMAT 9,990.00
COLUMN avg_disc  HEADING 'AVG DISCOUNT|PER YEAR' FORMAT 999,990
COLUMN avg_rev   HEADING 'AVG REVENUE|PER YEAR' FORMAT 9,999,990

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF avg_custs avg_spend avg_price avg_disc avg_rev ON REPORT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. SERVICES IN &p_category, THE AVERAGE YEAR' SKIP 1 -
       CENTER 'PER-YEAR RUN RATE, &p_from - &p_to  (DRILL-DOWN)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

WITH svc_year AS (
    SELECT s.serv_ID              AS serv_id,
           MAX(s.serv_name)       AS service,
           d.cal_year             AS cal_year,
           SUM(f.serv_net_amt)    AS revenue,
           COUNT(DISTINCT c.cus_ID) AS custs,
           SUM(f.serv_discount_amt) AS discount,
           COUNT(*)               AS bookings
    FROM   reservation_fact f
    JOIN   service_dim  s ON s.service_key  = f.service_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   date_dim     d ON d.date_key     = f.date_key
    WHERE  f.res_status = 'Completed'
    AND    d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    AND    UPPER(s.serv_category) LIKE '%' || UPPER(TRIM('&p_category')) || '%'
    GROUP  BY s.serv_ID, d.cal_year
)
SELECT RANK() OVER (ORDER BY AVG(sy.revenue) DESC)          AS rnk,
       MAX(sy.service)                                      AS service,
       COUNT(*)                                             AS yrs,
       AVG(sy.custs)                                        AS avg_custs,
       AVG(sy.revenue / NULLIF(sy.custs, 0))                AS avg_spend,
       AVG(sy.revenue / NULLIF(sy.bookings, 0))             AS avg_price,
       AVG(sy.discount)                                     AS avg_disc,
       AVG(sy.revenue)                                      AS avg_rev
FROM   svc_year sy
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
       CENTER 'GLOW BEAUTY - 3. &p_service YEAR BY YEAR' SKIP 1 -
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
PROMPT Report Completed
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
