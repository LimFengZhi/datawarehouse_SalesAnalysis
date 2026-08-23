-- ===================================================================
-- 03b_customer_hotspot.sql
-- GLOW BEAUTY - CUSTOMER HOTSPOTS: WHERE THE BUYERS LIVE
--
-- THE DRILL PATH
--   1. STATE   sales by the customer's HOME state, ranked
--   2. CITY    pick a state and see only the cities where Glow Beauty
--              has NO shop - the expansion candidates
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @analysis\Fz\03b_customer_hotspot.sql
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
-- MEASURES
--   Sales      order_fact.order_net_amt + reservation_fact.serv_net_amt
--              - what the customer actually paid, net of discount and
--              excluding the 6 % SST, 'Completed' rows only. Both facts
--              carry customer_key, so a person's whole spend is counted.
--   Customers  COUNT(DISTINCT cus_ID) - the natural key, NEVER
--              customer_key: customer_dim is SCD2, so one person can
--              own several surrogate rows and would be counted twice.
--   Per head   sales / customers
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
ACCEPT p_from CHAR DEFAULT 2019 PROMPT 'Start year (default 2019): '
ACCEPT p_to   CHAR DEFAULT 2025 PROMPT 'End year   (default 2025): '
PROMPT


-- ###################################################################
-- SECTION 1 - WHERE THE BUYERS LIVE, BY STATE
-- Ranked on total sales. The SHOPS column counts the branches Glow
-- Beauty actually has in that state, so a state can be read against
-- its own shop footprint straight away.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. CUSTOMER HOTSPOTS BY HOME STATE' SKIP 1 -
       CENTER 'WHERE THE BUYERS LIVE, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk       HEADING 'RANK'               FORMAT 990
COLUMN cus_state HEADING 'CUSTOMER HOME STATE' FORMAT A34
COLUMN shops     HEADING 'SHOPS'              FORMAT 990
COLUMN cities    HEADING 'CITIES|LIVED IN'    FORMAT 990
COLUMN custs     HEADING 'CUSTOMERS'          FORMAT 99,990
COLUMN sales     HEADING 'SALES (RM)'         FORMAT 999,999,990
COLUMN per_head  HEADING 'SALES PER|CUSTOMER' FORMAT 9,990.00
COLUMN pct_share HEADING 'SHARE OF|SALES'     FORMAT A8

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF custs sales ON REPORT

WITH spend AS (
    -- both revenue facts on one customer grain
    SELECT c.cus_ID, c.cus_city, c.cus_state, x.amt
    FROM   (SELECT customer_key, date_key, order_net_amt AS amt
            FROM   order_fact WHERE order_status = 'Completed'
            UNION ALL
            SELECT customer_key, date_key, serv_net_amt
            FROM   reservation_fact WHERE res_status = 'Completed') x
    JOIN   date_dim     d ON d.date_key     = x.date_key
    JOIN   customer_dim c ON c.customer_key = x.customer_key
    WHERE  d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
),
by_state AS (
    SELECT cus_state,
           COUNT(DISTINCT cus_ID)   AS custs,
           COUNT(DISTINCT cus_city) AS cities,
           SUM(amt)                 AS sales
    FROM   spend
    GROUP  BY cus_state
),
shops AS (
    SELECT br_state, COUNT(DISTINCT br_city) AS shops
    FROM   branch_dim
    GROUP  BY br_state
)
SELECT RANK() OVER (ORDER BY s.sales DESC) AS rnk,
       s.cus_state,
       NVL(h.shops, 0) AS shops,
       s.cities,
       s.custs,
       s.sales,
       s.sales / NULLIF(s.custs, 0) AS per_head,
       TO_CHAR(ROUND(s.sales / SUM(s.sales) OVER () * 100, 1), '990.9') || '%' AS pct_share
FROM   by_state s
LEFT   JOIN shops h ON h.br_state = s.cus_state
ORDER  BY rnk;


-- ###################################################################
-- SECTION 2 - THE SHOPLESS CITIES INSIDE ONE STATE
-- Only cities with NO branch appear here: real customers and real
-- revenue that the chain is currently serving from somewhere else.
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
       CENTER 'GLOW BEAUTY - 2. CITIES IN &p_state WITH NO SHOP' SKIP 1 -
       CENTER 'PROVEN DEMAND, NO BRANCH, &p_from - &p_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'Report Generated on: ' _DATE -
       RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk      HEADING 'RANK'               FORMAT 990
COLUMN cus_city HEADING 'CUSTOMER HOME CITY' FORMAT A24
COLUMN custs    HEADING 'CUSTOMERS'          FORMAT 99,990
COLUMN sales    HEADING 'SALES (RM)'         FORMAT 99,999,990
COLUMN per_head HEADING 'SALES PER|CUSTOMER' FORMAT 9,990.00
COLUMN pct_share HEADING 'SHARE OF|STATE'    FORMAT A8

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF custs sales ON REPORT

WITH spend AS (
    SELECT c.cus_ID, c.cus_city, x.amt
    FROM   (SELECT customer_key, date_key, order_net_amt AS amt
            FROM   order_fact WHERE order_status = 'Completed'
            UNION ALL
            SELECT customer_key, date_key, serv_net_amt
            FROM   reservation_fact WHERE res_status = 'Completed') x
    JOIN   date_dim     d ON d.date_key     = x.date_key
    JOIN   customer_dim c ON c.customer_key = x.customer_key
    WHERE  d.cal_year BETWEEN TO_NUMBER('&p_from') AND TO_NUMBER('&p_to')
    AND    UPPER(c.cus_state) LIKE '%' || UPPER(TRIM('&p_state')) || '%'
),
by_city AS (
    SELECT cus_city,
           COUNT(DISTINCT cus_ID) AS custs,
           SUM(amt)               AS sales
    FROM   spend
    GROUP  BY cus_city
),
shared AS (
    -- the share is worked out BEFORE the shopless filter, so it stays a
    -- share of the whole state rather than of the survivors
    SELECT cus_city, custs, sales,
           sales / SUM(sales) OVER () * 100 AS pct_of_state
    FROM   by_city
)
SELECT RANK() OVER (ORDER BY sales DESC) AS rnk,
       cus_city,
       custs,
       sales,
       sales / NULLIF(custs, 0) AS per_head,
       TO_CHAR(ROUND(pct_of_state, 1), '990.9') || '%' AS pct_share
FROM   shared
-- branch_dim is SCD2, so a city can hold several rows - NOT EXISTS only
-- asks whether there is none at all
WHERE  NOT EXISTS (SELECT 1 FROM branch_dim b
                   WHERE UPPER(b.br_city) = UPPER(shared.cus_city))
ORDER  BY rnk;

PROMPT
PROMPT +==========================================================+
PROMPT |        END OF CUSTOMER HOTSPOT REPORT                    |
PROMPT +==========================================================+
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
