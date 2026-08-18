-- ===================================================================
-- 02_product_category_drilldown.sql
-- SALES ANALYSIS - PRODUCT CATEGORY SALES, DRILLED DOWN STEP BY STEP
--   states x years  ->  pick a STATE  ->  its branches x years
--   ->  pick a BRANCH  ->  its years x quarters  ->  pick a YEAR
--   ->  its product categories RANKED, quarters across (the trend)
--   ->  pick a CATEGORY  ->  its products, quarters across
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Fz\02_product_category_drilldown.sql
--
-- PARAMETERS (the year range at the start; the rest ONE AT A TIME,
-- each after the table it refers to has printed, so the choice is
-- made from what is on screen)
--   start year, end year   at the start   defaults 2018 and 2025 -
--                          frame sections 1-3 (year columns outside the
--                          range are hidden, totals / share / growth
--                          are computed on the range)
--   state      after section 1   default Selangor
--   branch     after section 2   default Petaling Jaya
--   year       after section 3   default = end year
--   category   after section 4   default Serum
--   A name that matches nothing falls back to the biggest member of
--   that level (top-selling state / branch / category), so the drill
--   never dead-ends. The spool is paused around every prompt, so the
--   output file holds only the tables.
--
-- WHAT IT ANSWERS
--   1. Where does product revenue come from, state by state and year
--      by year - and how did each state grow?
--   2. Inside one state, which branches carry it?
--   3. Inside one branch, how do the quarters behave year after year
--      (Q4 festive peak, Q3 trough, the MCO holes)?
--   4. Inside one branch-year, which product CATEGORIES lead, and how
--      does each move quarter by quarter - seasonal or flat?
--   5. Inside one category, which PRODUCTS make it, quarter by quarter,
--      and at what price then vs now?
--
-- THE CUBE
--   fact      order_fact  (one row per product line, Completed only)
--   dims      date_dim.cal_year / cal_quarter / cal_year_month
--             branch_dim.br_state / br_ID / br_city
--             product_dim.product_category / product_name
--   measures  Sales (RM) = order_total_amt - order_tax_amt
--                          (= qty x price of the day - discount; SST is
--                          passed on to the government, not revenue)
--             Units      = SUM(order_qty)
--             Lines      = COUNT(*)  (order lines)
--             Realised price = sales / units
--   Sections 1-3 print whole ringgit (no cents) so eight years fit
--   across the page; sections 4-5 print cents.
--
-- WHY GROUP BY CATEGORY / NAME AND NOT product_key
--   product_dim is SCD Type 2: a product with a price rise has two or
--   three product_key rows. Category and name are identical across
--   those versions, so grouping on them rolls the versions together.
--   Same idea for branch_dim: group on br_ID / br_city, never branch_key.
--
-- REPORT SECTIONS  (each one is ONE OLAP operation)
--   Every title reads "n. PRODUCT SALES BY <level> (RM)" with the
--   scope (state / branch / year / category, and the year range) on
--   the line below it.
--   1  BY STATE      PIVOT       states down, years of the range across
--         -> prompt: state
--   2  BY BRANCH     DRILL-DOWN  state -> branch, years across
--         -> prompt: branch
--   3  BY QUARTER    DRILL-DOWN  year -> quarter, quarters across, YoY %
--         -> prompt: year
--   4  BY CATEGORY   DICE        branch x year, categories RANKED, quarter
--                                trend across
--         -> prompt: category
--   5  BY PRODUCT    DRILL-DOWN  category -> product, quarters across,
--                                price then vs now
--
-- WHAT TO LOOK FOR  (defaults: 2018-2025 > Selangor > Petaling Jaya >
--   2025 > Serum, revision-3 data)
--   - Section 1: Selangor is the biggest state every year (44 % of
--     product sales 2018-2025), Wilayah Persekutuan second (32 %),
--     every state dips in 2020-21 (MCO) and jumps 70-80 % in 2022,
--     Perak appears in 2023 (Ipoh); every established state has grown
--     65-75 % from 2018 to 2025 (Melaka +298 % because it opened in
--     August 2018).
--   - Section 2 (Selangor): Petaling Jaya carries 32 % of the state,
--     then Shah Alam 20 %, Puchong 19 %, Klang 17 %, Selayang 13 % -
--     the same order every year, all growing 65-74 %.
--   - Section 3 (Petaling Jaya): Q4 is the best quarter in every year
--     but 2018 (festive run-ups + 11.11 / 12.12, 28-31 % of the year,
--     40 % in 2021 when the FMCO emptied Q3); Q3 is the weakest; 2020
--     Q2 (MCO 1.0) and 2021 Q3 (FMCO) are the lockdown holes; 2022 is
--     +74 % on 2021.
--   - Section 4 (PJ 2025): Serum #1 (19 %) and Moisturizer #2 (14 %),
--     then Face Mask, Sunscreen, Cleanser ...; in 2025 every category
--     peaks in Q4 (festive gifting), Exfoliator and Face Mask the most
--     seasonal (PEAK/LOW 1.5-1.6), Moisturizer the flattest (1.28),
--     realised price runs from RM 98 (Serum) to RM 20 (Spot Treatment).
--     Run it with year 2024 to see Sunscreen peak in Q2 instead.
--   - Section 5 (Serum 2025): Peptide Firming Serum (22 %) and Retinol
--     Renewal Serum (19 %) lead, both peaking in Q1 (the January price
--     rise pulled buying forward - Q1 > Q4 only in these two); PRICE
--     THEN = PRICE NOW in 2025 because 2025 is the current price era -
--     run it with year 2024 to see 135 -> 149 on Peptide Firming Serum
--     (SCD2). REALISED below PRICE THEN is the loyalty / promo discount.
--   - Try: Perak > Ipoh > 2023 to see an opening year (Q1 = March
--     only), or Melaka > Melaka > 2021 for the FMCO hole in Q3; a
--     nonsense name at any prompt lands on the biggest member.
-- ===================================================================

-- reset anything a previous script left behind in this session
TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 165
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

-- SQL*Plus caps an ACCEPT prompt at 99 characters - keep it short.
-- The year range frames sections 1-3 (year columns outside it are
-- hidden, totals / share / growth are computed on the range only).
ACCEPT p_from NUMBER DEFAULT 2018 PROMPT 'Start year (default 2018): '
ACCEPT p_to   NUMBER DEFAULT 2025 PROMPT 'End year   (default 2025): '

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

-- one PRINT / NOPRINT switch per year column, so the pivots in
-- sections 1-2 only show the years inside the range
COLUMN v2018 NEW_VALUE v2018 NOPRINT
COLUMN v2019 NEW_VALUE v2019 NOPRINT
COLUMN v2020 NEW_VALUE v2020 NOPRINT
COLUMN v2021 NEW_VALUE v2021 NOPRINT
COLUMN v2022 NEW_VALUE v2022 NOPRINT
COLUMN v2023 NEW_VALUE v2023 NOPRINT
COLUMN v2024 NEW_VALUE v2024 NOPRINT
COLUMN v2025 NEW_VALUE v2025 NOPRINT
SELECT CASE WHEN 2018 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2018,
       CASE WHEN 2019 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2019,
       CASE WHEN 2020 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2020,
       CASE WHEN 2021 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2021,
       CASE WHEN 2022 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2022,
       CASE WHEN 2023 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2023,
       CASE WHEN 2024 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2024,
       CASE WHEN 2025 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2025
FROM   dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL product_category_drilldown_output.txt


-- ###################################################################
-- SECTION 1 - PRODUCT SALES BY STATE (years across)
-- OLAP: PIVOT - years of the chosen range across, states down, whole
-- company. TOTAL and SHARE % over the range, GROWTH % = end year vs
-- the first year the state traded inside the range (Perak from 2023).
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. PRODUCT SALES BY STATE (RM)' SKIP 1 -
       CENTER 'ALL BRANCHES, &f_from - &f_to  (PIVOT: YEARS ACROSS)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_state   HEADING 'STATE'      FORMAT A19
COLUMN branches   HEADING 'BR'         FORMAT 99
COLUMN y2018      HEADING '2018'       FORMAT 99,999,990 &v2018
COLUMN y2019      HEADING '2019'       FORMAT 99,999,990 &v2019
COLUMN y2020      HEADING '2020'       FORMAT 99,999,990 &v2020
COLUMN y2021      HEADING '2021'       FORMAT 99,999,990 &v2021
COLUMN y2022      HEADING '2022'       FORMAT 99,999,990 &v2022
COLUMN y2023      HEADING '2023'       FORMAT 99,999,990 &v2023
COLUMN y2024      HEADING '2024'       FORMAT 99,999,990 &v2024
COLUMN y2025      HEADING '2025'       FORMAT 99,999,990 &v2025
COLUMN total      HEADING 'TOTAL|&f_from-&f_to' FORMAT 999,999,990
COLUMN share_pct  HEADING 'SHARE|%'    FORMAT 990.0
COLUMN growth_pct HEADING 'GROWTH %|1ST->&f_to' FORMAT S9,990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF y2018 y2019 y2020 y2021 y2022 y2023 y2024 y2025 total ON REPORT

WITH sales AS (
    SELECT b.br_state, b.br_ID, d.cal_year,
           SUM(f.order_total_amt - f.order_tax_amt) AS amt
    FROM   order_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY b.br_state, b.br_ID, d.cal_year
)
SELECT br_state,
       COUNT(DISTINCT br_ID)                          AS branches,
       -- no ELSE, so a year the state did not trade prints blank
       SUM(CASE WHEN cal_year = 2018 THEN amt END)    AS y2018,
       SUM(CASE WHEN cal_year = 2019 THEN amt END)    AS y2019,
       SUM(CASE WHEN cal_year = 2020 THEN amt END)    AS y2020,
       SUM(CASE WHEN cal_year = 2021 THEN amt END)    AS y2021,
       SUM(CASE WHEN cal_year = 2022 THEN amt END)    AS y2022,
       SUM(CASE WHEN cal_year = 2023 THEN amt END)    AS y2023,
       SUM(CASE WHEN cal_year = 2024 THEN amt END)    AS y2024,
       SUM(CASE WHEN cal_year = 2025 THEN amt END)    AS y2025,
       SUM(amt)                                       AS total,
       ROUND(RATIO_TO_REPORT(SUM(amt)) OVER () * 100, 1) AS share_pct,
       ROUND((SUM(CASE WHEN cal_year = &f_to THEN amt END)
              / NULLIF(SUM(amt) KEEP (DENSE_RANK FIRST ORDER BY cal_year), 0) - 1) * 100, 1) AS growth_pct
FROM   (SELECT br_state, br_ID, cal_year, SUM(amt) AS amt FROM sales GROUP BY br_state, br_ID, cal_year)
GROUP  BY br_state
ORDER  BY total DESC;

-- ---- prompt 1: which state? (spool paused, helper hidden) ----------
SPOOL OFF
ACCEPT p_state CHAR DEFAULT 'Selangor' PROMPT 'State to open up (default Selangor): '
SET TERMOUT OFF
-- resolve to a real br_state value: name match first, else the biggest
COLUMN f_state NEW_VALUE f_state NOPRINT
SELECT MAX(br_state) KEEP (DENSE_RANK FIRST ORDER BY miss, amt DESC) AS f_state
FROM (
    SELECT b.br_state,
           SUM(f.order_total_amt - f.order_tax_amt) AS amt,
           CASE WHEN UPPER(b.br_state) LIKE '%' || UPPER(TRIM('&p_state')) || '%' THEN 0 ELSE 1 END AS miss
    FROM   order_fact f
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY b.br_state
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL product_category_drilldown_output.txt APPEND


-- ###################################################################
-- SECTION 2 - PRODUCT SALES BY BRANCH (the chosen state, years across)
-- OLAP: DRILL-DOWN state -> branch, still years across. SHARE % is
-- the branch's share of the state over the range.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. PRODUCT SALES BY BRANCH (RM)' SKIP 1 -
       CENTER 'STATE = &f_state, &f_from - &f_to  (DRILL-DOWN STATE -> BRANCH)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city    HEADING 'BRANCH'     FORMAT A15
COLUMN y2018      HEADING '2018'       FORMAT 9,999,990 &v2018
COLUMN y2019      HEADING '2019'       FORMAT 9,999,990 &v2019
COLUMN y2020      HEADING '2020'       FORMAT 9,999,990 &v2020
COLUMN y2021      HEADING '2021'       FORMAT 9,999,990 &v2021
COLUMN y2022      HEADING '2022'       FORMAT 9,999,990 &v2022
COLUMN y2023      HEADING '2023'       FORMAT 9,999,990 &v2023
COLUMN y2024      HEADING '2024'       FORMAT 9,999,990 &v2024
COLUMN y2025      HEADING '2025'       FORMAT 9,999,990 &v2025
COLUMN total      HEADING 'TOTAL|&f_from-&f_to' FORMAT 99,999,990
COLUMN share_pct  HEADING 'SHARE OF|STATE %' FORMAT 990.0
COLUMN growth_pct HEADING 'GROWTH %|1ST->&f_to' FORMAT S9,990.0
COLUMN br_ID      NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'STATE' OF y2018 y2019 y2020 y2021 y2022 y2023 y2024 y2025 total ON REPORT

WITH sales AS (
    SELECT b.br_ID, b.br_city, d.cal_year,
           SUM(f.order_total_amt - f.order_tax_amt) AS amt
    FROM   order_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_state = '&f_state'
    AND    d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY b.br_ID, b.br_city, d.cal_year
)
SELECT br_city,
       SUM(CASE WHEN cal_year = 2018 THEN amt END)    AS y2018,
       SUM(CASE WHEN cal_year = 2019 THEN amt END)    AS y2019,
       SUM(CASE WHEN cal_year = 2020 THEN amt END)    AS y2020,
       SUM(CASE WHEN cal_year = 2021 THEN amt END)    AS y2021,
       SUM(CASE WHEN cal_year = 2022 THEN amt END)    AS y2022,
       SUM(CASE WHEN cal_year = 2023 THEN amt END)    AS y2023,
       SUM(CASE WHEN cal_year = 2024 THEN amt END)    AS y2024,
       SUM(CASE WHEN cal_year = 2025 THEN amt END)    AS y2025,
       SUM(amt)                                       AS total,
       ROUND(RATIO_TO_REPORT(SUM(amt)) OVER () * 100, 1) AS share_pct,
       ROUND((SUM(CASE WHEN cal_year = &f_to THEN amt END)
              / NULLIF(SUM(amt) KEEP (DENSE_RANK FIRST ORDER BY cal_year), 0) - 1) * 100, 1) AS growth_pct,
       br_ID
FROM   sales
GROUP  BY br_ID, br_city
ORDER  BY total DESC;

-- ---- prompt 2: which branch? ---------------------------------------
SPOOL OFF
ACCEPT p_branch CHAR DEFAULT 'Petaling Jaya' PROMPT 'Branch to open up (default Petaling Jaya): '
SET TERMOUT OFF
-- resolve inside the chosen state: name match first, else the biggest
COLUMN f_br_id   NEW_VALUE f_br_id   NOPRINT
COLUMN f_branch  NEW_VALUE f_branch  NOPRINT
SELECT TO_CHAR(MAX(br_ID) KEEP (DENSE_RANK FIRST ORDER BY miss, amt DESC)) AS f_br_id,
       MAX(br_city)       KEEP (DENSE_RANK FIRST ORDER BY miss, amt DESC)  AS f_branch
FROM (
    SELECT b.br_ID, b.br_city,
           SUM(f.order_total_amt - f.order_tax_amt) AS amt,
           CASE WHEN UPPER(b.br_city) LIKE '%' || UPPER(TRIM('&p_branch')) || '%' THEN 0 ELSE 1 END AS miss
    FROM   order_fact f
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_state = '&f_state'
    GROUP  BY b.br_ID, b.br_city
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL product_category_drilldown_output.txt APPEND


-- ###################################################################
-- SECTION 3 - PRODUCT SALES BY QUARTER (the chosen branch, years down)
-- OLAP: DRILL-DOWN year -> quarter for one branch, quarters across.
-- Q4 % = Q4's share of the year (the festive weight), YOY % = the
-- year against the year before.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. PRODUCT SALES BY QUARTER (RM)' SKIP 1 -
       CENTER 'BRANCH = &f_branch, &f_from - &f_to  (DRILL-DOWN YEAR -> QUARTER)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year   HEADING 'YEAR'       FORMAT 9999
COLUMN q1         HEADING 'Q1'         FORMAT 9,999,990
COLUMN q2         HEADING 'Q2'         FORMAT 9,999,990
COLUMN q3         HEADING 'Q3'         FORMAT 9,999,990
COLUMN q4         HEADING 'Q4'         FORMAT 9,999,990
COLUMN total      HEADING 'YEAR|TOTAL' FORMAT 99,999,990
COLUMN q4_pct     HEADING 'Q4 %|OF YEAR' FORMAT 990.0
COLUMN best_q     HEADING 'BEST|QTR'   FORMAT A4
COLUMN yoy_pct    HEADING 'YOY %'      FORMAT S9,990.0
COLUMN units      HEADING 'UNITS'      FORMAT 999,990

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF q1 q2 q3 q4 total units ON REPORT

WITH sales AS (
    SELECT d.cal_year, d.cal_quarter,
           SUM(f.order_total_amt - f.order_tax_amt) AS amt,
           SUM(f.order_qty)                         AS units
    FROM   order_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year BETWEEN &f_from AND &f_to
    GROUP  BY d.cal_year, d.cal_quarter
),
yr AS (
    SELECT cal_year,
           SUM(CASE WHEN cal_quarter = 1 THEN amt END) AS q1,
           SUM(CASE WHEN cal_quarter = 2 THEN amt END) AS q2,
           SUM(CASE WHEN cal_quarter = 3 THEN amt END) AS q3,
           SUM(CASE WHEN cal_quarter = 4 THEN amt END) AS q4,
           SUM(amt)                                    AS total,
           SUM(units)                                  AS units,
           'Q' || MAX(cal_quarter) KEEP (DENSE_RANK FIRST ORDER BY amt DESC) AS best_q
    FROM   sales
    GROUP  BY cal_year
)
SELECT cal_year, q1, q2, q3, q4, total,
       ROUND(q4 / NULLIF(total, 0) * 100, 1)                                AS q4_pct,
       best_q,
       ROUND((total / NULLIF(LAG(total) OVER (ORDER BY cal_year), 0) - 1) * 100, 1) AS yoy_pct,
       units
FROM   yr
ORDER  BY cal_year;

-- ---- prompt 3: which year? -----------------------------------------
SPOOL OFF
ACCEPT p_year NUMBER DEFAULT &f_to PROMPT 'Year to open up (default &f_to): '
SET TERMOUT OFF
COLUMN f_year NEW_VALUE f_year NOPRINT
SELECT TO_CHAR(GREATEST(&f_from, LEAST(&f_to, &p_year))) AS f_year FROM dual;
CLEAR COLUMNS
SET TERMOUT ON
SPOOL product_category_drilldown_output.txt APPEND


-- ###################################################################
-- SECTION 4 - PRODUCT SALES BY CATEGORY (the chosen branch-year, ranked)
-- OLAP: DICE (branch x year), categories down RANKED by the year's
-- sales, quarters across for the trend through the year. SHARE % =
-- the category's share of the year, PEAK = its best quarter, PEAK/LOW
-- = best quarter over worst (1.0 = flat, 2.0 = strongly seasonal),
-- REALISED = sales / units. Pick a category from this list next.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. PRODUCT SALES BY CATEGORY (RM)' SKIP 1 -
       CENTER 'BRANCH = &f_branch, YEAR = &f_year  (DICE, CATEGORIES RANKED, QUARTERS ACROSS)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk        HEADING 'RANK'       FORMAT 99
COLUMN product_category HEADING 'CATEGORY' FORMAT A19
COLUMN q1         HEADING 'Q1 (RM)'    FORMAT 999,990.00
COLUMN q2         HEADING 'Q2 (RM)'    FORMAT 999,990.00
COLUMN q3         HEADING 'Q3 (RM)'    FORMAT 999,990.00
COLUMN q4         HEADING 'Q4 (RM)'    FORMAT 999,990.00
COLUMN total      HEADING 'YEAR|TOTAL (RM)' FORMAT 9,999,990.00
COLUMN share_pct  HEADING 'SHARE|%'    FORMAT 990.0
COLUMN units      HEADING 'UNITS'      FORMAT 99,990
COLUMN peak_q     HEADING 'PEAK|QTR'   FORMAT A4
COLUMN peak_low   HEADING 'PEAK/|LOW'  FORMAT 90.00
COLUMN avg_price  HEADING 'REALISED|PRICE (RM)' FORMAT 9,990.00
COLUMN products   HEADING 'PRODUCTS|SOLD' FORMAT 990

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF q1 q2 q3 q4 total units ON REPORT

WITH sales AS (
    SELECT p.product_category, d.cal_quarter,
           SUM(f.order_total_amt - f.order_tax_amt) AS amt,
           SUM(f.order_qty)                         AS units,
           COUNT(DISTINCT p.product_ID)             AS products
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    GROUP  BY p.product_category, d.cal_quarter
)
SELECT RANK() OVER (ORDER BY SUM(amt) DESC)        AS rnk,
       product_category,
       SUM(CASE WHEN cal_quarter = 1 THEN amt END) AS q1,
       SUM(CASE WHEN cal_quarter = 2 THEN amt END) AS q2,
       SUM(CASE WHEN cal_quarter = 3 THEN amt END) AS q3,
       SUM(CASE WHEN cal_quarter = 4 THEN amt END) AS q4,
       SUM(amt)                                    AS total,
       ROUND(RATIO_TO_REPORT(SUM(amt)) OVER () * 100, 1) AS share_pct,
       SUM(units)                                  AS units,
       'Q' || MAX(cal_quarter) KEEP (DENSE_RANK FIRST ORDER BY amt DESC) AS peak_q,
       ROUND(MAX(amt) / NULLIF(MIN(amt), 0), 2)    AS peak_low,
       ROUND(SUM(amt) / NULLIF(SUM(units), 0), 2)  AS avg_price,
       MAX(products)                               AS products
FROM   sales
GROUP  BY product_category
ORDER  BY rnk;

-- ---- prompt 4: which category? -------------------------------------
SPOOL OFF
ACCEPT p_cat CHAR DEFAULT 'Serum' PROMPT 'Product category to open up (default Serum): '
SET TERMOUT OFF
-- resolve inside this branch-year: name match first, else the biggest
COLUMN f_cat NEW_VALUE f_cat NOPRINT
SELECT MAX(product_category) KEEP (DENSE_RANK FIRST ORDER BY miss, amt DESC) AS f_cat
FROM (
    SELECT p.product_category,
           SUM(f.order_total_amt - f.order_tax_amt) AS amt,
           CASE WHEN UPPER(p.product_category) LIKE '%' || UPPER(TRIM('&p_cat')) || '%' THEN 0 ELSE 1 END AS miss
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    GROUP  BY p.product_category
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL product_category_drilldown_output.txt APPEND


-- ###################################################################
-- SECTION 5 - PRODUCT SALES BY PRODUCT (the chosen category)
-- OLAP: DRILL-DOWN category -> product for the chosen branch and
-- year, quarters across. SHARE % = share of the category in the year.
-- PRICE THEN = the list price in force that year (the product_dim
-- version the lines point at), PRICE NOW = the current version's list
-- price - different when the product had a price rise since (SCD2).
-- REALISED = sales / units, i.e. after loyalty and promo discounts.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. PRODUCT SALES BY PRODUCT (RM)' SKIP 1 -
       CENTER 'BRANCH = &f_branch, YEAR = &f_year, CATEGORY = &f_cat  (DRILL-DOWN CATEGORY -> PRODUCT)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN rnk          HEADING 'RANK'      FORMAT 99
COLUMN product_name HEADING 'PRODUCT'   FORMAT A32
-- one digit wider than a single product needs: the ALL row is the
-- whole category (six figures a quarter at the big branches)
COLUMN q1           HEADING 'Q1 (RM)'   FORMAT 999,990.00
COLUMN q2           HEADING 'Q2 (RM)'   FORMAT 999,990.00
COLUMN q3           HEADING 'Q3 (RM)'   FORMAT 999,990.00
COLUMN q4           HEADING 'Q4 (RM)'   FORMAT 999,990.00
COLUMN sales        HEADING 'YEAR|SALES (RM)' FORMAT 9,999,990.00
COLUMN share_pct    HEADING 'SHARE OF|CATEGORY %' FORMAT 990.0
COLUMN units        HEADING 'UNITS'     FORMAT 99,990
COLUMN avg_price    HEADING 'REALISED|PRICE (RM)' FORMAT 9,990.00
COLUMN era_price    HEADING 'PRICE THEN|(RM)' FORMAT 9,990.00
COLUMN list_price   HEADING 'PRICE NOW|(RM)'  FORMAT 9,990.00
COLUMN peak_q       HEADING 'PEAK|QTR'  FORMAT A4

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF q1 q2 q3 q4 sales units ON REPORT

WITH lines AS (
    SELECT p.product_ID, p.product_name, d.cal_quarter,
           f.order_qty, f.order_total_amt - f.order_tax_amt  AS amt,
           p.product_unit_price                              AS era_price
    FROM   order_fact  f
    JOIN   date_dim    d ON d.date_key    = f.date_key
    JOIN   branch_dim  b ON b.branch_key  = f.branch_key
    JOIN   product_dim p ON p.product_key = f.product_key
    WHERE  f.order_status = 'Completed'
    AND    b.br_ID = &f_br_id
    AND    d.cal_year = &f_year
    AND    p.product_category = '&f_cat'
),
by_q AS (
    SELECT product_ID, product_name, cal_quarter,
           SUM(amt) AS amt, SUM(order_qty) AS units, MAX(era_price) AS era_price
    FROM   lines
    GROUP  BY product_ID, product_name, cal_quarter
),
cur_price AS (
    SELECT product_ID, product_unit_price
    FROM   product_dim WHERE is_current_flag = 'Y'
)
SELECT RANK() OVER (ORDER BY SUM(q.amt) DESC)              AS rnk,
       q.product_name,
       SUM(CASE WHEN q.cal_quarter = 1 THEN q.amt END)     AS q1,
       SUM(CASE WHEN q.cal_quarter = 2 THEN q.amt END)     AS q2,
       SUM(CASE WHEN q.cal_quarter = 3 THEN q.amt END)     AS q3,
       SUM(CASE WHEN q.cal_quarter = 4 THEN q.amt END)     AS q4,
       SUM(q.amt)                                          AS sales,
       ROUND(RATIO_TO_REPORT(SUM(q.amt)) OVER () * 100, 1) AS share_pct,
       SUM(q.units)                                        AS units,
       ROUND(SUM(q.amt) / NULLIF(SUM(q.units), 0), 2)      AS avg_price,
       MAX(q.era_price)                                    AS era_price,
       MAX(c.product_unit_price)                           AS list_price,
       'Q' || MAX(q.cal_quarter) KEEP (DENSE_RANK FIRST ORDER BY q.amt DESC) AS peak_q
FROM   by_q q
LEFT   JOIN cur_price c ON c.product_ID = q.product_ID
GROUP  BY q.product_ID, q.product_name
ORDER  BY rnk;

PROMPT
PROMPT +==========================================================+
PROMPT |        END OF PRODUCT CATEGORY DRILL-DOWN REPORT         |
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
UNDEFINE f_from
UNDEFINE f_to
UNDEFINE v2018
UNDEFINE v2019
UNDEFINE v2020
UNDEFINE v2021
UNDEFINE v2022
UNDEFINE v2023
UNDEFINE v2024
UNDEFINE v2025
UNDEFINE p_state
UNDEFINE p_branch
UNDEFINE p_year
UNDEFINE p_cat
UNDEFINE f_state
UNDEFINE f_br_id
UNDEFINE f_branch
UNDEFINE f_year
UNDEFINE f_cat
UNDEFINE run_dt
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
