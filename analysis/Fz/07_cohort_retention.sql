-- ===================================================================
-- 07_cohort_retention.sql
-- CUSTOMER ANALYSIS - COHORT RETENTION: DO THE CUSTOMERS WE WIN
--                     KEEP BUYING, AND IS THAT GETTING BETTER OR WORSE?
--   Every customer is put in the COHORT of the month of his / her FIRST
--   completed product order (the acquisition month) and followed month
--   by month after that. The walk is a business one, not a geographic
--   one: WHEN were they won (cohort years -> the months of one year)
--   -> WHO stays (loyalty tier, the first basket) -> WHERE they were
--   won (acquiring branch) -> ONE cohort month by month against the
--   same month one year earlier.
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Fz\07_cohort_retention.sql
--
-- PARAMETERS (the cohort-year range at the start; the rest ONE AT A
-- TIME, each after the table it refers to has printed)
--   first / last cohort year   at the start    defaults 2019 and 2025
--   cohort year                after section 1 default 2024
--   cohort month (1-12)        after section 5 default 11 (November)
--   A year outside the range / a month with no cohort falls back to
--   the biggest cohort of that level. The spool is paused around every
--   prompt, so the output file holds only tables.
--
-- WHAT IT ANSWERS
--   1. Of the customers won in a year, how many are still buying one,
--      three, six, twelve months later - and is that curve rising or
--      falling year after year (the retention health check)?
--   2. Which customers stick: does the loyalty tier or the product they
--      bought first predict who comes back?
--   3. Which branches win customers that stay, and do those customers
--      keep shopping at the branch that won them?
--   4. In which month of the year are the "good" cohorts won (11.11 /
--      festive shoppers vs quiet-month shoppers), and how does one
--      cohort's life compare with its year-ago twin month by month?
--
-- THE CUBE
--   fact      order_fact rolled up to ONE ROW PER COMPLETED ORDER
--             (order_ID); service visits are NOT counted (a customer is
--             "retained" here when he / she buys PRODUCTS again - add a
--             UNION ALL on reservation_fact to the ord block if visits
--             should count as activity)
--   dims      date_dim (cal_date -> calendar month), customer_dim
--             (cus_ID, loyalty tier of the version on the order date),
--             branch_dim (br_ID / br_city / br_state), product_dim
--             (product_category)
--   measures  COHORT (acquisition month) = calendar month of the
--                customer's first completed order in the warehouse
--             NEW CUSTOMERS  = size of the cohort
--             M+k ACTIVE %   = % of the cohort with at least one
--                completed order in the k-th calendar month after the
--                acquisition month (k = 1..12); a customer counts once
--                per month however many orders were placed
--             BOUGHT AGAIN <= kM % = % of the cohort with at least one
--                further order within k months (cumulative)
--             FIRST YEAR     = months 0..11 (the acquisition month plus
--                the next eleven): ORDERS and NET RM per customer,
--                of which REPEAT RM = months 1..11 only
--             ACTIVE IN YEAR 2 % = % with an order in months 12..23
--             Net (RM)       = order_total_amt - order_tax_amt (paid,
--                no tax), Completed only
--             HORIZON        = the last calendar month with an order
--
-- READ THIS BEFORE QUOTING A RETENTION RATE
--   - RIGHT-CENSORING: a cell whose month lies after the horizon prints
--     BLANK, not 0 - a Nov 2025 cohort has an M+1 but no M+2. Every
--     rate is computed on the customers whose month k IS observable
--     (so a year row's M+12 % is the M+12 % of the cohorts that already
--     have a 12th month, not diluted by the ones that do not).
--   - LEFT-CENSORING: the warehouse starts on 2018-01-01 and the
--     customer dimension carries no registration date, so a customer
--     who had shopped before 2018 looks "new" in the first month of
--     2018 he / she buys. The 2018 cohorts are therefore far bigger
--     than a real year and retain far better (they are the old base).
--     That is why the range defaults to 2019-2025; type 2018 to see it.
--   - A retention rate is a MONTHLY ACTIVITY rate in a business where a
--     customer orders 2-3 times a YEAR: 15-25 % active in any one month
--     is a healthy, loyal base - compare cohorts with each other and
--     with their year-ago twin, do not compare with a subscription
--     product's 90 %.
--
-- WHY GROUP BY cus_ID / br_ID / CATEGORY AND NOT THE SURROGATE KEYS
--   customer_dim, branch_dim and product_dim are SCD Type 2; the
--   natural keys and the category roll the versions together. The tier
--   used is the one in force on the FIRST order (the acquisition tier).
--
-- REPORT SECTIONS  (each one is ONE OLAP operation)
--   1  BY COHORT YEAR      ROLL-UP    active vs new customers per year,
--                                     M+1/3/6/12 %, bought again <=3/6/
--                                     12M %, first-year orders and RM,
--                                     year-2 activity - the trend
--         -> prompt: cohort year
--   2  BY LOYALTY TIER     DICE       the year's cohort cut by the tier
--                                     on the first order
--   3  BY FIRST BASKET     DICE       cut by the category that led the
--                                     first order (the "gateway
--                                     product"), and whether the repeat
--                                     orders stay in that category
--   4  BY ACQUIRING BRANCH DRILL-     cut by the branch of the first
--                          ACROSS     order, ranked by 12-month repeat
--                                     rate; % of repeat orders placed
--                                     at the same branch
--   5  BY COHORT MONTH     DRILL-DOWN year -> its 12 monthly cohorts,
--                                     the classic triangle: M+1..M+12
--                                     across, plus a pooled year row
--         -> prompt: cohort month
--   6  ONE COHORT, MONTH   DRILL-DOWN the chosen cohort followed month
--      BY MONTH                       by month (up to 36): active %,
--                                     the year-ago twin's % in the same
--                                     month offset, difference, orders,
--                                     RM, cumulative RM per customer won
--
-- WHAT TO LOOK FOR  (defaults 2019-2025 > 2024 > November,
--   revision-3 data; the shapes below follow from how the data was
--   generated - check the exact figures on your own run)
--   - Section 1: NEW % OF ACTIVE falls year after year as the base
--     accumulates (the chain keeps most of what it wins - roughly half
--     of all customers never lapse); the 2020 and 2021 cohorts are the
--     smallest (fewer registrations, shops shut) and their M+k months
--     land in lockdowns, so their early-month rates dip; from 2022 the
--     curve should sit back at the 2019 level or above - THAT is the
--     "improving or decaying" answer. M+12 is close to M+6: the decay
--     happens in the first months (the ~45 % of customers who lapse
--     do so within a year or two), after which the curve flattens.
--   - Section 2: the strongest split in the report. Platinum and Gold
--     customers are two to three times as active as Bronze, so every
--     column climbs up the tier ladder (M+1, bought-again, orders and
--     RM in the first year); Bronze is the biggest slice of the cohort
--     (about half) but a far smaller share of the first-year repeat RM.
--   - Section 3: the gateway product does NOT predict loyalty here -
--     the rates are flat across categories to within noise; what
--     differs is the FIRST ORDER RM and the multiple of it that the
--     first year brings back. REPEAT LED BY SAME CAT % is far below
--     100: customers spread across the range after the first buy.
--   - Section 4: branch rates sit within a few points of each other;
--     the Klang Valley branches' 2020-2021 cohorts are the ones hit by
--     the longer lockdowns. REPEAT AT SAME BRANCH % is high (~70 %+):
--     customers stay with the branch that won them - the rest is the
--     spill-over to a nearby branch in the same state.
--   - Section 5: read the triangle DIAGONALLY as well as down - a cell
--     is high when its CALENDAR month is Nov / Dec (festive) and low in
--     Q3, whatever the cohort. The November (11.11) and December
--     cohorts are the biggest of the year; whether they retain worse
--     than a quiet-month cohort is the promo-shopper question - in this
--     data they do not: promo days pull the same customers forward.
--   - Section 6: the twin comparison removes seasonality (same
--     calendar month one year earlier), so DIFF PTS is the pure
--     year-on-year retention change of that cohort month; the CUM NET
--     PER CUSTOMER WON column is the cohort's revenue per acquired
--     customer to date - the number a marketing budget per new customer
--     should be compared with. Try 2020 > 3 (Mar 2020, MCO 1.0) against
--     its 2019 twin, or 2019 > any month, whose twin is a 2018 cohort
--     inflated by the pre-2018 base (see LEFT-CENSORING).
-- ===================================================================

-- reset anything a previous script left behind in this session
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 180
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

-- SQL*Plus caps an ACCEPT prompt at 99 characters - keep it short.
ACCEPT p_from NUMBER DEFAULT 2019 PROMPT 'First cohort year (default 2019; 2018 = warehouse start, see header): '
ACCEPT p_to   NUMBER DEFAULT 2025 PROMPT 'Last cohort year  (default 2025): '

-- ---- values reused in every title ---------------------------------
-- TERMOUT OFF hides these helper queries (only works when the file is
-- run with @, which is how this report is meant to be run).
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

-- clamp the range to the data (2018-2025) and put it the right way round
COLUMN f_from NEW_VALUE f_from NOPRINT
COLUMN f_to   NEW_VALUE f_to   NOPRINT
SELECT TO_CHAR(GREATEST(2018, LEAST(&p_from, &p_to)))  AS f_from,
       TO_CHAR(LEAST(2025, GREATEST(&p_from, &p_to)))  AS f_to
FROM   dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL cohort_retention_output.txt


-- ###################################################################
-- SECTION 1 - RETENTION BY COHORT YEAR
-- OLAP: ROLL-UP of the monthly cohorts to the acquisition YEAR. One
-- row per year of the range: how many customers were active, how many
-- were new, and how the new ones behaved afterwards. Every rate is
-- computed on the customers whose month k is inside the horizon.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. CUSTOMER RETENTION BY COHORT YEAR' SKIP 1 -
       CENTER 'ALL BRANCHES, CUSTOMERS WON &f_from - &f_to  (ROLL-UP OF THE MONTHLY COHORTS)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cyear       HEADING 'COHORT|YEAR'            FORMAT 9999
COLUMN active_cust HEADING 'ACTIVE|CUSTOMERS'       FORMAT 99,990
COLUMN new_cust    HEADING 'NEW|CUSTOMERS'          FORMAT 99,990
COLUMN new_pct     HEADING 'NEW % OF|ACTIVE'        FORMAT 990.0
COLUMN m1_pct      HEADING 'ACTIVE|M+1 %'           FORMAT 990.0
COLUMN m3_pct      HEADING 'ACTIVE|M+3 %'           FORMAT 990.0
COLUMN m6_pct      HEADING 'ACTIVE|M+6 %'           FORMAT 990.0
COLUMN m12_pct     HEADING 'ACTIVE|M+12 %'          FORMAT 990.0
COLUMN r3_pct      HEADING 'BOUGHT|AGAIN|<=3M %'    FORMAT 990.0
COLUMN r6_pct      HEADING 'BOUGHT|AGAIN|<=6M %'    FORMAT 990.0
COLUMN r12_pct     HEADING 'BOUGHT|AGAIN|<=12M %'   FORMAT 990.0
COLUMN am12        HEADING 'MTHS ACTIVE|OF FIRST 12' FORMAT 90.00
COLUMN o12         HEADING 'ORDERS|1ST YEAR|/CUST'  FORMAT 90.00
COLUMN n12         HEADING 'NET RM|1ST YEAR|/CUST'  FORMAT 9,990
COLUMN rep12       HEADING 'OF WHICH|REPEAT RM|/CUST' FORMAT 9,990
COLUMN y2_pct      HEADING 'ACTIVE IN|YEAR 2 %'     FORMAT 990.0

BREAK ON REPORT

WITH ord AS (
    -- ONE ROW PER COMPLETED ORDER: customer, order date, net (no tax)
    SELECT c.cus_ID, f.order_ID,
           MIN(d.cal_date)                          AS cal_date,
           SUM(f.order_total_amt - f.order_tax_amt) AS net
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY c.cus_ID, f.order_ID
),
ok AS (
    -- cohort = month of the customer's first order; k = months after it
    SELECT cus_ID, order_ID, cal_date, net,
           TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM') AS cohort,
           MONTHS_BETWEEN(TRUNC(cal_date, 'MM'),
                          TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM')) AS k
    FROM   ord
),
hz AS (SELECT TRUNC(MAX(cal_date), 'MM') AS horizon FROM ord),
cust AS (
    -- ONE ROW PER CUSTOMER: cohort and the retention flags
    SELECT cus_ID, MIN(cohort) AS cohort,
           MAX(CASE WHEN k = 1  THEN 1 ELSE 0 END)                 AS m1,
           MAX(CASE WHEN k = 3  THEN 1 ELSE 0 END)                 AS m3,
           MAX(CASE WHEN k = 6  THEN 1 ELSE 0 END)                 AS m6,
           MAX(CASE WHEN k = 12 THEN 1 ELSE 0 END)                 AS m12,
           MAX(CASE WHEN k BETWEEN 1 AND 3  THEN 1 ELSE 0 END)     AS r3,
           MAX(CASE WHEN k BETWEEN 1 AND 6  THEN 1 ELSE 0 END)     AS r6,
           MAX(CASE WHEN k BETWEEN 1 AND 12 THEN 1 ELSE 0 END)     AS r12,
           MAX(CASE WHEN k BETWEEN 12 AND 23 THEN 1 ELSE 0 END)    AS y2,
           COUNT(DISTINCT CASE WHEN k BETWEEN 0 AND 11 THEN k END) AS am12,
           SUM(CASE WHEN k BETWEEN 0 AND 11 THEN 1 ELSE 0 END)     AS o12,
           SUM(CASE WHEN k BETWEEN 0 AND 11 THEN net ELSE 0 END)   AS n12,
           SUM(CASE WHEN k BETWEEN 1 AND 11 THEN net ELSE 0 END)   AS rep12
    FROM   ok
    GROUP  BY cus_ID
),
cx AS (
    -- s<k> = 1 when the customer's month k lies inside the horizon
    -- (NULL otherwise, so the customer drops out of that rate)
    SELECT c.*,
           CASE WHEN ADD_MONTHS(c.cohort, 1)  <= h.horizon THEN 1 END AS s1,
           CASE WHEN ADD_MONTHS(c.cohort, 3)  <= h.horizon THEN 1 END AS s3,
           CASE WHEN ADD_MONTHS(c.cohort, 6)  <= h.horizon THEN 1 END AS s6,
           CASE WHEN ADD_MONTHS(c.cohort, 11) <= h.horizon THEN 1 END AS s11,
           CASE WHEN ADD_MONTHS(c.cohort, 12) <= h.horizon THEN 1 END AS s12,
           CASE WHEN ADD_MONTHS(c.cohort, 23) <= h.horizon THEN 1 END AS s23
    FROM   cust c CROSS JOIN hz h
),
active AS (
    -- everybody who ordered in the year, new or old
    SELECT EXTRACT(YEAR FROM cal_date) AS cyear, COUNT(DISTINCT cus_ID) AS active_cust
    FROM   ord
    GROUP  BY EXTRACT(YEAR FROM cal_date)
)
SELECT EXTRACT(YEAR FROM x.cohort)                                    AS cyear,
       MAX(a.active_cust)                                             AS active_cust,
       COUNT(*)                                                       AS new_cust,
       ROUND(COUNT(*) / NULLIF(MAX(a.active_cust), 0) * 100, 1)       AS new_pct,
       ROUND(SUM(x.m1  * x.s1)  / NULLIF(SUM(x.s1),  0) * 100, 1)     AS m1_pct,
       ROUND(SUM(x.m3  * x.s3)  / NULLIF(SUM(x.s3),  0) * 100, 1)     AS m3_pct,
       ROUND(SUM(x.m6  * x.s6)  / NULLIF(SUM(x.s6),  0) * 100, 1)     AS m6_pct,
       ROUND(SUM(x.m12 * x.s12) / NULLIF(SUM(x.s12), 0) * 100, 1)     AS m12_pct,
       ROUND(SUM(x.r3  * x.s3)  / NULLIF(SUM(x.s3),  0) * 100, 1)     AS r3_pct,
       ROUND(SUM(x.r6  * x.s6)  / NULLIF(SUM(x.s6),  0) * 100, 1)     AS r6_pct,
       ROUND(SUM(x.r12 * x.s12) / NULLIF(SUM(x.s12), 0) * 100, 1)     AS r12_pct,
       ROUND(SUM(x.am12  * x.s11) / NULLIF(SUM(x.s11), 0), 2)         AS am12,
       ROUND(SUM(x.o12   * x.s11) / NULLIF(SUM(x.s11), 0), 2)         AS o12,
       ROUND(SUM(x.n12   * x.s11) / NULLIF(SUM(x.s11), 0), 0)         AS n12,
       ROUND(SUM(x.rep12 * x.s11) / NULLIF(SUM(x.s11), 0), 0)         AS rep12,
       ROUND(SUM(x.y2  * x.s23) / NULLIF(SUM(x.s23), 0) * 100, 1)     AS y2_pct
FROM   cx x
LEFT   JOIN active a ON a.cyear = EXTRACT(YEAR FROM x.cohort)
WHERE  EXTRACT(YEAR FROM x.cohort) BETWEEN &f_from AND &f_to
GROUP  BY EXTRACT(YEAR FROM x.cohort)
ORDER  BY 1;

-- ---- prompt 1: which cohort year? (spool paused, helper hidden) ----
SPOOL OFF
ACCEPT p_year NUMBER DEFAULT 2024 PROMPT 'Cohort year to open up (default 2024): '
SET TERMOUT OFF
-- resolve to a year inside the range: exact match first, else the year
-- that won the most customers
COLUMN f_year NEW_VALUE f_year NOPRINT
SELECT TO_CHAR(MAX(cyear) KEEP (DENSE_RANK FIRST ORDER BY miss, n DESC)) AS f_year
FROM (
    SELECT EXTRACT(YEAR FROM cohort) AS cyear, COUNT(*) AS n,
           CASE WHEN EXTRACT(YEAR FROM cohort) = &p_year THEN 0 ELSE 1 END AS miss
    FROM (
        SELECT c.cus_ID, TRUNC(MIN(d.cal_date), 'MM') AS cohort
        FROM   order_fact   f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        WHERE  f.order_status = 'Completed'
        GROUP  BY c.cus_ID
    )
    WHERE  EXTRACT(YEAR FROM cohort) BETWEEN &f_from AND &f_to
    GROUP  BY EXTRACT(YEAR FROM cohort)
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL cohort_retention_output.txt APPEND



-- ###################################################################
-- SECTION 2 - THE COHORT YEAR BY LOYALTY TIER
-- OLAP: DICE cohort year x tier. The tier is the one on the FIRST
-- order (the acquisition tier); FIRST ORDER RM is what that first
-- basket was worth. Same retention columns as section 1, plus the
-- pooled ALL TIERS row (a ROLLUP).
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. THE &f_year COHORT BY LOYALTY TIER' SKIP 1 -
       CENTER 'CUSTOMERS WON IN &f_year, CUT BY THE TIER ON THEIR FIRST ORDER  (DICE)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN tier        HEADING 'TIER'                  FORMAT A10
COLUMN new_cust    HEADING 'NEW|CUSTOMERS'         FORMAT 99,990
COLUMN share_pct   HEADING 'SHARE OF|COHORT %'     FORMAT 990.0
COLUMN first_net   HEADING 'FIRST|ORDER RM'        FORMAT 9,990.00
COLUMN m1_pct      HEADING 'ACTIVE|M+1 %'          FORMAT 990.0
COLUMN m3_pct      HEADING 'ACTIVE|M+3 %'          FORMAT 990.0
COLUMN m6_pct      HEADING 'ACTIVE|M+6 %'          FORMAT 990.0
COLUMN m12_pct     HEADING 'ACTIVE|M+12 %'         FORMAT 990.0
COLUMN r12_pct     HEADING 'BOUGHT|AGAIN|<=12M %'  FORMAT 990.0
COLUMN o12         HEADING 'ORDERS|1ST YEAR|/CUST' FORMAT 90.00
COLUMN n12         HEADING 'NET RM|1ST YEAR|/CUST' FORMAT 9,990
COLUMN rep12       HEADING 'OF WHICH|REPEAT RM|/CUST' FORMAT 9,990
COLUMN rep_share   HEADING 'SHARE OF|REPEAT RM %'  FORMAT 990.0
COLUMN y2_pct      HEADING 'ACTIVE IN|YEAR 2 %'    FORMAT 990.0

BREAK ON REPORT

WITH ord AS (
    -- ONE ROW PER COMPLETED ORDER, with the tier in force on that date
    SELECT c.cus_ID, f.order_ID,
           MIN(d.cal_date)                          AS cal_date,
           MAX(c.cus_loyalty_tier)                  AS tier,
           SUM(f.order_total_amt - f.order_tax_amt) AS net
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY c.cus_ID, f.order_ID
),
ok AS (
    SELECT cus_ID, order_ID, cal_date, tier, net,
           TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM') AS cohort,
           MONTHS_BETWEEN(TRUNC(cal_date, 'MM'),
                          TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM')) AS k,
           MIN(order_ID) KEEP (DENSE_RANK FIRST ORDER BY cal_date)
                         OVER (PARTITION BY cus_ID)          AS first_order
    FROM   ord
),
hz AS (SELECT TRUNC(MAX(cal_date), 'MM') AS horizon FROM ord),
cust AS (
    -- the year's cohort only, one row per customer
    SELECT cus_ID, MIN(cohort) AS cohort,
           MAX(CASE WHEN order_ID = first_order THEN tier END)     AS tier,
           MAX(CASE WHEN order_ID = first_order THEN net  END)     AS first_net,
           MAX(CASE WHEN k = 1  THEN 1 ELSE 0 END)                 AS m1,
           MAX(CASE WHEN k = 3  THEN 1 ELSE 0 END)                 AS m3,
           MAX(CASE WHEN k = 6  THEN 1 ELSE 0 END)                 AS m6,
           MAX(CASE WHEN k = 12 THEN 1 ELSE 0 END)                 AS m12,
           MAX(CASE WHEN k BETWEEN 1 AND 12 THEN 1 ELSE 0 END)     AS r12,
           MAX(CASE WHEN k BETWEEN 12 AND 23 THEN 1 ELSE 0 END)    AS y2,
           SUM(CASE WHEN k BETWEEN 0 AND 11 THEN 1 ELSE 0 END)     AS o12,
           SUM(CASE WHEN k BETWEEN 0 AND 11 THEN net ELSE 0 END)   AS n12,
           SUM(CASE WHEN k BETWEEN 1 AND 11 THEN net ELSE 0 END)   AS rep12
    FROM   ok
    WHERE  EXTRACT(YEAR FROM cohort) = &f_year
    GROUP  BY cus_ID
),
cx AS (
    SELECT c.*,
           COUNT(*) OVER ()                                            AS tot,
           SUM(CASE WHEN ADD_MONTHS(c.cohort, 11) <= h.horizon THEN c.rep12 END) OVER () AS tot_rep,
           CASE WHEN ADD_MONTHS(c.cohort, 1)  <= h.horizon THEN 1 END AS s1,
           CASE WHEN ADD_MONTHS(c.cohort, 3)  <= h.horizon THEN 1 END AS s3,
           CASE WHEN ADD_MONTHS(c.cohort, 6)  <= h.horizon THEN 1 END AS s6,
           CASE WHEN ADD_MONTHS(c.cohort, 11) <= h.horizon THEN 1 END AS s11,
           CASE WHEN ADD_MONTHS(c.cohort, 12) <= h.horizon THEN 1 END AS s12,
           CASE WHEN ADD_MONTHS(c.cohort, 23) <= h.horizon THEN 1 END AS s23
    FROM   cust c CROSS JOIN hz h
)
SELECT CASE WHEN GROUPING(x.tier) = 1 THEN 'ALL TIERS' ELSE x.tier END AS tier,
       COUNT(*)                                                       AS new_cust,
       ROUND(COUNT(*) / NULLIF(MAX(x.tot), 0) * 100, 1)               AS share_pct,
       ROUND(AVG(x.first_net), 2)                                     AS first_net,
       ROUND(SUM(x.m1  * x.s1)  / NULLIF(SUM(x.s1),  0) * 100, 1)     AS m1_pct,
       ROUND(SUM(x.m3  * x.s3)  / NULLIF(SUM(x.s3),  0) * 100, 1)     AS m3_pct,
       ROUND(SUM(x.m6  * x.s6)  / NULLIF(SUM(x.s6),  0) * 100, 1)     AS m6_pct,
       ROUND(SUM(x.m12 * x.s12) / NULLIF(SUM(x.s12), 0) * 100, 1)     AS m12_pct,
       ROUND(SUM(x.r12 * x.s12) / NULLIF(SUM(x.s12), 0) * 100, 1)     AS r12_pct,
       ROUND(SUM(x.o12   * x.s11) / NULLIF(SUM(x.s11), 0), 2)         AS o12,
       ROUND(SUM(x.n12   * x.s11) / NULLIF(SUM(x.s11), 0), 0)         AS n12,
       ROUND(SUM(x.rep12 * x.s11) / NULLIF(SUM(x.s11), 0), 0)         AS rep12,
       ROUND(SUM(x.rep12 * x.s11) / NULLIF(MAX(x.tot_rep), 0) * 100, 1) AS rep_share,
       ROUND(SUM(x.y2  * x.s23) / NULLIF(SUM(x.s23), 0) * 100, 1)     AS y2_pct
FROM   cx x
GROUP  BY ROLLUP(x.tier)
ORDER  BY GROUPING(x.tier), DECODE(x.tier, 'Bronze', 1, 'Silver', 2, 'Gold', 3, 'Platinum', 4, 5);



-- ###################################################################
-- SECTION 3 - THE COHORT YEAR BY FIRST BASKET (GATEWAY CATEGORY)
-- OLAP: DICE cohort year x product category, where the category is
-- the one that LED the first order (its biggest line by net). Ranked
-- by 12-month repeat rate. NET 1ST YR / FIRST ORDER is how many first
-- baskets the first year brings back; REPEAT LED BY SAME CAT % is the
-- share of the first-year repeat orders led by that same category.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. THE &f_year COHORT BY FIRST BASKET' SKIP 1 -
       CENTER 'CUT BY THE CATEGORY THAT LED THE FIRST ORDER, RANKED BY 12-MONTH REPEAT RATE  (DICE)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cat         HEADING 'FIRST BASKET|LED BY'    FORMAT A15
COLUMN new_cust    HEADING 'NEW|CUSTOMERS'          FORMAT 99,990
COLUMN share_pct   HEADING 'SHARE OF|COHORT %'      FORMAT 990.0
COLUMN first_net   HEADING 'FIRST|ORDER RM'         FORMAT 9,990.00
COLUMN first_units HEADING 'FIRST|ORDER|UNITS'      FORMAT 90.0
COLUMN m1_pct      HEADING 'ACTIVE|M+1 %'           FORMAT 990.0
COLUMN m3_pct      HEADING 'ACTIVE|M+3 %'           FORMAT 990.0
COLUMN m6_pct      HEADING 'ACTIVE|M+6 %'           FORMAT 990.0
COLUMN m12_pct     HEADING 'ACTIVE|M+12 %'          FORMAT 990.0
COLUMN r12_pct     HEADING 'BOUGHT|AGAIN|<=12M %'   FORMAT 990.0
COLUMN o12         HEADING 'ORDERS|1ST YEAR|/CUST'  FORMAT 90.00
COLUMN n12         HEADING 'NET RM|1ST YEAR|/CUST'  FORMAT 9,990
COLUMN mult        HEADING 'NET 1ST YR|/ FIRST|ORDER' FORMAT 90.0
COLUMN same_cat    HEADING 'REPEAT LED|BY SAME|CAT %' FORMAT 990.0

BREAK ON REPORT

WITH ord AS (
    -- ONE ROW PER COMPLETED ORDER: date, net, units, and the category
    -- of the order's biggest line (the one that led the basket)
    SELECT c.cus_ID, f.order_ID,
           MIN(d.cal_date)                          AS cal_date,
           SUM(f.order_total_amt - f.order_tax_amt) AS net,
           SUM(f.order_qty)                         AS units,
           MAX(p.product_category)
               KEEP (DENSE_RANK FIRST ORDER BY f.order_total_amt - f.order_tax_amt DESC,
                                              p.product_ID)  AS lead_cat
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   product_dim  p ON p.product_key  = f.product_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY c.cus_ID, f.order_ID
),
ok AS (
    SELECT cus_ID, order_ID, cal_date, net, units, lead_cat,
           TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM') AS cohort,
           MONTHS_BETWEEN(TRUNC(cal_date, 'MM'),
                          TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM')) AS k,
           MIN(order_ID) KEEP (DENSE_RANK FIRST ORDER BY cal_date)
                         OVER (PARTITION BY cus_ID)          AS first_order
    FROM   ord
),
ok2 AS (
    -- carry the first order's category onto every order of the customer
    SELECT o.*,
           MAX(CASE WHEN order_ID = first_order THEN lead_cat END)
               OVER (PARTITION BY cus_ID)                    AS first_cat
    FROM   ok o
),
hz AS (SELECT TRUNC(MAX(cal_date), 'MM') AS horizon FROM ord),
cust AS (
    SELECT cus_ID, MIN(cohort) AS cohort, MIN(first_cat) AS cat,
           MAX(CASE WHEN order_ID = first_order THEN net   END)    AS first_net,
           MAX(CASE WHEN order_ID = first_order THEN units END)    AS first_units,
           MAX(CASE WHEN k = 1  THEN 1 ELSE 0 END)                 AS m1,
           MAX(CASE WHEN k = 3  THEN 1 ELSE 0 END)                 AS m3,
           MAX(CASE WHEN k = 6  THEN 1 ELSE 0 END)                 AS m6,
           MAX(CASE WHEN k = 12 THEN 1 ELSE 0 END)                 AS m12,
           MAX(CASE WHEN k BETWEEN 1 AND 12 THEN 1 ELSE 0 END)     AS r12,
           SUM(CASE WHEN k BETWEEN 0 AND 11 THEN 1 ELSE 0 END)     AS o12,
           SUM(CASE WHEN k BETWEEN 0 AND 11 THEN net ELSE 0 END)   AS n12,
           SUM(CASE WHEN k BETWEEN 1 AND 11 THEN 1 ELSE 0 END)     AS rep_ord,
           SUM(CASE WHEN k BETWEEN 1 AND 11 AND lead_cat = first_cat THEN 1 ELSE 0 END) AS rep_same
    FROM   ok2
    WHERE  EXTRACT(YEAR FROM cohort) = &f_year
    GROUP  BY cus_ID
),
cx AS (
    SELECT c.*,
           COUNT(*) OVER ()                                            AS tot,
           CASE WHEN ADD_MONTHS(c.cohort, 1)  <= h.horizon THEN 1 END AS s1,
           CASE WHEN ADD_MONTHS(c.cohort, 3)  <= h.horizon THEN 1 END AS s3,
           CASE WHEN ADD_MONTHS(c.cohort, 6)  <= h.horizon THEN 1 END AS s6,
           CASE WHEN ADD_MONTHS(c.cohort, 11) <= h.horizon THEN 1 END AS s11,
           CASE WHEN ADD_MONTHS(c.cohort, 12) <= h.horizon THEN 1 END AS s12
    FROM   cust c CROSS JOIN hz h
)
SELECT CASE WHEN GROUPING(x.cat) = 1 THEN 'ALL CATEGORIES' ELSE x.cat END AS cat,
       COUNT(*)                                                       AS new_cust,
       ROUND(COUNT(*) / NULLIF(MAX(x.tot), 0) * 100, 1)               AS share_pct,
       ROUND(AVG(x.first_net), 2)                                     AS first_net,
       ROUND(AVG(x.first_units), 1)                                   AS first_units,
       ROUND(SUM(x.m1  * x.s1)  / NULLIF(SUM(x.s1),  0) * 100, 1)     AS m1_pct,
       ROUND(SUM(x.m3  * x.s3)  / NULLIF(SUM(x.s3),  0) * 100, 1)     AS m3_pct,
       ROUND(SUM(x.m6  * x.s6)  / NULLIF(SUM(x.s6),  0) * 100, 1)     AS m6_pct,
       ROUND(SUM(x.m12 * x.s12) / NULLIF(SUM(x.s12), 0) * 100, 1)     AS m12_pct,
       ROUND(SUM(x.r12 * x.s12) / NULLIF(SUM(x.s12), 0) * 100, 1)     AS r12_pct,
       ROUND(SUM(x.o12 * x.s11) / NULLIF(SUM(x.s11), 0), 2)           AS o12,
       ROUND(SUM(x.n12 * x.s11) / NULLIF(SUM(x.s11), 0), 0)           AS n12,
       ROUND(SUM(x.n12 * x.s11) / NULLIF(SUM(x.first_net * x.s11), 0), 1) AS mult,
       ROUND(SUM(x.rep_same * x.s11) / NULLIF(SUM(x.rep_ord * x.s11), 0) * 100, 1) AS same_cat
FROM   cx x
GROUP  BY ROLLUP(x.cat)
ORDER  BY GROUPING(x.cat), r12_pct DESC NULLS LAST, new_cust DESC;



-- ###################################################################
-- SECTION 4 - THE COHORT YEAR BY ACQUIRING BRANCH
-- OLAP: DRILL-ACROSS to the branch dimension - the cohort cut by the
-- branch of the FIRST order, ranked by 12-month repeat rate. REPEAT AT
-- SAME BRANCH % = share of the first-year repeat orders placed at the
-- branch that won the customer.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. THE &f_year COHORT BY ACQUIRING BRANCH' SKIP 1 -
       CENTER 'CUT BY THE BRANCH OF THE FIRST ORDER, RANKED BY 12-MONTH REPEAT RATE  (DRILL-ACROSS)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city     HEADING 'ACQUIRING|BRANCH'       FORMAT A15
COLUMN br_state    HEADING 'STATE'                  FORMAT A19
COLUMN new_cust    HEADING 'NEW|CUSTOMERS'          FORMAT 99,990
COLUMN share_pct   HEADING 'SHARE OF|COHORT %'      FORMAT 990.0
COLUMN m1_pct      HEADING 'ACTIVE|M+1 %'           FORMAT 990.0
COLUMN m3_pct      HEADING 'ACTIVE|M+3 %'           FORMAT 990.0
COLUMN m6_pct      HEADING 'ACTIVE|M+6 %'           FORMAT 990.0
COLUMN m12_pct     HEADING 'ACTIVE|M+12 %'          FORMAT 990.0
COLUMN r12_pct     HEADING 'BOUGHT|AGAIN|<=12M %'   FORMAT 990.0
COLUMN o12         HEADING 'ORDERS|1ST YEAR|/CUST'  FORMAT 90.00
COLUMN n12         HEADING 'NET RM|1ST YEAR|/CUST'  FORMAT 9,990
COLUMN stay_pct    HEADING 'REPEAT AT|SAME|BRANCH %' FORMAT 990.0
COLUMN y2_pct      HEADING 'ACTIVE IN|YEAR 2 %'     FORMAT 990.0
COLUMN br_ID       NOPRINT

BREAK ON REPORT

WITH ord AS (
    -- ONE ROW PER COMPLETED ORDER with the branch it was placed at
    SELECT c.cus_ID, f.order_ID,
           MIN(d.cal_date)                          AS cal_date,
           MIN(b.br_ID)                             AS br_ID,
           MIN(b.br_city)                           AS br_city,
           MIN(b.br_state)                          AS br_state,
           SUM(f.order_total_amt - f.order_tax_amt) AS net
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    JOIN   branch_dim   b ON b.branch_key   = f.branch_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY c.cus_ID, f.order_ID
),
ok AS (
    SELECT cus_ID, order_ID, cal_date, br_ID, br_city, br_state, net,
           TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM') AS cohort,
           MONTHS_BETWEEN(TRUNC(cal_date, 'MM'),
                          TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM')) AS k,
           MIN(order_ID) KEEP (DENSE_RANK FIRST ORDER BY cal_date)
                         OVER (PARTITION BY cus_ID)          AS first_order
    FROM   ord
),
ok2 AS (
    -- carry the acquiring branch onto every order of the customer
    SELECT o.*,
           MAX(CASE WHEN order_ID = first_order THEN br_ID END)
               OVER (PARTITION BY cus_ID)                    AS first_br
    FROM   ok o
),
hz AS (SELECT TRUNC(MAX(cal_date), 'MM') AS horizon FROM ord),
cust AS (
    SELECT cus_ID, MIN(cohort) AS cohort, MIN(first_br) AS br_ID,
           MAX(CASE WHEN order_ID = first_order THEN br_city  END)  AS br_city,
           MAX(CASE WHEN order_ID = first_order THEN br_state END)  AS br_state,
           MAX(CASE WHEN k = 1  THEN 1 ELSE 0 END)                 AS m1,
           MAX(CASE WHEN k = 3  THEN 1 ELSE 0 END)                 AS m3,
           MAX(CASE WHEN k = 6  THEN 1 ELSE 0 END)                 AS m6,
           MAX(CASE WHEN k = 12 THEN 1 ELSE 0 END)                 AS m12,
           MAX(CASE WHEN k BETWEEN 1 AND 12 THEN 1 ELSE 0 END)     AS r12,
           MAX(CASE WHEN k BETWEEN 12 AND 23 THEN 1 ELSE 0 END)    AS y2,
           SUM(CASE WHEN k BETWEEN 0 AND 11 THEN 1 ELSE 0 END)     AS o12,
           SUM(CASE WHEN k BETWEEN 0 AND 11 THEN net ELSE 0 END)   AS n12,
           SUM(CASE WHEN k BETWEEN 1 AND 11 THEN 1 ELSE 0 END)     AS rep_ord,
           SUM(CASE WHEN k BETWEEN 1 AND 11 AND br_ID = first_br THEN 1 ELSE 0 END) AS rep_same
    FROM   ok2
    WHERE  EXTRACT(YEAR FROM cohort) = &f_year
    GROUP  BY cus_ID
),
cx AS (
    SELECT c.*,
           COUNT(*) OVER ()                                            AS tot,
           CASE WHEN ADD_MONTHS(c.cohort, 1)  <= h.horizon THEN 1 END AS s1,
           CASE WHEN ADD_MONTHS(c.cohort, 3)  <= h.horizon THEN 1 END AS s3,
           CASE WHEN ADD_MONTHS(c.cohort, 6)  <= h.horizon THEN 1 END AS s6,
           CASE WHEN ADD_MONTHS(c.cohort, 11) <= h.horizon THEN 1 END AS s11,
           CASE WHEN ADD_MONTHS(c.cohort, 12) <= h.horizon THEN 1 END AS s12,
           CASE WHEN ADD_MONTHS(c.cohort, 23) <= h.horizon THEN 1 END AS s23
    FROM   cust c CROSS JOIN hz h
)
SELECT CASE WHEN GROUPING(x.br_ID) = 1 THEN 'ALL BRANCHES' ELSE x.br_city END AS br_city,
       CASE WHEN GROUPING(x.br_ID) = 1 THEN NULL ELSE x.br_state END        AS br_state,
       COUNT(*)                                                       AS new_cust,
       ROUND(COUNT(*) / NULLIF(MAX(x.tot), 0) * 100, 1)               AS share_pct,
       ROUND(SUM(x.m1  * x.s1)  / NULLIF(SUM(x.s1),  0) * 100, 1)     AS m1_pct,
       ROUND(SUM(x.m3  * x.s3)  / NULLIF(SUM(x.s3),  0) * 100, 1)     AS m3_pct,
       ROUND(SUM(x.m6  * x.s6)  / NULLIF(SUM(x.s6),  0) * 100, 1)     AS m6_pct,
       ROUND(SUM(x.m12 * x.s12) / NULLIF(SUM(x.s12), 0) * 100, 1)     AS m12_pct,
       ROUND(SUM(x.r12 * x.s12) / NULLIF(SUM(x.s12), 0) * 100, 1)     AS r12_pct,
       ROUND(SUM(x.o12 * x.s11) / NULLIF(SUM(x.s11), 0), 2)           AS o12,
       ROUND(SUM(x.n12 * x.s11) / NULLIF(SUM(x.s11), 0), 0)           AS n12,
       ROUND(SUM(x.rep_same * x.s11) / NULLIF(SUM(x.rep_ord * x.s11), 0) * 100, 1) AS stay_pct,
       ROUND(SUM(x.y2  * x.s23) / NULLIF(SUM(x.s23), 0) * 100, 1)     AS y2_pct,
       x.br_ID
FROM   cx x
GROUP  BY ROLLUP((x.br_ID, x.br_city, x.br_state))
ORDER  BY GROUPING(x.br_ID), r12_pct DESC NULLS LAST, new_cust DESC;



-- ###################################################################
-- SECTION 5 - THE COHORT YEAR MONTH BY MONTH (THE TRIANGLE)
-- OLAP: DRILL-DOWN year -> its 12 monthly cohorts. Cohort months down,
-- ACTIVE % in month +1 .. +12 across; a cell after the horizon is
-- blank. The last row is the pooled year (ROLLUP), computed on the
-- cohorts that have reached that month. Read it down a column (the
-- same age, different cohorts), along a row (one cohort ageing) and
-- diagonally (the same CALENDAR month - the seasonality).
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. THE &f_year COHORTS: % STILL BUYING, MONTH +1 TO +12' SKIP 1 -
       CENTER 'DRILL-DOWN YEAR -> COHORT MONTH  (BLANK = BEYOND THE LAST MONTH OF DATA)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cohort_lbl  HEADING 'COHORT'                FORMAT A9
COLUMN new_cust    HEADING 'NEW|CUST'              FORMAT 9,990
COLUMN m1          HEADING 'M+1'                   FORMAT 990.0
COLUMN m2          HEADING 'M+2'                   FORMAT 990.0
COLUMN m3          HEADING 'M+3'                   FORMAT 990.0
COLUMN m4          HEADING 'M+4'                   FORMAT 990.0
COLUMN m5          HEADING 'M+5'                   FORMAT 990.0
COLUMN m6          HEADING 'M+6'                   FORMAT 990.0
COLUMN m7          HEADING 'M+7'                   FORMAT 990.0
COLUMN m8          HEADING 'M+8'                   FORMAT 990.0
COLUMN m9          HEADING 'M+9'                   FORMAT 990.0
COLUMN m10         HEADING 'M+10'                  FORMAT 990.0
COLUMN m11         HEADING 'M+11'                  FORMAT 990.0
COLUMN m12         HEADING 'M+12'                  FORMAT 990.0
COLUMN r12_pct     HEADING 'BOUGHT|AGAIN|<=12M %'  FORMAT 990.0
COLUMN o12         HEADING 'ORDERS|1ST YR|/CUST'   FORMAT 90.00
COLUMN n12         HEADING 'NET RM|1ST YR|/CUST'   FORMAT 9,990

BREAK ON REPORT

WITH ord AS (
    SELECT c.cus_ID, f.order_ID,
           MIN(d.cal_date)                          AS cal_date,
           SUM(f.order_total_amt - f.order_tax_amt) AS net
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY c.cus_ID, f.order_ID
),
ok AS (
    SELECT cus_ID, order_ID, cal_date, net,
           TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM') AS cohort,
           MONTHS_BETWEEN(TRUNC(cal_date, 'MM'),
                          TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM')) AS k
    FROM   ord
),
hz AS (SELECT TRUNC(MAX(cal_date), 'MM') AS horizon FROM ord),
cust AS (
    SELECT cus_ID, MIN(cohort) AS cohort,
           MAX(CASE WHEN k = 1  THEN 1 ELSE 0 END) AS m1,
           MAX(CASE WHEN k = 2  THEN 1 ELSE 0 END) AS m2,
           MAX(CASE WHEN k = 3  THEN 1 ELSE 0 END) AS m3,
           MAX(CASE WHEN k = 4  THEN 1 ELSE 0 END) AS m4,
           MAX(CASE WHEN k = 5  THEN 1 ELSE 0 END) AS m5,
           MAX(CASE WHEN k = 6  THEN 1 ELSE 0 END) AS m6,
           MAX(CASE WHEN k = 7  THEN 1 ELSE 0 END) AS m7,
           MAX(CASE WHEN k = 8  THEN 1 ELSE 0 END) AS m8,
           MAX(CASE WHEN k = 9  THEN 1 ELSE 0 END) AS m9,
           MAX(CASE WHEN k = 10 THEN 1 ELSE 0 END) AS m10,
           MAX(CASE WHEN k = 11 THEN 1 ELSE 0 END) AS m11,
           MAX(CASE WHEN k = 12 THEN 1 ELSE 0 END) AS m12,
           MAX(CASE WHEN k BETWEEN 1 AND 12 THEN 1 ELSE 0 END)   AS r12,
           SUM(CASE WHEN k BETWEEN 0 AND 11 THEN 1 ELSE 0 END)   AS o12,
           SUM(CASE WHEN k BETWEEN 0 AND 11 THEN net ELSE 0 END) AS n12
    FROM   ok
    WHERE  EXTRACT(YEAR FROM cohort) = &f_year
    GROUP  BY cus_ID
),
cx AS (
    SELECT c.*,
           CASE WHEN ADD_MONTHS(c.cohort, 1)  <= h.horizon THEN 1 END AS s1,
           CASE WHEN ADD_MONTHS(c.cohort, 2)  <= h.horizon THEN 1 END AS s2,
           CASE WHEN ADD_MONTHS(c.cohort, 3)  <= h.horizon THEN 1 END AS s3,
           CASE WHEN ADD_MONTHS(c.cohort, 4)  <= h.horizon THEN 1 END AS s4,
           CASE WHEN ADD_MONTHS(c.cohort, 5)  <= h.horizon THEN 1 END AS s5,
           CASE WHEN ADD_MONTHS(c.cohort, 6)  <= h.horizon THEN 1 END AS s6,
           CASE WHEN ADD_MONTHS(c.cohort, 7)  <= h.horizon THEN 1 END AS s7,
           CASE WHEN ADD_MONTHS(c.cohort, 8)  <= h.horizon THEN 1 END AS s8,
           CASE WHEN ADD_MONTHS(c.cohort, 9)  <= h.horizon THEN 1 END AS s9,
           CASE WHEN ADD_MONTHS(c.cohort, 10) <= h.horizon THEN 1 END AS s10,
           CASE WHEN ADD_MONTHS(c.cohort, 11) <= h.horizon THEN 1 END AS s11,
           CASE WHEN ADD_MONTHS(c.cohort, 12) <= h.horizon THEN 1 END AS s12
    FROM   cust c CROSS JOIN hz h
)
SELECT CASE WHEN GROUPING(x.cohort) = 1 THEN 'YEAR &f_year'
            ELSE TO_CHAR(x.cohort, 'Mon YYYY', 'NLS_DATE_LANGUAGE=ENGLISH') END AS cohort_lbl,
       COUNT(*)                                                    AS new_cust,
       ROUND(SUM(x.m1  * x.s1)  / NULLIF(SUM(x.s1),  0) * 100, 1)  AS m1,
       ROUND(SUM(x.m2  * x.s2)  / NULLIF(SUM(x.s2),  0) * 100, 1)  AS m2,
       ROUND(SUM(x.m3  * x.s3)  / NULLIF(SUM(x.s3),  0) * 100, 1)  AS m3,
       ROUND(SUM(x.m4  * x.s4)  / NULLIF(SUM(x.s4),  0) * 100, 1)  AS m4,
       ROUND(SUM(x.m5  * x.s5)  / NULLIF(SUM(x.s5),  0) * 100, 1)  AS m5,
       ROUND(SUM(x.m6  * x.s6)  / NULLIF(SUM(x.s6),  0) * 100, 1)  AS m6,
       ROUND(SUM(x.m7  * x.s7)  / NULLIF(SUM(x.s7),  0) * 100, 1)  AS m7,
       ROUND(SUM(x.m8  * x.s8)  / NULLIF(SUM(x.s8),  0) * 100, 1)  AS m8,
       ROUND(SUM(x.m9  * x.s9)  / NULLIF(SUM(x.s9),  0) * 100, 1)  AS m9,
       ROUND(SUM(x.m10 * x.s10) / NULLIF(SUM(x.s10), 0) * 100, 1)  AS m10,
       ROUND(SUM(x.m11 * x.s11) / NULLIF(SUM(x.s11), 0) * 100, 1)  AS m11,
       ROUND(SUM(x.m12 * x.s12) / NULLIF(SUM(x.s12), 0) * 100, 1)  AS m12,
       ROUND(SUM(x.r12 * x.s12) / NULLIF(SUM(x.s12), 0) * 100, 1)  AS r12_pct,
       ROUND(SUM(x.o12 * x.s11) / NULLIF(SUM(x.s11), 0), 2)        AS o12,
       ROUND(SUM(x.n12 * x.s11) / NULLIF(SUM(x.s11), 0), 0)        AS n12
FROM   cx x
GROUP  BY ROLLUP(x.cohort)
ORDER  BY GROUPING(x.cohort), x.cohort;

-- ---- prompt 2: which cohort month? (spool paused, helper hidden) ---
SPOOL OFF
ACCEPT p_month NUMBER DEFAULT 11 PROMPT 'Cohort month to follow, 1-12 (default 11 = November): '
SET TERMOUT OFF
-- resolve inside the chosen year: exact month first, else the biggest
-- cohort of the year; also the labels for the titles
COLUMN f_cohort   NEW_VALUE f_cohort   NOPRINT
COLUMN f_coh_lbl  NEW_VALUE f_coh_lbl  NOPRINT
COLUMN f_twin_lbl NEW_VALUE f_twin_lbl NOPRINT
SELECT TO_CHAR(MAX(cohort) KEEP (DENSE_RANK FIRST ORDER BY miss, n DESC), 'YYYY-MM-DD') AS f_cohort,
       TO_CHAR(MAX(cohort) KEEP (DENSE_RANK FIRST ORDER BY miss, n DESC),
               'Mon YYYY', 'NLS_DATE_LANGUAGE=ENGLISH')                                    AS f_coh_lbl,
       TO_CHAR(ADD_MONTHS(MAX(cohort) KEEP (DENSE_RANK FIRST ORDER BY miss, n DESC), -12),
               'Mon YYYY', 'NLS_DATE_LANGUAGE=ENGLISH')                                    AS f_twin_lbl
FROM (
    SELECT cohort, COUNT(*) AS n,
           CASE WHEN EXTRACT(MONTH FROM cohort) = &p_month THEN 0 ELSE 1 END AS miss
    FROM (
        SELECT c.cus_ID, TRUNC(MIN(d.cal_date), 'MM') AS cohort
        FROM   order_fact   f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        WHERE  f.order_status = 'Completed'
        GROUP  BY c.cus_ID
    )
    WHERE  EXTRACT(YEAR FROM cohort) = &f_year
    GROUP  BY cohort
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL cohort_retention_output.txt APPEND



-- ###################################################################
-- SECTION 6 - THE CHOSEN COHORT, MONTH BY MONTH, AGAINST ITS TWIN
-- OLAP: DRILL-DOWN to the finest grain - one cohort followed through
-- every month since it was won (up to 36, stops at the horizon):
-- customers active and %, the same offset of the year-ago twin cohort
-- (same calendar month one year earlier, so the seasonality cancels),
-- the difference in points, the share that has bought again by then,
-- orders, net RM, RM per active customer and the cumulative net RM per
-- customer won.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 6. THE &f_coh_lbl COHORT MONTH BY MONTH vs THE &f_twin_lbl COHORT' SKIP 1 -
       CENTER 'DRILL-DOWN TO ONE COHORT: MONTH 0 = ACQUISITION MONTH, TWIN = SAME OFFSET ONE YEAR EARLIER' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN mth         HEADING 'CALENDAR|MONTH'          FORMAT A9
COLUMN k           HEADING 'MONTH|+K'                FORMAT 90
COLUMN act         HEADING 'ACTIVE|CUST'             FORMAT 9,990
COLUMN act_pct     HEADING 'ACTIVE|%'                FORMAT 990.0
COLUMN twin_pct    HEADING 'TWIN|ACTIVE %'           FORMAT 990.0
COLUMN diff_pts    HEADING 'DIFF|PTS'                FORMAT 990.0
COLUMN ever_pct    HEADING 'BOUGHT|AGAIN|BY NOW %'   FORMAT 990.0
COLUMN orders      HEADING 'ORDERS'                  FORMAT 99,990
COLUMN net         HEADING 'NET|SALES (RM)'          FORMAT 9,999,990
COLUMN net_act     HEADING 'NET RM|PER ACTIVE'       FORMAT 9,990.00
COLUMN cum_net     HEADING 'CUM NET RM|PER CUST WON' FORMAT 99,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF orders net ON REPORT

WITH ord AS (
    SELECT c.cus_ID, f.order_ID,
           MIN(d.cal_date)                          AS cal_date,
           SUM(f.order_total_amt - f.order_tax_amt) AS net
    FROM   order_fact   f
    JOIN   date_dim     d ON d.date_key     = f.date_key
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY c.cus_ID, f.order_ID
),
ok AS (
    SELECT cus_ID, order_ID, cal_date, net,
           TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM') AS cohort,
           MONTHS_BETWEEN(TRUNC(cal_date, 'MM'),
                          TRUNC(MIN(cal_date) OVER (PARTITION BY cus_ID), 'MM')) AS k
    FROM   ord
),
hz   AS (SELECT TRUNC(MAX(cal_date), 'MM') AS horizon FROM ord),
this AS (SELECT * FROM ok WHERE cohort = DATE '&f_cohort'),
twin AS (SELECT * FROM ok WHERE cohort = ADD_MONTHS(DATE '&f_cohort', -12)),
sz   AS (
    SELECT (SELECT COUNT(DISTINCT cus_ID) FROM this) AS n_this,
           (SELECT COUNT(DISTINCT cus_ID) FROM twin) AS n_twin
    FROM   dual
),
ks   AS (SELECT LEVEL - 1 AS k FROM dual CONNECT BY LEVEL <= 36),
a    AS (
    SELECT k, COUNT(DISTINCT cus_ID) AS act, COUNT(*) AS orders, SUM(net) AS net
    FROM   this GROUP BY k
),
t    AS (SELECT k, COUNT(DISTINCT cus_ID) AS act FROM twin GROUP BY k),
fr   AS (
    -- the month each customer FIRST bought again (for the cumulative %)
    SELECT first_rep AS k, COUNT(*) AS n
    FROM  (SELECT cus_ID, MIN(CASE WHEN k >= 1 THEN k END) AS first_rep FROM this GROUP BY cus_ID)
    WHERE  first_rep IS NOT NULL
    GROUP  BY first_rep
)
SELECT TO_CHAR(ADD_MONTHS(DATE '&f_cohort', ks.k), 'Mon YYYY', 'NLS_DATE_LANGUAGE=ENGLISH') AS mth,
       ks.k,
       NVL(a.act, 0)                                                        AS act,
       ROUND(NVL(a.act, 0) / NULLIF(sz.n_this, 0) * 100, 1)                 AS act_pct,
       CASE WHEN sz.n_twin > 0 THEN ROUND(NVL(t.act, 0) / sz.n_twin * 100, 1) END AS twin_pct,
       CASE WHEN sz.n_twin > 0 THEN
            ROUND(NVL(a.act, 0) / NULLIF(sz.n_this, 0) * 100 - NVL(t.act, 0) / sz.n_twin * 100, 1) END AS diff_pts,
       ROUND(SUM(NVL(fr.n, 0)) OVER (ORDER BY ks.k) / NULLIF(sz.n_this, 0) * 100, 1) AS ever_pct,
       NVL(a.orders, 0)                                                     AS orders,
       NVL(a.net, 0)                                                        AS net,
       ROUND(a.net / NULLIF(a.act, 0), 2)                                   AS net_act,
       ROUND(SUM(NVL(a.net, 0)) OVER (ORDER BY ks.k) / NULLIF(sz.n_this, 0), 2) AS cum_net
FROM   ks
CROSS  JOIN sz
CROSS  JOIN hz
LEFT   JOIN a  ON a.k  = ks.k
LEFT   JOIN t  ON t.k  = ks.k
LEFT   JOIN fr ON fr.k = ks.k
WHERE  ADD_MONTHS(DATE '&f_cohort', ks.k) <= hz.horizon
ORDER  BY ks.k;

PROMPT
PROMPT +==========================================================+
PROMPT |           END OF COHORT RETENTION REPORT                 |
PROMPT +==========================================================+
PROMPT

-- ===================================================================
-- tidy up so the next script starts clean
-- ===================================================================
SPOOL OFF
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE p_from
UNDEFINE p_to
UNDEFINE p_year
UNDEFINE p_month
UNDEFINE f_from
UNDEFINE f_to
UNDEFINE f_year
UNDEFINE f_cohort
UNDEFINE f_coh_lbl
UNDEFINE f_twin_lbl
UNDEFINE run_dt
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
