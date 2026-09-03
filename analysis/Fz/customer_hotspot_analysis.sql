-- ===================================================================
-- 03_customer_hotspot.sql
-- GLOW BEAUTY - CUSTOMER HOTSPOTS: WHERE THE BUYERS LIVE
--   customer home states ranked by spend, then the cities with
--   proven demand and no shop - the expansion candidates
--
-- THE DRILL PATH
--   1. STATE   sales by the customer's HOME state, ranked
--   2. CITY    pick a state and see only the cities where Glow Beauty
--              has NO shop - the expansion candidates
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\03_customer_hotspot.sql
--
-- PARAMETERS (prompted; every one carries a DEFAULT)
--   start year / end year   the analysis period (data runs 2019-2025)
--   state                   the state section 2 opens up, matched on any
--                           part of the name (default Selangor)
--
-- ===================================================================
-- THE POINT OF THIS REPORT
-- ===================================================================
-- Every other report starts from the SHOP. This one starts from the
-- PERSON: customer_dim.cus_state / cus_city say where the buyer lives,
-- which is not the same as where they bought. Since 2022 the chain
-- fulfils online orders from any branch, so a customer's money can
-- appear at a shop hundreds of kilometres from home.
--
-- That gap is the whole analysis. A city with customers and revenue but
-- NO SHOP is an expansion candidate - the demand is already proven and
-- is currently being served from somewhere else. Section 2 lists those
-- cities and nothing else.
--
-- MEASURES  (both are AVERAGES PER YEAR, so a 3-year window and a
--            7-year window are directly comparable)
--   Avg revenue/yr    order_net_amt + serv_net_amt (net of discount,
--                     SST excluded, 'Completed' only), summed within
--                     each year, then averaged over the years
--   Avg customers/yr  COUNT(DISTINCT cus_ID) WITHIN each year, then
--                     averaged - never one distinct count over the
--                     whole period (a person active in 3 years is one
--                     customer per year, not one third), and never
--                     customer_key (SCD2 - one person, several rows)
--   Per head          avg revenue/yr / avg customers/yr - what one
--                     customer is worth in a typical year
--   Product / Service the same average year split by fact. PRODUCT
--                     revenue has been fulfillable ONLINE since 2022,
--                     so a shopless city's product money is already
--                     served; SERVICE revenue requires the customer
--                     to TRAVEL to a branch - in a shopless city that
--                     is proven demand surviving real friction, the
--                     strongest expansion evidence on the page. Quote
--                     the service RM, never the service SHARE: the
--                     product/service mix is flat (~21 % service)
--                     everywhere by construction, so the ratio does
--                     not separate cities
--
-- OLAP TECHNIQUES USED
--   CTE (WITH)         both sections
--   UNION ALL          the two revenue facts drilled across onto one
--                      customer grain
--   RANK               both sections
--   Ratio to report    share of chain sales / share of state sales
--   NOT EXISTS         section 2 - keeps only the cities with no shop
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

PROMPT
ACCEPT p_from CHAR DEFAULT 2023 PROMPT 'Start year (default 2023): '
ACCEPT p_to   CHAR DEFAULT 2025 PROMPT 'End year   (default 2025): '
PROMPT


-- ###################################################################
-- SECTION 1 - WHERE THE BUYERS LIVE, BY STATE
-- Ranked on AVG REVENUE PER YEAR. The BRANCHES column counts the
-- branches Glow Beauty actually has in that state, so a state can be
-- read against its own branch footprint straight away.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. CUSTOMER HOTSPOTS BY HOME STATE' SKIP 1 -
       CENTER 'WHERE THE BUYERS LIVE, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk       HEADING 'RANK'               FORMAT 9990
COLUMN cus_state HEADING 'CUSTOMER HOME STATE' FORMAT A34
COLUMN shops     HEADING 'BRANCHES'           FORMAT 990
COLUMN cities    HEADING 'CITIES|LIVED IN'    FORMAT 990
COLUMN custs     HEADING 'AVG CUSTOMERS|PER YEAR' FORMAT 99,990
COLUMN sales     HEADING 'AVG REVENUE|PER YEAR (RM)' FORMAT 99,999,990
COLUMN prod_rev  HEADING 'AVG PRODUCT|REV/YR (RM)' FORMAT 99,999,990
COLUMN serv_rev  HEADING 'AVG SERVICE|REV/YR (RM)' FORMAT 9,999,990
COLUMN per_head  HEADING 'REVENUE PER|CUSTOMER' FORMAT 9,990.00
COLUMN pct_share HEADING 'SHARE OF|REVENUE'   FORMAT A8

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF custs sales prod_rev serv_rev per_head ON REPORT

WITH spend AS (
    -- both revenue facts on one customer grain, year kept for the
    -- per-year averaging
    SELECT c.cus_ID, c.cus_city, c.cus_state, d.cal_year, x.amt, x.src
    FROM   (SELECT customer_key, date_key, order_net_amt AS amt,
                   'P' AS src
            FROM   order_fact WHERE order_status = 'Completed'
            UNION ALL
            SELECT customer_key, date_key, serv_net_amt, 'S'
            FROM   reservation_fact WHERE res_status = 'Completed') x
    JOIN   date_dim     d ON d.date_key     = x.date_key
    JOIN   customer_dim c ON c.customer_key = x.customer_key
    WHERE  d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
),
by_state_year AS (
    -- one row per state per YEAR: customers counted DISTINCT within
    -- the year (a person active in three years counts once per year)
    SELECT cus_state, cal_year,
           COUNT(DISTINCT cus_ID) AS custs,
           SUM(amt)               AS sales,
           SUM(CASE WHEN src = 'P' THEN amt ELSE 0 END) AS prod_rev,
           SUM(CASE WHEN src = 'S' THEN amt ELSE 0 END) AS serv_rev
    FROM   spend
    GROUP  BY cus_state, cal_year
),
by_state AS (
    -- collapse the years into ONE average year per state. CITIES
    -- LIVED IN stays a whole-period distinct count (a city is not
    -- more of a city for appearing in three years).
    SELECT y.cus_state,
           AVG(y.custs)                 AS custs,
           AVG(y.sales)                 AS sales,
           AVG(y.prod_rev)              AS prod_rev,
           AVG(y.serv_rev)              AS serv_rev,
           (SELECT COUNT(DISTINCT s.cus_city) FROM spend s
            WHERE  s.cus_state = y.cus_state) AS cities
    FROM   by_state_year y
    GROUP  BY y.cus_state
),
shops AS (
    -- count branches by br_name (branch_dim is not SCD2 any more -
    -- one row per branch, the DISTINCT is just belt and braces)
    SELECT br_state, COUNT(DISTINCT br_name) AS shops
    FROM   branch_dim
    GROUP  BY br_state
)
SELECT RANK() OVER (ORDER BY s.sales DESC) AS rnk,
       s.cus_state,
       NVL(h.shops, 0) AS shops,
       s.cities,
       s.custs,
       s.sales,
       s.prod_rev,
       s.serv_rev,
       s.sales / NULLIF(s.custs, 0) AS per_head,
       TO_CHAR(ROUND(s.sales / SUM(s.sales) OVER () * 100, 1), '990.9') || '%' AS pct_share
FROM   by_state s
LEFT   JOIN shops h ON h.br_state = s.cus_state
ORDER  BY rnk;


-- ###################################################################
-- SECTION 2 - THE SHOPLESS CITIES INSIDE ONE STATE
-- Only cities with NO branch appear here: real customers and real
-- revenue that the chain is currently serving from somewhere else,
-- both stated as an AVERAGE YEAR like section 1. AVG SERVICE REV is
-- the line to read: products ship online, but every service ringgit
-- from a shopless city is someone TRAVELLING to another town.
-- SHARE OF STATE is measured against the state's WHOLE sales, branch
-- cities included, so it says how much of the state is being served
-- without a shop - not just how these towns compare to each other.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
ACCEPT p_state CHAR DEFAULT 'Selangor' PROMPT 'State to open up (default Selangor): '
PROMPT

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. CITIES IN &p_state WITH NO BRANCH' SKIP 1 -
       CENTER 'PROVEN DEMAND, NO BRANCH, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk      HEADING 'RANK'               FORMAT 9990
COLUMN cus_city HEADING 'CUSTOMER HOME CITY' FORMAT A24
COLUMN custs    HEADING 'AVG CUSTOMERS|PER YEAR' FORMAT 99,990
COLUMN sales    HEADING 'AVG REVENUE|PER YEAR (RM)' FORMAT 9,999,990
COLUMN prod_rev HEADING 'AVG PRODUCT|REV/YR (RM)' FORMAT 9,999,990
COLUMN serv_rev HEADING 'AVG SERVICE|REV/YR (RM)' FORMAT 999,990
COLUMN per_head HEADING 'REVENUE PER|CUSTOMER' FORMAT 9,990.00
COLUMN pct_share HEADING 'SHARE OF|STATE'    FORMAT A8

BREAK ON REPORT
COMPUTE AVG LABEL 'AVG' OF custs sales prod_rev serv_rev per_head ON REPORT

WITH spend AS (
    SELECT c.cus_ID, c.cus_city, d.cal_year, x.amt, x.src
    FROM   (SELECT customer_key, date_key, order_net_amt AS amt,
                   'P' AS src
            FROM   order_fact WHERE order_status = 'Completed'
            UNION ALL
            SELECT customer_key, date_key, serv_net_amt, 'S'
            FROM   reservation_fact WHERE res_status = 'Completed') x
    JOIN   date_dim     d ON d.date_key     = x.date_key
    JOIN   customer_dim c ON c.customer_key = x.customer_key
    WHERE  d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    AND    UPPER(c.cus_state) LIKE '%' || UPPER(TRIM('&p_state')) || '%'
),
by_city_year AS (
    SELECT cus_city, cal_year,
           COUNT(DISTINCT cus_ID) AS custs,
           SUM(amt)               AS sales,
           SUM(CASE WHEN src = 'P' THEN amt ELSE 0 END) AS prod_rev,
           SUM(CASE WHEN src = 'S' THEN amt ELSE 0 END) AS serv_rev
    FROM   spend
    GROUP  BY cus_city, cal_year
),
by_city AS (
    SELECT cus_city,
           AVG(custs)    AS custs,
           AVG(sales)    AS sales,
           AVG(prod_rev) AS prod_rev,
           AVG(serv_rev) AS serv_rev
    FROM   by_city_year
    GROUP  BY cus_city
),
shared AS (
    -- the share is worked out BEFORE the shopless filter, so it stays a
    -- share of the whole state rather than of the survivors
    SELECT cus_city, custs, sales, prod_rev, serv_rev,
           sales / SUM(sales) OVER () * 100 AS pct_of_state
    FROM   by_city
)
SELECT RANK() OVER (ORDER BY sales DESC) AS rnk,
       cus_city,
       custs,
       sales,
       prod_rev,
       serv_rev,
       sales / NULLIF(custs, 0) AS per_head,
       TO_CHAR(ROUND(pct_of_state, 1), '990.9') || '%' AS pct_share
FROM   shared
-- deliberately br_city, NOT br_name: this compares a branch LOCATION
-- with a customer's home city ('Glow Beauty Ipoh' would never equal
-- 'Ipoh'). A city can hold several branches - NOT EXISTS only asks
-- whether there is none at all
WHERE  NOT EXISTS (SELECT 1 FROM branch_dim b
                   WHERE UPPER(b.br_city) = UPPER(shared.cus_city))
ORDER  BY rnk;

PROMPT
PROMPT Report Completed
PROMPT

-- ===================================================================
-- tidy up so the next script starts clean
-- ===================================================================
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE p_from
UNDEFINE p_to
UNDEFINE p_state
SET FEEDBACK ON
SET VERIFY ON
