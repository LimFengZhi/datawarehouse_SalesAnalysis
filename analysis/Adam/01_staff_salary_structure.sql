-- ===================================================================
-- 01_staff_salary_structure.sql
-- PAYROLL ANALYSIS - STAFF SALARY STRUCTURE
--   year roll-up -> branch -> position
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\user\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Adam\01_staff_salary_structure.sql
--
-- PARAMETERS (prompted)
--   focus year   the year to slice into           (default 2025)
--   branch       city name for the section 3 dice (default Kuala Lumpur)
--
-- WHAT IT ANSWERS
--   1. What did the company pay its staff each year, and how was each
--      payslip composed - base, bonus, statutory deduction?
--   2. In the focus year, how is payroll distributed across branches?
--   3. Inside one branch, what are the pay bands by position?
--
-- MEASURE DEFINITIONS
--   base / bonus / deduction   as paid, from salary_payment_fact
--   gross = base + bonus       salary_payment_fact stores no gross
--                              column - computed here, every time
--   net   = total_amount       computed by the ETL as base + bonus -
--                              deduction, used as-is
--   base per head = SUM(base) / COUNT(DISTINCT st_ID)
--   deduction rate  = deduction / base, per payslip
--
--   Headcount is COUNT(DISTINCT st_ID), never staff_key: staff_dim is
--   SCD Type 2, so one person can own several surrogate rows and must
--   still count as one head. Branches group on br_ID for the same
--   reason. Branch is resolved from salary_payment_fact.branch_key
--   directly - staff_dim carries no br_ID of its own, so a section
--   that needs both branch and position joins branch_dim on the fact,
--   not through staff_dim.
--
-- ===================================================================
-- WHAT IS REAL IN THIS PAYROLL - READ THIS BEFORE QUOTING ANY NUMBER
-- ===================================================================
--   Unlike the dataset this report was first written against, salary
--   LEVELS here are genuine across the FULL 2018-2025 range - every
--   payslip's base is one contracted salary compounding through a
--   real increment schedule, not an independent random draw per year.
--   Composition (bonus and deduction ratios) is exact throughout too.
--   Both are auditable directly from sales_data2\gen_sales_data2.py:
--
--     ANNUAL INCREMENT   +3% every year, FROZEN in 2021 (+0%),
--                        +4% in 2025 (INCREMENT dict)
--     PAY CUT            -20% Apr-May 2020 (MCO 1.0)
--                        -15% Jun-Aug 2021 (FMCO)               (pay_cut())
--     EPF EMPLOYEE RATE  11%  Jan 2018 - Mar 2020
--                         7%  Apr 2020 - Dec 2020  (COVID relief)
--                         9%  Jan 2021 - Jun 2022  (partial restore)
--                        11%  Jul 2022 onward                   (epf_rate())
--     DECEMBER BONUS     13th month, 1.00x base - HALVED to 0.50x
--                        in December 2020 and 2021
--     RAYA BONUS         0.35x base - HALVED to 0.15x in the Raya
--                        months of 2020 and 2021
--
--   So there is no "genuine vs randomised" split to track here (the
--   REGIME column this report used to carry is gone) - the thing
--   worth watching instead is that 2020 and 2022 are NOT flat years:
--   the EPF rate changed mid-year in each (2021, between them, IS
--   flat - just at 9%, not 11%). DED % OF BASE in section 1 is the
--   annual blend this produces.
--
-- FACT USED  (one)
--   salary_payment_fact   one row per staff member per pay period,
--                         19,517 rows, 2018-2025. Every row is money
--                         actually paid; there is no status to filter
--                         on. No gross or net column - see MEASURE
--                         DEFINITIONS above.
--
-- DIMENSIONS USED  (three)
--   date_dim     cal_year, cal_year_month   -> the drill path
--   branch_dim   br_ID, br_city             -> sections 2 and 3
--   staff_dim    st_ID, st_position         -> headcount and pay bands
--
-- REPORT SECTIONS  (OLAP operation per section)
--   1  PAYROLL BY YEAR, 2018-2025            ROLL-UP
--   2  FOCUS YEAR BY BRANCH                  SLICE on the year
--   3  CHOSEN BRANCH x POSITION              DICE
--   4  SUMMARY STATISTICS                    ROLL-UP
--
-- WHAT TO LOOK FOR
--   - Section 1: headcount grows 192 -> 236 over the eight years (13
--     branches now, not the original 5). BASE PER HEAD climbs almost
--     every year - 2020 is the one dip (cuts), otherwise it compounds
--     at roughly 3%/year exactly as the increment schedule promises
--   - Section 1, bonus: BONUS % OF GROSS drops visibly in 2020 and
--     2021 - that is the halved December and Raya bonus, not a
--     policy change in how bonuses are calculated
--   - Section 1, deduction: DED % OF BASE dips below 11% in 2020
--     (8.08, blending 11% Jan-Mar with the 7% relief rate from Apr),
--     sits flat at 9.00 in 2021, then partially recovers in 2022
--     (10.03, blending 9% Jan-Jun with 11% from Jul). That shape - two
--     years off the baseline with a flat trough between them - is the
--     EPF relief rate, not a data error
--   - Section 3: Beauty Therapist spans two internal hire bands
--     (Junior and Senior) that collapse to one job title in
--     staff_dim.st_position, so its pay band is wider than the other
--     five positions. That is expected, not noise
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

-- SQL*Plus caps an ACCEPT prompt at 99 characters - a longer one
-- raises SP2-0003 and leaves the variable UNDEFINED, which then makes
-- SQL*Plus ask "Enter value for ..." mid-report. Keep these short.
ACCEPT focus_year NUMBER DEFAULT 2025 PROMPT 'Focus year (default 2025): '
ACCEPT branch     CHAR   DEFAULT 'Kuala Lumpur' PROMPT 'Branch city for section 3 (default Kuala Lumpur): '

-- ---- values reused in every title ---------------------------------
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN focus_y NEW_VALUE focus_y NOPRINT
SELECT TO_CHAR(&focus_year) AS focus_y FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL staff_salary_structure_output.txt


-- ###################################################################
-- SECTION 1 - PAYROLL BY YEAR
-- OLAP: ROLL-UP to year grain over the whole fact.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. PAYROLL BY YEAR, 2018 - 2025' SKIP 1 -
       CENTER 'WHAT WAS PAID, AND HOW EACH PAYSLIP WAS COMPOSED' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year   HEADING 'YEAR'                FORMAT 9999
COLUMN headcount  HEADING 'HEADS'               FORMAT 990
COLUMN payslips   HEADING 'PAY|SLIPS'           FORMAT 9,990
-- wide enough for the COMPUTE SUM row: eight years of payroll is an
-- eight-figure total, and a narrower format prints ##### instead
COLUMN base_total HEADING 'BASE (RM)'           FORMAT 99,999,990.00
COLUMN bonus_tot  HEADING 'BONUS (RM)'          FORMAT 99,999,990.00
COLUMN gross_tot  HEADING 'GROSS (RM)'          FORMAT 99,999,990.00
COLUMN ded_total  HEADING 'DEDUCTION|(RM)'      FORMAT 9,999,990.00
COLUMN net_total  HEADING 'NET PAID (RM)'       FORMAT 99,999,990.00
COLUMN base_head  HEADING 'BASE PER|HEAD (RM)'  FORMAT 99,990.00
COLUMN bonus_pct  HEADING 'BONUS %|OF GROSS'    FORMAT 990.0
COLUMN ded_pct    HEADING 'DED %|OF BASE'       FORMAT 990.00
COLUMN yoy_pct    HEADING 'GROSS|YOY %'         FORMAT S9990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF base_total bonus_tot gross_tot ded_total net_total ON REPORT

WITH pay AS (
    -- the base result set every section builds on: one row per
    -- payslip, carrying its year and staff ID as they stood on the
    -- payment date (the ETL resolved the SCD2 key that way, so no
    -- version filter is needed here). gross is not stored - computed
    -- here from base + bonus; net is the ETL's total_amount.
    SELECT d.cal_year,
           sd.st_ID,
           f.base_amount, f.bonus_amount, f.deduction_amount,
           f.base_amount + f.bonus_amount AS gross_amount,
           f.total_amount                 AS net_amount
    FROM   salary_payment_fact f
    JOIN   date_dim   d  ON d.date_key  = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    WHERE  d.date_key <> 0
),
by_year AS (
    SELECT cal_year,
           COUNT(DISTINCT st_ID)      AS headcount,
           COUNT(*)                   AS payslips,
           SUM(base_amount)           AS base_total,
           SUM(bonus_amount)          AS bonus_tot,
           SUM(gross_amount)          AS gross_tot,
           SUM(deduction_amount)      AS ded_total,
           SUM(net_amount)            AS net_total
    FROM   pay
    GROUP  BY cal_year
)
SELECT cal_year, headcount, payslips,
       base_total, bonus_tot, gross_tot, ded_total, net_total,
       base_total / NULLIF(headcount, 0)                    AS base_head,
       ROUND(bonus_tot / NULLIF(gross_tot, 0) * 100, 1)     AS bonus_pct,
       ROUND(ded_total / NULLIF(base_total, 0) * 100, 2)    AS ded_pct,
       ROUND((gross_tot - LAG(gross_tot) OVER (ORDER BY cal_year))
           / NULLIF(LAG(gross_tot) OVER (ORDER BY cal_year), 0)
             * 100, 1)                                      AS yoy_pct
FROM   by_year
ORDER  BY cal_year;

PROMPT
PROMPT   BASE PER HEAD is comparable across every year here - it is a
PROMPT   real compounding salary, not a re-draw. 2020 is the one dip:
PROMPT   the Apr-May pay cut lands inside the annual average.
PROMPT


-- ###################################################################
-- SECTION 2 - FOCUS YEAR BY BRANCH
-- OLAP: SLICE - date_dim fixed to the focus year, rolled up by branch.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. FOCUS YEAR &focus_y: PAYROLL BY BRANCH' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city   HEADING 'BRANCH'             FORMAT A15
COLUMN headcount HEADING 'HEADS'              FORMAT 990
COLUMN payslips  HEADING 'PAY|SLIPS'          FORMAT 9,990
-- wide enough for the COMPUTE SUM row: by 2025 the all-branch total
-- crosses eight figures (RM 10.03m), and a narrower format prints
-- ##### instead - see section 1's identical note
COLUMN base_tot  HEADING 'BASE (RM)'          FORMAT 99,999,990.00
COLUMN bonus_tot HEADING 'BONUS (RM)'         FORMAT 99,999,990.00
COLUMN gross_tot HEADING 'GROSS (RM)'         FORMAT 99,999,990.00
COLUMN base_head HEADING 'BASE PER|HEAD (RM)' FORMAT 99,990.00
COLUMN share_pct HEADING 'SHARE OF|PAYROLL %' FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF base_tot bonus_tot gross_tot ON REPORT

WITH pay AS (
    SELECT b.br_ID, b.br_city, sd.st_ID,
           f.base_amount, f.bonus_amount,
           f.base_amount + f.bonus_amount AS gross_amount
    FROM   salary_payment_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   branch_dim b  ON b.branch_key = f.branch_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    WHERE  d.date_key <> 0
    AND    d.cal_year = &focus_year
),
by_branch AS (
    -- natural key only: branch_dim is SCD2, so one branch can own
    -- several surrogate rows and must still roll up as one line
    SELECT br_ID, br_city,
           COUNT(DISTINCT st_ID) AS headcount,
           COUNT(*)              AS payslips,
           SUM(base_amount)      AS base_tot,
           SUM(bonus_amount)     AS bonus_tot,
           SUM(gross_amount)     AS gross_tot
    FROM   pay
    GROUP  BY br_ID, br_city
)
SELECT br_city, headcount, payslips, base_tot, bonus_tot, gross_tot,
       base_tot / NULLIF(headcount, 0)                    AS base_head,
       ROUND(RATIO_TO_REPORT(gross_tot) OVER () * 100, 1) AS share_pct
FROM   by_branch
ORDER  BY gross_tot DESC;

PROMPT
PROMPT   BASE PER HEAD is genuine and comparable branch to branch here.
PROMPT   A newly opened branch (Ipoh from 2023-03) will show fewer
PROMPT   HEADS and a smaller SHARE, not a different pay level.
PROMPT


-- ###################################################################
-- SECTION 3 - DICE: CHOSEN BRANCH x POSITION
-- OLAP: DICE - a selection on TWO dimensions at once
--         branch_dim  restricted to &branch
--         date_dim    restricted to &focus_y
--       then rolled up by staff_dim position.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. &branch &focus_y: PAY BANDS BY POSITION' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN st_position HEADING 'POSITION'          FORMAT A20
COLUMN headcount   HEADING 'HEADS'             FORMAT 990
COLUMN payslips    HEADING 'PAY|SLIPS'         FORMAT 9,990
COLUMN base_head   HEADING 'BASE PER|HEAD (RM)' FORMAT 99,990.00
COLUMN gross_tot   HEADING 'GROSS (RM)'        FORMAT 9,999,990.00
COLUMN share_pct   HEADING 'SHARE OF|BRANCH %' FORMAT 990.0
COLUMN bar         HEADING 'PAY BAND'          FORMAT A24

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF gross_tot ON REPORT

WITH pay AS (
    -- st_position is taken from the staff_dim version in force on the
    -- payment date. A mid-year position change would therefore place
    -- the same person in two lines; headcounts would then sum above
    -- the branch total. No position changes exist in this dataset,
    -- but that is the reading to apply if one ever appears.
    SELECT sd.st_position, sd.st_ID,
           f.base_amount,
           f.base_amount + f.bonus_amount AS gross_amount
    FROM   salary_payment_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   branch_dim b  ON b.branch_key = f.branch_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    WHERE  d.date_key <> 0
    AND    d.cal_year = &focus_year
    AND    UPPER(b.br_city) = UPPER('&branch')
),
by_position AS (
    SELECT st_position,
           COUNT(DISTINCT st_ID) AS headcount,
           COUNT(*)              AS payslips,
           SUM(base_amount)      AS base_tot,
           SUM(gross_amount)     AS gross_tot
    FROM   pay
    GROUP  BY st_position
)
SELECT st_position, headcount, payslips,
       base_tot / NULLIF(headcount, 0)                    AS base_head,
       gross_tot,
       ROUND(RATIO_TO_REPORT(gross_tot) OVER () * 100, 1) AS share_pct,
       -- scaled to the best-paid position in this branch, which
       -- always draws the full width; every other band is drawn
       -- against it
       RPAD('#', GREATEST(1,
            ROUND((base_tot / NULLIF(headcount, 0))
                / NULLIF(MAX(base_tot / NULLIF(headcount, 0)) OVER (), 0)
                  * 24)), '#')                            AS bar
FROM   by_position
ORDER  BY base_head DESC;

PROMPT
PROMPT   Pay bands here are genuine, not a randomised snapshot. Beauty
PROMPT   Therapist is the one wide band - it covers both a Junior and
PROMPT   a Senior hiring tier that staff_dim no longer distinguishes.
PROMPT   No rows at all means the branch had no staff on payroll in
PROMPT   the focus year - Ipoh only appears from February 2023.
PROMPT


-- ###################################################################
-- SECTION 4 - SUMMARY STATISTICS
-- OLAP: ROLL-UP to a single company-wide row per metric
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. STAFF SALARY SUMMARY STATISTICS' SKIP 1 -
       CENTER 'ALL BRANCHES 2018 - 2025, FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC' FORMAT A40
COLUMN metric_value HEADING 'VALUE'  FORMAT A34

WITH pay AS (
    SELECT d.cal_year, MOD(d.cal_year_month, 100) AS mth,
           sd.st_ID,
           f.base_amount, f.bonus_amount, f.deduction_amount,
           f.base_amount + f.bonus_amount AS gross_amount,
           f.total_amount                 AS net_amount
    FROM   salary_payment_fact f
    JOIN   date_dim   d  ON d.date_key  = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    WHERE  d.date_key <> 0
),
by_year AS (
    SELECT cal_year,
           COUNT(DISTINCT st_ID)                        AS headcount,
           SUM(gross_amount)                            AS gross_tot,
           SUM(base_amount) / COUNT(DISTINCT st_ID)     AS base_head
    FROM   pay
    GROUP  BY cal_year
),
-- one-row helper blocks; CROSS JOINed below instead of used as scalar
-- subqueries, which Oracle 11g rejects inside an aggregate SELECT
-- list (ORA-00937)
overall AS (
    SELECT COUNT(*)                  AS payslips,
           COUNT(DISTINCT st_ID)     AS people,
           SUM(base_amount)          AS base_tot,
           SUM(bonus_amount)         AS bonus_tot,
           SUM(deduction_amount)     AS ded_tot,
           SUM(gross_amount)         AS gross_tot,
           SUM(net_amount)           AS net_tot
    FROM   pay
),
span AS (
    SELECT MIN(cal_year) AS first_yr, MAX(cal_year) AS last_yr,
           MIN(headcount) KEEP (DENSE_RANK FIRST ORDER BY cal_year) AS first_heads,
           MAX(headcount) KEEP (DENSE_RANK LAST  ORDER BY cal_year) AS last_heads
    FROM   by_year
),
peaks AS (
    SELECT MAX(cal_year) KEEP (DENSE_RANK FIRST ORDER BY gross_tot DESC) AS top_yr,
           MAX(gross_tot)                                                AS top_gross,
           -- the trough in base per head, across the whole genuine range
           MIN(cal_year) KEEP (DENSE_RANK FIRST ORDER BY base_head ASC)  AS low_yr,
           MIN(base_head)                                                AS low_head
    FROM   by_year
),
bonus_mix AS (
    SELECT AVG(CASE WHEN mth = 12 THEN bonus_amount / NULLIF(base_amount, 0) END) AS dec_mult,
           SUM(CASE WHEN mth = 12 THEN bonus_amount ELSE 0 END)                   AS dec_bonus
    FROM   pay
),
focus AS (
    SELECT headcount AS f_heads, gross_tot AS f_gross, base_head AS f_base_head
    FROM   by_year WHERE cal_year = &focus_year
),
stats AS (
    SELECT o.*, s.*, p.*, bm.*, fc.*
    FROM   overall o CROSS JOIN span s CROSS JOIN peaks p
           CROSS JOIN bonus_mix bm CROSS JOIN focus fc
)
SELECT 'Payslips issued'                              AS metric_name,
       TO_CHAR(payslips)                                                    AS metric_value FROM stats
UNION ALL SELECT 'Distinct people paid',
       TO_CHAR(people)                                                      FROM stats
UNION ALL SELECT 'Headcount, first year to last',
       TO_CHAR(first_heads) || ' -> ' || TO_CHAR(last_heads)
       || '  (' || TO_CHAR(first_yr) || '-' || TO_CHAR(last_yr) || ')'      FROM stats
UNION ALL SELECT 'Total base paid (RM)',
       TRIM(TO_CHAR(base_tot,  '999,999,990.00'))                           FROM stats
UNION ALL SELECT 'Total bonus paid (RM)',
       TRIM(TO_CHAR(bonus_tot, '999,999,990.00'))                           FROM stats
UNION ALL SELECT 'Total gross payroll (RM)',
       TRIM(TO_CHAR(gross_tot, '999,999,990.00'))                           FROM stats
UNION ALL SELECT 'Total deducted (RM)',
       TRIM(TO_CHAR(ded_tot,   '999,999,990.00'))                           FROM stats
UNION ALL SELECT 'Total net paid (RM)',
       TRIM(TO_CHAR(net_tot,   '999,999,990.00'))                           FROM stats
UNION ALL SELECT 'Bonus as % of gross payroll',
       TRIM(TO_CHAR(bonus_tot / NULLIF(gross_tot, 0) * 100, '990.0')) || '%' FROM stats
UNION ALL SELECT 'December bonus, avg multiple of base',
       TRIM(TO_CHAR(dec_mult, '990.00')) || ' x'                            FROM stats
UNION ALL SELECT 'December bonus, total paid (RM)',
       TRIM(TO_CHAR(dec_bonus, '999,999,990.00'))                           FROM stats
UNION ALL SELECT 'Heaviest payroll year',
       TO_CHAR(top_yr) || '  (RM ' || TRIM(TO_CHAR(top_gross, '999,999,990.00')) || ')' FROM stats
UNION ALL SELECT 'Lowest base per head, any year',
       TO_CHAR(low_yr) || '  (RM ' || TRIM(TO_CHAR(low_head, '99,990.00')) || ')' FROM stats
UNION ALL SELECT 'Focus year &focus_y headcount',
       TO_CHAR(f_heads)                                                     FROM stats
UNION ALL SELECT 'Focus year &focus_y gross payroll (RM)',
       TRIM(TO_CHAR(f_gross, '999,999,990.00'))                             FROM stats
UNION ALL SELECT 'Focus year &focus_y base per head (RM)',
       TRIM(TO_CHAR(f_base_head, '99,990.00'))                              FROM stats;

PROMPT
PROMPT +==========================================================+
PROMPT |           END OF STAFF SALARY STRUCTURE REPORT           |
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
UNDEFINE focus_year
UNDEFINE branch
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
