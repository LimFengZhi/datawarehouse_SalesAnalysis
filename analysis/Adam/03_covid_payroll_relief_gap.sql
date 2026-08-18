-- ===================================================================
-- 03_covid_payroll_relief_gap.sql
-- PAYROLL ANALYSIS - THE COVID RELIEF GAP
--   company baseline -> the overlap window -> gross vs net -> branch
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\user\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Adam\03_covid_payroll_relief_gap.sql
--
-- NO PARAMETERS. Unlike 01 and 02, this report is not about a chosen
-- year or branch - it is a fixed historical episode, five specific
-- months, and every section drills into that same window.
--
-- THE PROBLEM
--   Two COVID-era payroll measures ran at the same time and were never
--   reconciled against each other:
--     THE CUT      the company reduced base pay 20% (Apr-May 2020,
--                  MCO 1.0) and 15% (Jun-Aug 2021, FMCO)
--     THE RELIEF   the Malaysian EPF Board eased the mandatory
--                  employee contribution from 11% to 7% (2020) then
--                  9% (2021-2022), leaving more of each payslip as
--                  take-home pay
--   Both are real, documented, and independently confirmed against
--   sales_data2\gen_sales_data2.py (pay_cut(), epf_rate()) and the
--   live fact table (01_staff_salary_structure.sql section 1's DED %
--   OF BASE and BONUS % OF GROSS already show their fingerprints).
--   Nobody has asked whether the second measure actually offset the
--   first. This report answers that, for the five months both were
--   in force together.
--
-- WHAT IT ANSWERS
--   1. What did payroll look like before, during and after the two
--      COVID windows, at company scale?
--   2. Month by month, exactly when did the cut start and end, and
--      when did the relief start and end - do they line up?
--   3. Of the pay the cut took away, how much did the relief give
--      back? Is it close to 100%, or a much smaller number?
--   4. Does the shortfall fall evenly across branches, or do the
--      bigger branches absorb more of it in absolute RM?
--
-- MEASURE DEFINITIONS
--   Gross reduction (the cut's cost to the company) = the exact
--   counterfactual base implied by the KNOWN cut factor, minus what
--   was actually paid:
--       counterfactual base = actual base_amount / cut_factor
--       gross reduction     = counterfactual - actual
--                            = actual * (1/cut_factor - 1)
--   cut_factor is 0.80 for MCO 1.0, 0.85 for FMCO - see pay_cut() in
--   gen_sales_data2.py. This is an exact reconstruction, not an
--   estimate: the cut factor is a fixed multiplier applied uniformly,
--   so dividing it back out recovers the pre-cut base precisely
--   (up to the independent +-0.5% payslip noise, which averages out
--   over hundreds of payslips).
--
--   Relief cushion (extra take-home the relief measure provided) =
--   what the standard 11% EPF rate would have withheld on the SAME
--   (already-cut) base, minus what was actually withheld:
--       relief cushion = actual_base * 0.11 - actual_deduction_amount
--                       = actual_base * (0.11 - actual_epf_rate)
--   This isolates the relief's own effect from the cut's effect - it
--   is evaluated against the actual base paid, not the counterfactual
--   one, so the two measures' contributions never overlap or double
--   count.
--
--   Cushion % = relief cushion / gross reduction * 100. If it were
--   100%, the relief would have fully offset the cut's effect on
--   take-home pay. See WHAT TO LOOK FOR below for what it actually is.
--
-- FACT USED  (one)
--   salary_payment_fact   the same 19,517 rows as 01, restricted here
--                         to five specific pay periods.
--
-- DIMENSIONS USED  (two)
--   date_dim     cal_year_month              -> identifies the window
--   branch_dim   br_ID, br_city               -> section 4
--
-- REPORT SECTIONS  (the drill path, OLAP operation per section)
--   1  COMPANY PAYROLL BASELINE, 2018-2025    ROLL-UP
--   2  THE OVERLAP WINDOW, MONTH BY MONTH      SLICE + DRILL-DOWN
--   3  GROSS CUT vs NET RELIEF                 the core finding
--   4  BRANCH IMPACT OF THE SHORTFALL          DICE
--   5  SUMMARY STATISTICS                      ROLL-UP
--
-- WHAT TO LOOK FOR
--   - Section 2: the cut is a STEP FUNCTION, not a gradual dip - base
--     per head drops the month the cut starts and returns to trend
--     the very next month it ends. There is no slow recovery to look
--     for; the mechanism is instantaneous both ways
--   - Section 3: the cushion is real but small - roughly a sixth of
--     the 2020 shortfall and a ninth of the 2021 shortfall, not
--     anywhere close to covering it. A wage cut sized at 15-20% was
--     never going to be offset by an EPF rate move of 2-4 points
--   - Section 4: every branch loses the SAME percentage, so the
--     ranking here is pure headcount - it says nothing about which
--     branch was treated worse, only which one has more people
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

-- ---- values reused in every title ---------------------------------
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL covid_payroll_relief_gap_output.txt


-- ###################################################################
-- SECTION 1 - COMPANY PAYROLL BASELINE, 2018-2025
-- OLAP: ROLL-UP to year grain - the "normal" a reader needs in mind
-- before the anomaly in section 2 means anything.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. COMPANY PAYROLL BASELINE, 2018 - 2025' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year   HEADING 'YEAR'                FORMAT 9999
COLUMN headcount  HEADING 'HEADS'               FORMAT 990
COLUMN base_head  HEADING 'BASE PER|HEAD (RM)'  FORMAT 99,990.00
COLUMN ded_pct    HEADING 'DED %|OF BASE'       FORMAT 990.00
COLUMN covid_flag HEADING 'COVID|MEASURE'       FORMAT A20

WITH pay AS (
    SELECT d.cal_year, sd.st_ID, f.base_amount, f.deduction_amount
    FROM   salary_payment_fact f
    JOIN   date_dim   d  ON d.date_key  = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    WHERE  d.date_key <> 0
)
SELECT cal_year,
       COUNT(DISTINCT st_ID)                                    AS headcount,
       SUM(base_amount) / COUNT(DISTINCT st_ID)                 AS base_head,
       ROUND(SUM(deduction_amount) / NULLIF(SUM(base_amount),0) * 100, 2) AS ded_pct,
       CASE cal_year
           WHEN 2020 THEN 'Cut + relief (partial)'
           WHEN 2021 THEN 'Cut + relief'
           WHEN 2022 THEN 'Relief only (to Jun)'
       END                                                      AS covid_flag
FROM   pay
GROUP  BY cal_year
ORDER  BY cal_year;

PROMPT
PROMPT   COVID MEASURE marks the only three years touched by either
PROMPT   the wage cut or the EPF relief. Every other year is unmarked
PROMPT   because neither measure was active for any part of it.
PROMPT


-- ###################################################################
-- SECTION 2 - THE OVERLAP WINDOW, MONTH BY MONTH
-- OLAP: SLICE - date_dim fixed to Jan 2020 - Dec 2022, the only span
--       where either measure runs, drilled to the month.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. THE CUT AND THE RELIEF, MONTH BY MONTH' SKIP 1 -
       CENTER '2020 - 2022, THE ONLY YEARS EITHER MEASURE WAS ACTIVE' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN ym        HEADING 'MONTH'              FORMAT A8
COLUMN base_head HEADING 'BASE PER|HEAD (RM)' FORMAT 99,990.00
COLUMN idx       HEADING 'INDEX|(PRE-COVID=100)' FORMAT 9990.0
COLUMN ded_pct   HEADING 'EPF|RATE %'         FORMAT 990
COLUMN cut       HEADING 'WAGE|CUT'           FORMAT A5
COLUMN relief    HEADING 'EPF|RELIEF'         FORMAT A5

WITH pay AS (
    SELECT d.cal_year_month, d.cal_date, sd.st_ID,
           f.base_amount, f.deduction_amount
    FROM   salary_payment_fact f
    JOIN   date_dim   d  ON d.date_key  = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    WHERE  d.date_key <> 0
    AND    d.cal_year BETWEEN 2020 AND 2022
),
by_month AS (
    SELECT cal_year_month, MIN(cal_date) AS mth_date,
           SUM(base_amount) / COUNT(DISTINCT st_ID)      AS base_head,
           ROUND(SUM(deduction_amount)
               / NULLIF(SUM(base_amount),0) * 100)        AS ded_pct
    FROM   pay
    GROUP  BY cal_year_month
),
base2019 AS (
    -- 2019 average monthly base per head - the last full year before
    -- either measure existed. One row per 2019 month, then averaged.
    SELECT AVG(mh) AS base_2019 FROM (
        SELECT SUM(f.base_amount) / COUNT(DISTINCT sd.st_ID) AS mh
        FROM   salary_payment_fact f
        JOIN   date_dim   d  ON d.date_key  = f.date_key
        JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
        WHERE  d.date_key <> 0 AND d.cal_year = 2019
        GROUP  BY d.cal_year_month
    )
)
SELECT TO_CHAR(m.mth_date, 'YYYY-MM')                       AS ym,
       m.base_head,
       ROUND(m.base_head / NULLIF(b.base_2019,0) * 100, 1)  AS idx,
       m.ded_pct,
       CASE WHEN m.cal_year_month IN (202004,202005,202106,202107,202108)
            THEN 'CUT' END                                  AS cut,
       CASE WHEN m.ded_pct < 11 THEN 'YES' END               AS relief
FROM   by_month m
CROSS  JOIN base2019 b
ORDER  BY m.cal_year_month;

PROMPT
PROMPT   WAGE CUT and EPF RELIEF are shown side by side on purpose:
PROMPT   RELIEF runs continuously Apr 2020 - Jun 2022, but CUT only
PROMPT   flags five of those months. The other twenty-two are relief
PROMPT   with no wage cut at all - INDEX stays close to 100 through them.
PROMPT


-- ###################################################################
-- SECTION 3 - GROSS CUT vs NET RELIEF  (the core finding)
-- OLAP: DRILL-DOWN to the five overlap months, then a single company-
--       wide comparison: what the cut removed vs what the relief gave
--       back.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. WHAT THE CUT TOOK vs WHAT THE RELIEF GAVE BACK' SKIP 1 -
       CENTER 'THE FIVE MONTHS BOTH MEASURES RAN TOGETHER' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN ym          HEADING 'MONTH'                FORMAT A8
COLUMN wave        HEADING 'WAVE'                 FORMAT A12
COLUMN gross_cut   HEADING 'GROSS REDUCTION|(RM, the cut)'   FORMAT 999,990.00
COLUMN relief_amt  HEADING 'RELIEF CUSHION|(RM, the EPF ease)' FORMAT 999,990.00
COLUMN cushion_pct HEADING 'CUSHION|%'            FORMAT 990.0
COLUMN gap         HEADING 'UNCUSHIONED|GAP (RM)' FORMAT 999,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL 5 MONTHS' OF gross_cut relief_amt gap ON REPORT

WITH ov AS (
    SELECT d.cal_year_month, f.base_amount, f.deduction_amount
    FROM   salary_payment_fact f
    JOIN   date_dim d ON d.date_key = f.date_key
    WHERE  d.date_key <> 0
    AND    d.cal_year_month IN (202004,202005,202106,202107,202108)
),
by_month AS (
    SELECT cal_year_month,
           CASE WHEN cal_year_month IN (202004,202005) THEN 'MCO 1.0 (-20%)'
                ELSE 'FMCO (-15%)' END                          AS wave,
           -- exact counterfactual: actual / cut_factor - actual
           SUM(CASE WHEN cal_year_month IN (202004,202005)
                    THEN base_amount * (1/0.80 - 1)
                    ELSE base_amount * (1/0.85 - 1) END)        AS gross_cut,
           -- relief cushion: what 11% would have withheld on this
           -- SAME (already-cut) base, minus what was actually withheld
           SUM(base_amount * 0.11 - deduction_amount)           AS relief_amt
    FROM   ov
    GROUP  BY cal_year_month,
           CASE WHEN cal_year_month IN (202004,202005) THEN 'MCO 1.0 (-20%)'
                ELSE 'FMCO (-15%)' END
)
SELECT TO_CHAR(cal_year_month) AS ym, wave, gross_cut, relief_amt,
       ROUND(relief_amt / NULLIF(gross_cut,0) * 100, 1)  AS cushion_pct,
       gross_cut - relief_amt                            AS gap
FROM   by_month
ORDER  BY cal_year_month;

PROMPT
PROMPT   CUSHION % is the share of the cut the relief measure gave
PROMPT   back. FMCO's 9% EPF rate cushions less than MCO 1.0's 7% rate
PROMPT   did, on top of a smaller cut - the two measures were never
PROMPT   sized against each other.
PROMPT


-- ###################################################################
-- SECTION 4 - BRANCH IMPACT OF THE SHORTFALL
-- OLAP: DICE - the five overlap months, rolled up by branch.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. THE UNCUSHIONED GAP, BY BRANCH' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city   HEADING 'BRANCH'                FORMAT A15
COLUMN headcount HEADING 'HEADS|AFFECTED'        FORMAT 990
COLUMN gross_cut HEADING 'GROSS REDUCTION|(RM)'  FORMAT 999,990.00
COLUMN relief_amt HEADING 'RELIEF CUSHION|(RM)'  FORMAT 999,990.00
COLUMN gap       HEADING 'UNCUSHIONED|GAP (RM)'  FORMAT 999,990.00
COLUMN gap_head  HEADING 'GAP PER|HEAD (RM)'     FORMAT 9,990.00

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF gross_cut relief_amt gap ON REPORT

WITH ov AS (
    SELECT b.br_ID, b.br_city, sd.st_ID, d.cal_year_month,
           f.base_amount, f.deduction_amount
    FROM   salary_payment_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   branch_dim b  ON b.branch_key = f.branch_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    WHERE  d.date_key <> 0
    AND    d.cal_year_month IN (202004,202005,202106,202107,202108)
),
by_branch AS (
    SELECT br_ID, br_city,
           COUNT(DISTINCT st_ID) AS headcount,
           SUM(CASE WHEN cal_year_month IN (202004,202005)
                    THEN base_amount * (1/0.80 - 1)
                    ELSE base_amount * (1/0.85 - 1) END)  AS gross_cut,
           SUM(base_amount * 0.11 - deduction_amount)     AS relief_amt
    FROM   ov
    GROUP  BY br_ID, br_city
)
SELECT br_city, headcount, gross_cut, relief_amt,
       gross_cut - relief_amt                          AS gap,
       (gross_cut - relief_amt) / NULLIF(headcount,0)   AS gap_head
FROM   by_branch
ORDER  BY gap DESC;

PROMPT
PROMPT   GAP PER HEAD is close to flat across branches - confirming the
PROMPT   ranking above is a headcount effect, not a branch-specific one.
PROMPT


-- ###################################################################
-- SECTION 5 - SUMMARY STATISTICS
-- OLAP: ROLL-UP to a single set of headline figures.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. COVID RELIEF GAP SUMMARY STATISTICS' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC' FORMAT A42
COLUMN metric_value HEADING 'VALUE'  FORMAT A32

WITH ov AS (
    SELECT sd.st_ID, d.cal_year_month, f.base_amount, f.deduction_amount
    FROM   salary_payment_fact f
    JOIN   date_dim   d  ON d.date_key  = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    WHERE  d.date_key <> 0
    AND    d.cal_year_month IN (202004,202005,202106,202107,202108)
),
stats AS (
    SELECT COUNT(DISTINCT st_ID)                                       AS heads,
           SUM(CASE WHEN cal_year_month IN (202004,202005)
                    THEN base_amount * (1/0.80 - 1)
                    ELSE base_amount * (1/0.85 - 1) END)               AS gross_cut,
           SUM(base_amount * 0.11 - deduction_amount)                  AS relief_amt
    FROM   ov
),
fmt AS (
    SELECT heads, gross_cut, relief_amt,
           gross_cut - relief_amt                                  AS gap,
           ROUND(relief_amt / NULLIF(gross_cut,0) * 100, 1)        AS cushion_pct,
           (gross_cut - relief_amt) / NULLIF(heads,0)              AS gap_head
    FROM   stats
)
SELECT 'Staff affected (at least one overlap month)' AS metric_name,
       TO_CHAR(heads)                                                       AS metric_value FROM fmt
UNION ALL SELECT 'Months both measures ran together',
       '5  (Apr-May 2020, Jun-Aug 2021)'                                    FROM fmt
UNION ALL SELECT 'Total gross reduction from the cut (RM)',
       TRIM(TO_CHAR(gross_cut, '999,999,990.00'))                           FROM fmt
UNION ALL SELECT 'Total relief cushion provided (RM)',
       TRIM(TO_CHAR(relief_amt, '999,999,990.00'))                          FROM fmt
UNION ALL SELECT 'Uncushioned gap - what staff absorbed (RM)',
       TRIM(TO_CHAR(gap, '999,999,990.00'))                                 FROM fmt
UNION ALL SELECT 'Cushion %  (relief / cut)',
       TRIM(TO_CHAR(cushion_pct, '990.0')) || '%'                           FROM fmt
UNION ALL SELECT 'Uncushioned gap per affected employee (RM)',
       TRIM(TO_CHAR(gap_head, '9,990.00'))                                  FROM fmt;

PROMPT
PROMPT +==========================================================+
PROMPT |          END OF COVID PAYROLL RELIEF GAP REPORT          |
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
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
