-- ===================================================================
-- 03_customer_geographic_expansion.sql
-- CUSTOMER LOCATION ANALYSIS - WHICH AREA NEEDS THE NEXT BRANCH?
--   company per year  ->  every CUSTOMER HOME STATE, years across
--   ->  pick a STATE  ->  its CITIES, and how much of each city's
--       money is spent at home vs somewhere else
--   ->  the branches standing in that state, for comparison
--   ->  every CITY in the company ranked by demand nobody serves
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Fz\03_customer_geographic_expansion.sql
--
-- PARAMETERS (the year range at the start; the state AFTER section 2
-- has printed, so the choice is made from what is on screen)
--   start year, end year   at the start   defaults 2019 and 2025 -
--                          they frame EVERY section (year columns
--                          outside the range are hidden, and totals /
--                          averages / share / growth / branch counts
--                          are computed on the range only)
--   state      after section 2   default Selangor
--   A name that matches nothing falls back to the biggest state, so
--   the drill never dead-ends. The spool is paused around the prompt,
--   so the output file holds only the tables.
--
-- THE QUESTION
--   Start from the CUSTOMER, not the shop. customer_dim.cus_state and
--   cus_city say where the person who paid actually lives;
--   branch_dim.br_state / br_city say where they had to go to spend it.
--   When those two disagree the customer TRAVELLED, and travelling
--   customers are the evidence for a branch closer to them.
--
--   Every ringgit a customer spends is therefore one of:
--     AT HOME       spent at a branch in their own city
--     IN STATE      another city, but still their own state
--     TRAVELLED OUT another state entirely
--   The last two together are what a branch nearer to them would be
--   opening to capture. That is the whole subject of this report.
--
-- WHAT IT ANSWERS
--   1. What does the company earn each year, from how many customers,
--      through how many branches - and how much of it involved the
--      customer leaving their own city?
--   2. Which STATES do our customers live in, what do they spend, how
--      many branches serve them, and how much of their money leaves
--      the state?
--   3. Inside one state, CITY BY CITY: who lives there, what do they
--      spend, is there a branch in that city, and how much of their
--      money is spent at home?
--   4. And the branches that stand in that state - what is each one
--      actually living on?
--   5. Across the whole company, which CITY has the most spending that
--      no branch of its own is capturing? (the shortlist)
--
--   And before any of that: IS THERE ANYWHERE we take money from and
--   have no shop in at all? Section 2 answers that on its own, because
--   it is the first thing an expansion decision needs to rule in or
--   out. Everything after it is about places that ARE served, but not
--   well enough.
--
--   A NOTE ON THIS DATASET. The customer base lives in exactly the same
--   17 cities and 8 states the branches stand in - verified against the
--   warehouse: COUNT(DISTINCT cus_city) = COUNT(DISTINCT br_city) = 17
--   and no cus_city is missing from branch_dim. So over the full
--   2019-2025 range section 2 prints NONE, and that is the honest
--   answer, not a bug. The gap in this data is a gap in TIME: four
--   cities had paying residents for years before a branch reached them.
--   Narrow the range to 2019-2023 and section 2 names all four.
--   (customer_dim carries cus_city and cus_state only - there is no
--   postcode in the warehouse, and the generator assigns postcodes at
--   random inside a city, so no finer geography is available.)
--
-- THE CUBE
--   facts     order_fact       (Completed only)
--             reservation_fact (Completed only)
--             The two are UNIONed into one revenue stream - a branch
--             sells products and services, so both count.
--   dims      customer_dim.cus_state / cus_city    THE BUYER (the axis)
--             branch_dim.br_state / br_city / br_ID  where it was spent
--             date_dim.cal_year
--   measures  Revenue (RM)   = (order_total_amt - order_tax_amt)
--                            + (serv_total_amt  - serv_tax_amt)
--                            SST is passed to the government, not revenue
--             Customers      = COUNT(DISTINCT cus_ID)
--             Branches       = COUNT(DISTINCT br_ID) that actually
--                              traded in the year (see the note below)
--             AT HOME %      revenue spent in the customer's own city
--             TRAVEL %       100 - AT HOME %, the money that left town
--             OUT OF STATE % the part that left the state as well
--             AVG PER BRANCH the state's revenue in the last year of
--                            the range / its branches in that year
--
-- WHY THE BRANCH COUNT COMES FROM THE FACTS
--   branch_dim has NO opening date (br_ID, br_name, br_city, br_state,
--   br_email + the SCD2 columns - that is all), and every SCD2 first
--   version starts 2018-01-01, so effective_start_date says nothing
--   about when a branch opened. A branch is therefore counted as
--   trading in a year when it has fact rows in that year. That is what
--   makes Subang Jaya, Bukit Jalil, Seremban and Kuantan correctly
--   show NO branch for 2019-2023 and one from 2024.
--
-- WHY GROUP BY cus_city / cus_ID AND NOT customer_key
--   customer_dim is SCD Type 2: a customer whose email or tier changed
--   has more than one customer_key row. Counting keys would count that
--   person twice. cus_ID is the natural key, so DISTINCT cus_ID is the
--   real headcount, and grouping on cus_city / cus_state rolls every
--   version of a customer into one line. Same for br_ID / br_city.
--
-- REPORT SECTIONS  (each one is ONE OLAP operation)
--   1  COMPANY BY YEAR         ROLL-UP    the yardstick
--   2  CUSTOMERS, NO BRANCH    SLICE      every place we sell to but
--                                         do not stand in  <- THE GAP
--   3  CUSTOMER HOME STATE     PIVOT      states down, years across
--         -> prompt: state
--   4  CUSTOMER HOME CITY      DRILL-DOWN state -> city, the cities of
--                                         the chosen state, at home vs
--                                         travelled  <- THE KEY TABLE
--   5  THE STATE'S BRANCHES    DRILL-DOWN state -> branch, what each
--                                         shop actually lives on
--   6  EVERY CITY RANKED       RANKED     the company-wide shortlist
--
-- WHAT TO LOOK FOR  (defaults 2019-2025 > Selangor, revision-5 data)
--   - Section 2 on the DEFAULT range prints NONE: there is nowhere we
--     sell to and have no branch in. That is the real state of the
--     estate today, and it means the decision is not "find a blank spot
--     on the map" but "which served city is our branch failing to
--     hold" - section 6, and Selayang / Gombak in particular.
--   - Section 1: RM 124.7 M over seven years, 13 branches until 2024
--     then 17, AVG PER BRANCH RM 1.04 M (2019) to RM 1.80 M (2025) -
--     dipping to RM 1.41 M in 2024 because four branches opened
--     mid-ramp. TRAVEL % is the headline: 31 % of revenue in 2019-2021
--     involved leaving your own city, then it STEPS to 47.6 % in 2022
--     and stays near 48 %. That is the year the shop went online; half
--     the company's money now comes from customers who did not buy in
--     their own town. OUT OF STATE % does the same, 10.4 % to 24.8 %.
--   - Section 3: eight home states. Selangor RM 56.6 M from residents
--     (6 branches, RM 2.15 M each) and W.P. RM 40.3 M (5 branches,
--     RM 1.81 M each) dominate. OUT OF STATE % rises as coverage falls:
--     15.4 % (Selangor), 18.9 % (W.P.), 20.9 % (Johor), 26.5 % (Pulau
--     Pinang), 34.6 % (Melaka), 36.5 % (Perak), 51.0 % (Negeri
--     Sembilan), 54.1 % (Pahang). Note Johor's single branch earns the
--     most of any branch in the company (RM 2,199,274 in 2025) and
--     Perak's the least (RM 939,689) - Ipoh is the one losing footfall
--     to the web shop.
--   - Section 4 (Selangor) is the key table. AT HOME % falls straight
--     down the list: Petaling Jaya 71.2 %, Shah Alam 52.7, Puchong
--     52.6, Klang 50.0, Selayang 42.2, Subang Jaya 31.4. Only PJ really
--     holds its own neighbourhood. Subang Jaya's year row shows why -
--     RM 255 k to RM 358 k while it had NO branch, then RM 1,527,081 in
--     2024 when one opened, +777.8 % growth. Run the same section for
--     Wilayah Persekutuan over 2024-2025 for the same shape: Kuala
--     Lumpur keeps 62.0 % at home, Gombak only 39.6 %.
--   - Section 5 (Selangor branches): every shop takes 54-57 % from its
--     OWN CITY, about 30 % from the rest of the state and only 10-14 %
--     from other states. Petaling Jaya is 33.0 % of the state, Subang
--     Jaya only 5.5 % because it opened in 2024. Cross-check it against
--     section 4: a branch's OWN CITY figure equals that city's SPENT AT
--     HOME in section 6 (Petaling Jaya, RM 9,963,265 in both).
--   - THE BACK-TEST - run the range 2019-2023, the years before the
--     last expansion. Section 2 names the gap outright, and section 6
--     ranks it at the top:
--         Bukit Jalil   BR 0   402 residents  RM 1,131,590  100.0 %
--         Subang Jaya   BR 0   437 residents  RM 1,345,463  100.0 %
--         Seremban      BR 0   133 residents  RM   337,828  100.0 %
--         Kuantan       BR 0   142 residents  RM   419,928  100.0 %
--     Those are EXACTLY the four cities Glow Beauty opened branches in
--     on 2024-01-01, in the order of how much was at stake. The report,
--     on data that predates the decision, reproduces it completely -
--     which is the reason to trust what it says about the next one.
--     Note that Subang Jaya and Bukit Jalil were the two BIGGEST
--     opportunities and both sit inside states that already had 5 or 6
--     branches: at state grain they are invisible, and only the drill
--     to CITY finds them.
--   - Section 6 on the full range is the current shortlist. The 2024
--     openings still head it (Bukit Jalil 69.5 %, Subang Jaya 68.6 %)
--     because five of the seven years had no branch there - that is
--     history, not opportunity. The live candidates are the next two:
--         SELAYANG   57.8 % travelled, RM 4,850,234 leaving, 2,016
--                    residents, and it HAS a branch - a shop that is
--                    not holding its own neighbourhood
--         GOMBAK     55.4 % travelled, RM 4,244,397 leaving, 1,899
--                    residents, same story
--     At the other end Johor Bahru (20.9 %), George Town (26.5 %) and
--     Petaling Jaya (28.8 %) are the well-served cities.
--   - Try: 2019-2023 for the back-test above, Wilayah Persekutuan for
--     the five-branch state where Gombak still leaks 60 %, Perak for
--     the single branch going backwards, a reversed range (2025 then
--     2019 - it is clamped, not an error), a partial name like
--     'Wilayah', or a nonsense name to land on the biggest state.
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
ACCEPT p_from NUMBER DEFAULT 2019 PROMPT 'Start year (default 2019): '
ACCEPT p_to   NUMBER DEFAULT 2025 PROMPT 'End year   (default 2025): '

-- ---- values reused in every title ---------------------------------
-- TERMOUT OFF hides these helper queries (only works when the file is
-- run with @, which is how this report is meant to be run).
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

-- clamp the range to the data (2019-2025) and put it the right way round
COLUMN f_from NEW_VALUE f_from NOPRINT
COLUMN f_to   NEW_VALUE f_to   NOPRINT
SELECT TO_CHAR(GREATEST(2019, LEAST(&p_from, &p_to)))  AS f_from,
       TO_CHAR(LEAST(2025, GREATEST(&p_from, &p_to)))  AS f_to
FROM   dual;

-- one PRINT / NOPRINT switch per year column, so the pivots only show
-- the years inside the chosen range
COLUMN v2019 NEW_VALUE v2019 NOPRINT
COLUMN v2020 NEW_VALUE v2020 NOPRINT
COLUMN v2021 NEW_VALUE v2021 NOPRINT
COLUMN v2022 NEW_VALUE v2022 NOPRINT
COLUMN v2023 NEW_VALUE v2023 NOPRINT
COLUMN v2024 NEW_VALUE v2024 NOPRINT
COLUMN v2025 NEW_VALUE v2025 NOPRINT
SELECT CASE WHEN 2019 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2019,
       CASE WHEN 2020 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2020,
       CASE WHEN 2021 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2021,
       CASE WHEN 2022 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2022,
       CASE WHEN 2023 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2023,
       CASE WHEN 2024 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2024,
       CASE WHEN 2025 BETWEEN &f_from AND &f_to THEN 'PRINT' ELSE 'NOPRINT' END AS v2025
FROM   dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL customer_geographic_expansion_output.txt


-- ###################################################################
-- SECTION 1 - THE COMPANY, YEAR BY YEAR
-- OLAP: ROLL-UP to the top of every dimension. The yardstick for
-- everything below. AT HOME is revenue where the customer bought in
-- their OWN CITY; TRAVEL % is the rest. Watch TRAVEL % jump in 2022 -
-- that is the year the shop went online and customers stopped being
-- tied to the branch nearest them. AVG PER BRANCH dips in 2024
-- because four branches opened mid-ramp.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. THE COMPANY, YEAR BY YEAR (RM)' SKIP 1 -
       CENTER 'ALL CUSTOMERS, &f_from - &f_to  (ROLL-UP)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year    HEADING 'YEAR'            FORMAT 9999
COLUMN revenue     HEADING 'REVENUE (RM)'    FORMAT 999,999,990
COLUMN customers   HEADING 'CUSTO|MERS'      FORMAT 999,990
COLUMN branches    HEADING 'BRAN|CHES'       FORMAT 990
COLUMN avg_per_br  HEADING 'AVG PER|BRANCH'  FORMAT 99,999,990
COLUMN home_amt    HEADING 'AT HOME (RM)'    FORMAT 999,999,990
COLUMN travel_amt  HEADING 'TRAVELLED (RM)'  FORMAT 999,999,990
COLUMN travel_pct  HEADING 'TRA|VEL %'       FORMAT 990.0
COLUMN out_pct     HEADING 'OUT OF|STATE %'  FORMAT 990.0
COLUMN yoy_pct     HEADING 'YOY %'           FORMAT S9,990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF revenue home_amt travel_amt ON REPORT

-- The revenue stream every section uses: product lines and service
-- lines unioned, Completed only, pre-aggregated to keep it light.
WITH rev AS (
    SELECT cus_ID, cus_city, cus_state, br_ID, br_city, br_state, cal_year,
           SUM(amt) AS amt
    FROM (
        SELECT c.cus_ID, c.cus_city, c.cus_state,
               b.br_ID, b.br_city, b.br_state, d.cal_year,
               SUM(f.order_total_amt - f.order_tax_amt) AS amt
        FROM   order_fact   f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        JOIN   branch_dim   b ON b.branch_key   = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_ID, c.cus_city, c.cus_state,
                  b.br_ID, b.br_city, b.br_state, d.cal_year
        UNION ALL
        SELECT c.cus_ID, c.cus_city, c.cus_state,
               b.br_ID, b.br_city, b.br_state, d.cal_year,
               SUM(f.serv_total_amt - f.serv_tax_amt)
        FROM   reservation_fact f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        JOIN   branch_dim   b ON b.branch_key   = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_ID, c.cus_city, c.cus_state,
                  b.br_ID, b.br_city, b.br_state, d.cal_year
    )
    GROUP  BY cus_ID, cus_city, cus_state, br_ID, br_city, br_state, cal_year
)
SELECT cal_year,
       SUM(amt)                                              AS revenue,
       COUNT(DISTINCT cus_ID)                                AS customers,
       COUNT(DISTINCT br_ID)                                 AS branches,
       ROUND(SUM(amt) / NULLIF(COUNT(DISTINCT br_ID), 0))    AS avg_per_br,
       SUM(CASE WHEN cus_city =  br_city THEN amt ELSE 0 END) AS home_amt,
       SUM(CASE WHEN cus_city <> br_city THEN amt ELSE 0 END) AS travel_amt,
       ROUND(SUM(CASE WHEN cus_city <> br_city THEN amt ELSE 0 END)
             / NULLIF(SUM(amt), 0) * 100, 1)                 AS travel_pct,
       ROUND(SUM(CASE WHEN cus_state <> br_state THEN amt ELSE 0 END)
             / NULLIF(SUM(amt), 0) * 100, 1)                 AS out_pct,
       ROUND((SUM(amt) / NULLIF(LAG(SUM(amt)) OVER (ORDER BY cal_year), 0) - 1) * 100, 1) AS yoy_pct
FROM   rev
GROUP  BY cal_year
ORDER  BY cal_year;


-- ###################################################################
-- SECTION 2 - LOCATIONS WITH CUSTOMERS BUT NO BRANCH   <- THE GAP
-- OLAP: SLICE on the gap itself. Every city our customers live in is
-- checked against the cities a branch actually traded in during &f_to,
-- the last year of the range. Whatever is left over is a place with
-- paying residents and nowhere of their own to spend it: 100 % of that
-- money goes somewhere else, by definition.
--
-- READ THIS FIRST - it is the direct answer to "where is there a gap".
-- If it prints NONE, then every city our customers live in already has
-- a branch, and the expansion question becomes one of UNDER-served
-- cities instead: section 6 ranks those by how much of their money
-- still leaves town.
--
-- ON THE SHIPPED DATA the customer base lives in exactly the same 17
-- cities the branches stand in, so the full 2019-2025 range prints
-- NONE. Set the range to 2019-2023 and four cities appear - Subang
-- Jaya, Bukit Jalil, Seremban and Kuantan - which are precisely the
-- four Glow Beauty opened branches in on 2024-01-01.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. CUSTOMERS WITH NO BRANCH OF THEIR OWN' SKIP 1 -
       CENTER 'CITIES WE SELL TO BUT DO NOT STAND IN, &f_from - &f_to  (THE GAP)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN g_state    HEADING 'STATE'                    FORMAT A20
COLUMN g_city     HEADING 'CITY WITH NO BRANCH'      FORMAT A34
COLUMN residents  HEADING 'RESI|DENTS'               FORMAT 999,990
COLUMN total      HEADING 'THEIR SPEND|&f_from-&f_to (RM)' FORMAT 99,999,990
COLUMN last_amt   HEADING 'OF IT IN|&f_to (RM)'      FORMAT 99,999,990
COLUMN first_year HEADING 'FIRST|YEAR'               FORMAT 9999
COLUMN growth_pct HEADING 'GROWTH %|1ST->&f_to'      FORMAT S9,990.0

WITH rev AS (
    SELECT cus_ID, cus_city, cus_state, cal_year, SUM(amt) AS amt
    FROM (
        SELECT c.cus_ID, c.cus_city, c.cus_state, d.cal_year,
               SUM(f.order_total_amt - f.order_tax_amt) AS amt
        FROM   order_fact   f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_ID, c.cus_city, c.cus_state, d.cal_year
        UNION ALL
        SELECT c.cus_ID, c.cus_city, c.cus_state, d.cal_year,
               SUM(f.serv_total_amt - f.serv_tax_amt)
        FROM   reservation_fact f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_ID, c.cus_city, c.cus_state, d.cal_year
    )
    GROUP  BY cus_ID, cus_city, cus_state, cal_year
),
-- the cities a branch actually traded in during the LAST year of the
-- range: branch_dim has no opening date, so the facts are the record
served AS (
    SELECT DISTINCT b.br_city
    FROM   order_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year = &f_to
),
gap AS (
    SELECT r.cus_state                                       AS g_state,
           r.cus_city                                        AS g_city,
           COUNT(DISTINCT r.cus_ID)                          AS residents,
           SUM(r.amt)                                        AS total,
           SUM(CASE WHEN r.cal_year = &f_to THEN r.amt END)  AS last_amt,
           MIN(r.cal_year)                                   AS first_year,
           ROUND((SUM(CASE WHEN r.cal_year = &f_to THEN r.amt END)
                  / NULLIF(SUM(r.amt) KEEP (DENSE_RANK FIRST ORDER BY r.cal_year), 0) - 1) * 100, 1) AS growth_pct
    FROM   rev r
    WHERE  r.cus_city NOT IN (SELECT br_city FROM served)
    GROUP  BY r.cus_state, r.cus_city
)
SELECT g_state, g_city, residents, total, last_amt, first_year, growth_pct
FROM   gap
UNION  ALL
-- printed only when the gap is empty, so the section never returns a
-- bare heading the reader has to interpret
SELECT 'NONE', 'every customer city has a branch', NULL, NULL, NULL, NULL, NULL
FROM   dual
WHERE  NOT EXISTS (SELECT 1 FROM gap)
ORDER  BY 4 DESC NULLS LAST;


-- ###################################################################
-- SECTION 3 - WHAT EACH STATE'S CUSTOMERS SPEND (years across)
-- OLAP: PIVOT - years of the chosen range across, CUSTOMER HOME states
-- down. Every ringgit is credited to the state the BUYER lives in,
-- wherever they happened to spend it.
--
-- BR is the branches standing in that state in &f_to and AVG PER BR is
-- what one of them earned that year, so the buyer's side and the
-- seller's side sit on the same row. OUT OF STATE % is how much of the
-- residents' money left the state altogether. Pick a state next.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. SPEND BY CUSTOMER HOME STATE (RM)' SKIP 1 -
       CENTER 'WHERE OUR CUSTOMERS LIVE, &f_from - &f_to  (PIVOT: YEARS ACROSS)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cus_state  HEADING 'CUSTOMER HOME STATE' FORMAT A20
COLUMN branches   HEADING 'BR|&f_to'     FORMAT 90
COLUMN y2019      HEADING '2019'         FORMAT 99,999,990 &v2019
COLUMN y2020      HEADING '2020'         FORMAT 99,999,990 &v2020
COLUMN y2021      HEADING '2021'         FORMAT 99,999,990 &v2021
COLUMN y2022      HEADING '2022'         FORMAT 99,999,990 &v2022
COLUMN y2023      HEADING '2023'         FORMAT 99,999,990 &v2023
COLUMN y2024      HEADING '2024'         FORMAT 99,999,990 &v2024
COLUMN y2025      HEADING '2025'         FORMAT 99,999,990 &v2025
COLUMN total      HEADING 'TOTAL|&f_from-&f_to' FORMAT 999,999,990
COLUMN out_pct    HEADING 'OUT OF|STATE %' FORMAT 990.0
COLUMN avg_per_br HEADING 'AVG PER|BR &f_to'  FORMAT 99,999,990

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF y2019 y2020 y2021 y2022 y2023 y2024 y2025 total ON REPORT

WITH rev AS (
    SELECT cus_state, br_state, br_ID, cal_year, SUM(amt) AS amt
    FROM (
        SELECT c.cus_state, b.br_state, b.br_ID, d.cal_year,
               SUM(f.order_total_amt - f.order_tax_amt) AS amt
        FROM   order_fact   f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        JOIN   branch_dim   b ON b.branch_key   = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_state, b.br_state, b.br_ID, d.cal_year
        UNION ALL
        SELECT c.cus_state, b.br_state, b.br_ID, d.cal_year,
               SUM(f.serv_total_amt - f.serv_tax_amt)
        FROM   reservation_fact f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        JOIN   branch_dim   b ON b.branch_key   = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_state, b.br_state, b.br_ID, d.cal_year
    )
    GROUP  BY cus_state, br_state, br_ID, cal_year
),
-- the seller's side, keyed on the state the SHOP stands in
sell AS (
    SELECT br_state,
           COUNT(DISTINCT CASE WHEN cal_year = &f_to THEN br_ID END) AS branches,
           SUM(CASE WHEN cal_year = &f_to THEN amt END)              AS amt_last
    FROM   rev
    GROUP  BY br_state
),
buy AS (
    SELECT cus_state, cal_year,
           SUM(amt)                                                 AS amt,
           SUM(CASE WHEN cus_state <> br_state THEN amt ELSE 0 END)  AS out_amt
    FROM   rev
    GROUP  BY cus_state, cal_year
)
SELECT b.cus_state,
       NVL(MAX(s.branches), 0)                        AS branches,
       -- no ELSE, so a year the state produced nothing prints blank
       SUM(CASE WHEN b.cal_year = 2019 THEN b.amt END) AS y2019,
       SUM(CASE WHEN b.cal_year = 2020 THEN b.amt END) AS y2020,
       SUM(CASE WHEN b.cal_year = 2021 THEN b.amt END) AS y2021,
       SUM(CASE WHEN b.cal_year = 2022 THEN b.amt END) AS y2022,
       SUM(CASE WHEN b.cal_year = 2023 THEN b.amt END) AS y2023,
       SUM(CASE WHEN b.cal_year = 2024 THEN b.amt END) AS y2024,
       SUM(CASE WHEN b.cal_year = 2025 THEN b.amt END) AS y2025,
       SUM(b.amt)                                      AS total,
       ROUND(SUM(b.out_amt) / NULLIF(SUM(b.amt), 0) * 100, 1)  AS out_pct,
       ROUND(MAX(s.amt_last) / NULLIF(MAX(s.branches), 0))     AS avg_per_br
FROM   buy b
LEFT   JOIN sell s ON s.br_state = b.cus_state
GROUP  BY b.cus_state
ORDER  BY total DESC;

-- ---- prompt: which state? (spool paused, helper hidden) ------------
SPOOL OFF
ACCEPT p_state CHAR DEFAULT 'Selangor' PROMPT 'State to open up (default Selangor): '
SET TERMOUT OFF
-- resolve to a real cus_state value: name match first, else the biggest
COLUMN f_state NEW_VALUE f_state NOPRINT
SELECT MAX(cus_state) KEEP (DENSE_RANK FIRST ORDER BY miss, amt DESC) AS f_state
FROM (
    SELECT c.cus_state,
           SUM(f.order_total_amt - f.order_tax_amt) AS amt,
           CASE WHEN UPPER(c.cus_state) LIKE '%' || UPPER(TRIM('&p_state')) || '%'
                THEN 0 ELSE 1 END                   AS miss
    FROM   order_fact   f
    JOIN   customer_dim c ON c.customer_key = f.customer_key
    WHERE  f.order_status = 'Completed'
    GROUP  BY c.cus_state
);
CLEAR COLUMNS
SET TERMOUT ON
SPOOL customer_geographic_expansion_output.txt APPEND


-- ###################################################################
-- SECTION 4 - THE CITIES OF THE CHOSEN STATE   <- THE KEY TABLE
-- OLAP: DRILL-DOWN state -> city, rows are the CITIES OUR CUSTOMERS
-- LIVE IN, years across.
--
-- BR is how many branches stood in that city in &f_to - a ZERO here is
-- the strongest signal in the whole report: paying customers, no shop.
-- AT HOME % is the share of the city's money spent at a branch in that
-- same city, TRAVEL % the rest. A city with no branch is 0 % at home by
-- definition; a city WITH a branch that still shows a low AT HOME % is
-- one whose own shop is not holding its neighbourhood.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. THE CITIES OF &f_state (RM)' SKIP 1 -
       CENTER 'WHERE CUSTOMERS LIVE AND WHETHER THEY CAN SHOP THERE, &f_from - &f_to' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cus_city   HEADING 'CUSTOMER|HOME CITY' FORMAT A15
COLUMN has_branch HEADING 'BRANCH|IN &f_to' FORMAT A9
COLUMN customers  HEADING 'CUSTO|MERS'  FORMAT 999,990
COLUMN y2019      HEADING '2019'        FORMAT 99,999,990 &v2019
COLUMN y2020      HEADING '2020'        FORMAT 99,999,990 &v2020
COLUMN y2021      HEADING '2021'        FORMAT 99,999,990 &v2021
COLUMN y2022      HEADING '2022'        FORMAT 99,999,990 &v2022
COLUMN y2023      HEADING '2023'        FORMAT 99,999,990 &v2023
COLUMN y2024      HEADING '2024'        FORMAT 99,999,990 &v2024
COLUMN y2025      HEADING '2025'        FORMAT 99,999,990 &v2025
COLUMN total      HEADING 'TOTAL|&f_from-&f_to' FORMAT 99,999,990
COLUMN home_pct   HEADING 'AT|HOME %'   FORMAT 990.0
COLUMN travel_pct HEADING 'TRA|VEL %'   FORMAT 990.0
COLUMN growth_pct HEADING 'GROWTH %|1ST->&f_to' FORMAT S9,990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'STATE' OF y2019 y2020 y2021 y2022 y2023 y2024 y2025 total ON REPORT

WITH rev AS (
    SELECT cus_ID, cus_city, br_city, cal_year, SUM(amt) AS amt
    FROM (
        SELECT c.cus_ID, c.cus_city, b.br_city, d.cal_year,
               SUM(f.order_total_amt - f.order_tax_amt) AS amt
        FROM   order_fact   f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        JOIN   branch_dim   b ON b.branch_key   = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    c.cus_state = '&f_state'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_ID, c.cus_city, b.br_city, d.cal_year
        UNION ALL
        SELECT c.cus_ID, c.cus_city, b.br_city, d.cal_year,
               SUM(f.serv_total_amt - f.serv_tax_amt)
        FROM   reservation_fact f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        JOIN   branch_dim   b ON b.branch_key   = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    c.cus_state = '&f_state'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_ID, c.cus_city, b.br_city, d.cal_year
    )
    GROUP  BY cus_ID, cus_city, br_city, cal_year
),
-- branches trading in each CITY in the last year of the range; this is
-- the only record of an opening, branch_dim carries no open date
brc AS (
    SELECT b.br_city, COUNT(DISTINCT b.br_ID) AS branches
    FROM   order_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year = &f_to
    GROUP  BY b.br_city
)
SELECT r.cus_city,
       -- spelled out, not a 0, so an unserved city cannot be skimmed past
       CASE WHEN NVL(MAX(k.branches), 0) = 0
            THEN 'NO BRANCH' ELSE 'yes' END             AS has_branch,
       COUNT(DISTINCT r.cus_ID)                         AS customers,
       SUM(CASE WHEN r.cal_year = 2019 THEN r.amt END)  AS y2019,
       SUM(CASE WHEN r.cal_year = 2020 THEN r.amt END)  AS y2020,
       SUM(CASE WHEN r.cal_year = 2021 THEN r.amt END)  AS y2021,
       SUM(CASE WHEN r.cal_year = 2022 THEN r.amt END)  AS y2022,
       SUM(CASE WHEN r.cal_year = 2023 THEN r.amt END)  AS y2023,
       SUM(CASE WHEN r.cal_year = 2024 THEN r.amt END)  AS y2024,
       SUM(CASE WHEN r.cal_year = 2025 THEN r.amt END)  AS y2025,
       SUM(r.amt)                                       AS total,
       ROUND(SUM(CASE WHEN r.cus_city =  r.br_city THEN r.amt ELSE 0 END)
             / NULLIF(SUM(r.amt), 0) * 100, 1)          AS home_pct,
       ROUND(SUM(CASE WHEN r.cus_city <> r.br_city THEN r.amt ELSE 0 END)
             / NULLIF(SUM(r.amt), 0) * 100, 1)          AS travel_pct,
       ROUND((SUM(CASE WHEN r.cal_year = &f_to THEN r.amt END)
              / NULLIF(SUM(r.amt) KEEP (DENSE_RANK FIRST ORDER BY r.cal_year), 0) - 1) * 100, 1) AS growth_pct
FROM   rev r
LEFT   JOIN brc k ON k.br_city = r.cus_city
GROUP  BY r.cus_city
ORDER  BY total DESC;


-- ###################################################################
-- SECTION 5 - THE BRANCHES STANDING IN THAT STATE
-- OLAP: DRILL-DOWN state -> branch, the seller's side of section 3.
-- Each shop's revenue is split three ways by where its customers live:
--   OWN CITY    the customer lives in the branch's own city
--   SAME STATE  another city, same state (they crossed town)
--   OTHER STATE another state entirely
-- The three add up to the branch's total.
--
-- Read it against section 4: a city there with no branch and a lot of
-- money is being served by one of the shops listed here, and its
-- SAME STATE column is where that money is landing.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. THE BRANCHES OF &f_state (RM)' SKIP 1 -
       CENTER 'EACH SPLIT BY WHERE ITS CUSTOMERS LIVE, &f_from - &f_to  (DRILL-DOWN)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city     HEADING 'BRANCH'           FORMAT A15
COLUMN own_amt     HEADING 'OWN CITY (RM)'    FORMAT 99,999,990
COLUMN state_amt   HEADING 'SAME STATE (RM)'  FORMAT 99,999,990
COLUMN out_amt     HEADING 'OTHER STATE (RM)' FORMAT 99,999,990
COLUMN total       HEADING 'TOTAL (RM)'       FORMAT 99,999,990
COLUMN own_pct     HEADING 'OWN|CITY %'       FORMAT 990.0
COLUMN out_pct     HEADING 'OTHER|STATE %'    FORMAT 990.0
COLUMN customers   HEADING 'CUSTO|MERS'       FORMAT 999,990
COLUMN share_pct   HEADING 'SHARE OF|STATE %' FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'STATE' OF own_amt state_amt out_amt total ON REPORT

WITH rev AS (
    SELECT cus_ID, cus_city, cus_state, br_ID, br_city, br_state, SUM(amt) AS amt
    FROM (
        SELECT c.cus_ID, c.cus_city, c.cus_state, b.br_ID, b.br_city, b.br_state,
               SUM(f.order_total_amt - f.order_tax_amt) AS amt
        FROM   order_fact   f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        JOIN   branch_dim   b ON b.branch_key   = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    b.br_state = '&f_state'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_ID, c.cus_city, c.cus_state, b.br_ID, b.br_city, b.br_state
        UNION ALL
        SELECT c.cus_ID, c.cus_city, c.cus_state, b.br_ID, b.br_city, b.br_state,
               SUM(f.serv_total_amt - f.serv_tax_amt)
        FROM   reservation_fact f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        JOIN   branch_dim   b ON b.branch_key   = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    b.br_state = '&f_state'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_ID, c.cus_city, c.cus_state, b.br_ID, b.br_city, b.br_state
    )
    GROUP  BY cus_ID, cus_city, cus_state, br_ID, br_city, br_state
)
SELECT br_city,
       SUM(CASE WHEN cus_city = br_city THEN amt ELSE 0 END)          AS own_amt,
       SUM(CASE WHEN cus_city <> br_city AND cus_state = br_state
                THEN amt ELSE 0 END)                                  AS state_amt,
       SUM(CASE WHEN cus_state <> br_state THEN amt ELSE 0 END)       AS out_amt,
       SUM(amt)                                                      AS total,
       ROUND(SUM(CASE WHEN cus_city = br_city THEN amt ELSE 0 END)
             / NULLIF(SUM(amt), 0) * 100, 1)                         AS own_pct,
       ROUND(SUM(CASE WHEN cus_state <> br_state THEN amt ELSE 0 END)
             / NULLIF(SUM(amt), 0) * 100, 1)                         AS out_pct,
       COUNT(DISTINCT cus_ID)                                        AS customers,
       ROUND(RATIO_TO_REPORT(SUM(amt)) OVER () * 100, 1)             AS share_pct
FROM   rev
GROUP  BY br_ID, br_city
ORDER  BY total DESC;


-- ###################################################################
-- SECTION 6 - EVERY CITY RANKED: WHERE IS THERE ROOM?
-- OLAP: the ROLL-UP that closes the drill - back out to every city in
-- the company, read as a market rather than as a place with a shop.
--
-- TRAVELLED (RM) is what that city's residents spent somewhere other
-- than their own city: the demand no local branch is capturing, and
-- what a new one would open to take. Ordered by BR ascending then
-- TRAVEL % descending, so a city with NO branch comes first. Ranking
-- on travelled ringgit alone would put the biggest cities on top
-- simply because they are big, which is not an expansion signal.
--
-- Run the range 2019-2023 to see this table before the last expansion:
-- the four cities of section 2 head it at TRAVEL % = 100.
--
-- This is a DEMAND table. It makes no rent, payroll or payback
-- assumption - that judgement belongs to whoever reads it.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 6. EVERY CITY RANKED BY UNSERVED DEMAND' SKIP 1 -
       CENTER 'ALL CITIES, &f_from - &f_to  (CITIES WITHOUT A BRANCH FIRST)' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cus_city   HEADING 'CUSTOMER|HOME CITY' FORMAT A15
COLUMN cus_state  HEADING 'STATE'         FORMAT A20
COLUMN has_branch HEADING 'BRANCH|IN &f_to' FORMAT A9
COLUMN customers  HEADING 'RESI|DENTS'    FORMAT 999,990
COLUMN total      HEADING 'RESIDENT|SPEND (RM)' FORMAT 999,999,990
COLUMN home_amt   HEADING 'SPENT AT|HOME (RM)'  FORMAT 99,999,990
COLUMN travel_amt HEADING 'TRAVELLED|(RM)'      FORMAT 99,999,990
COLUMN travel_pct HEADING 'TRA|VEL %'     FORMAT 990.0
COLUMN growth_pct HEADING 'GROWTH %|1ST->&f_to' FORMAT S9,990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF customers total home_amt travel_amt ON REPORT

WITH rev AS (
    SELECT cus_ID, cus_city, cus_state, br_city, cal_year, SUM(amt) AS amt
    FROM (
        SELECT c.cus_ID, c.cus_city, c.cus_state, b.br_city, d.cal_year,
               SUM(f.order_total_amt - f.order_tax_amt) AS amt
        FROM   order_fact   f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        JOIN   branch_dim   b ON b.branch_key   = f.branch_key
        WHERE  f.order_status = 'Completed'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_ID, c.cus_city, c.cus_state, b.br_city, d.cal_year
        UNION ALL
        SELECT c.cus_ID, c.cus_city, c.cus_state, b.br_city, d.cal_year,
               SUM(f.serv_total_amt - f.serv_tax_amt)
        FROM   reservation_fact f
        JOIN   date_dim     d ON d.date_key     = f.date_key
        JOIN   customer_dim c ON c.customer_key = f.customer_key
        JOIN   branch_dim   b ON b.branch_key   = f.branch_key
        WHERE  f.res_status = 'Completed'
        AND    d.cal_year BETWEEN &f_from AND &f_to
        GROUP  BY c.cus_ID, c.cus_city, c.cus_state, b.br_city, d.cal_year
    )
    GROUP  BY cus_ID, cus_city, cus_state, br_city, cal_year
),
brc AS (
    SELECT b.br_city, COUNT(DISTINCT b.br_ID) AS branches
    FROM   order_fact f
    JOIN   date_dim   d ON d.date_key   = f.date_key
    JOIN   branch_dim b ON b.branch_key = f.branch_key
    WHERE  f.order_status = 'Completed'
    AND    d.cal_year = &f_to
    GROUP  BY b.br_city
)
SELECT r.cus_city,
       MAX(r.cus_state)                                            AS cus_state,
       CASE WHEN NVL(MAX(k.branches), 0) = 0
            THEN 'NO BRANCH' ELSE 'yes' END                        AS has_branch,
       COUNT(DISTINCT r.cus_ID)                                    AS customers,
       SUM(r.amt)                                                  AS total,
       SUM(CASE WHEN r.cus_city =  r.br_city THEN r.amt ELSE 0 END) AS home_amt,
       SUM(CASE WHEN r.cus_city <> r.br_city THEN r.amt ELSE 0 END) AS travel_amt,
       ROUND(SUM(CASE WHEN r.cus_city <> r.br_city THEN r.amt ELSE 0 END)
             / NULLIF(SUM(r.amt), 0) * 100, 1)                     AS travel_pct,
       ROUND((SUM(CASE WHEN r.cal_year = &f_to THEN r.amt END)
              / NULLIF(SUM(r.amt) KEEP (DENSE_RANK FIRST ORDER BY r.cal_year), 0) - 1) * 100, 1) AS growth_pct
FROM   rev r
LEFT   JOIN brc k ON k.br_city = r.cus_city
GROUP  BY r.cus_city
ORDER  BY NVL(MAX(k.branches), 0),
          SUM(CASE WHEN r.cus_city <> r.br_city THEN r.amt ELSE 0 END)
          / NULLIF(SUM(r.amt), 0) DESC;

PROMPT
PROMPT +==========================================================+
PROMPT |   END OF CUSTOMER LOCATION REPORT                        |
PROMPT |   The top rows of section 5 are the shortlist.           |
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
UNDEFINE v2019
UNDEFINE v2020
UNDEFINE v2021
UNDEFINE v2022
UNDEFINE v2023
UNDEFINE v2024
UNDEFINE v2025
UNDEFINE p_state
UNDEFINE f_state
UNDEFINE run_dt
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
