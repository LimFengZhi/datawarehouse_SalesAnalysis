-- ===================================================================
-- 01_staff_salary_structure.sql
-- PAYROLL ANALYSIS - STAFF SALARY STRUCTURE
--   year roll-up -> branch -> role
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
--   3. Inside one branch, what are the pay bands by role?
--
-- MEASURE DEFINITIONS
--   base / bonus / deduction   as paid, from salary_payment_fact
--   gross = base + bonus       computed by the ETL, used as-is
--   net   = gross - deduction  computed by the ETL, used as-is
--   base per head = SUM(base) / COUNT(DISTINCT st_ID)
--   deduction rate  = deduction / base, per payslip
--
--   Headcount is COUNT(DISTINCT st_ID), never staff_key: staff_dim is
--   SCD Type 2, so one person can own several surrogate rows and must
--   still count as one head. Branches group on br_ID for the same
--   reason.
--
-- ===================================================================
-- WHICH FIGURES ARE REAL - READ THIS BEFORE QUOTING ANY NUMBER
-- ===================================================================
--   Salary LEVELS and salary COMPOSITION do not have the same standing
--   in this warehouse.
--
--   COMPOSITION is exact in every year. The generators set the
--   December bonus to 1.00 x base, the Hari Raya bonus to 0.35 x base
--   and the deduction to 0.11 x base with no randomisation at all
--   (sales_data\data2\gen_data2.py, sales_data\data3\gen_data3.py -
--   the SALARY_PAYMENT block in each). Section 1's BONUS % / DED %
--   and section 4's deduction-rate check read these ratios and are
--   trustworthy throughout.
--
--   LEVELS are only genuine to 2022. From 2023 each pre-existing staff
--   member's base is RE-DRAWN as random.uniform(1900, 6600) rather
--   than carried forward, and in 2025 that re-draw covers every branch.
--   So:
--       2019-2022   real - contract-derived, cuts and restorations
--       2023-2024   randomised for branches 1-5, genuine for Ipoh
--       2025        randomised everywhere
--   Year-on-year salary GROWTH after 2022 is therefore noise. The
--   "4% rise on 2024" in README_DATA3.md is applied to a fresh random
--   draw, not to the 2024 value, and is not reproducible from the
--   data. This report does not claim it.
--
--   Sections 2 and 3 carry a REGIME column so a level comparison is
--   never read blind.
--
-- FACT USED  (one)
--   salary_payment_fact   one row per staff member per pay period,
--                         7,113 rows. Every row is money actually
--                         paid; there is no status to filter on.
--
-- DIMENSIONS USED  (three)
--   date_dim     cal_year, cal_year_month   -> the drill path
--   branch_dim   br_ID, br_city             -> sections 2 and 3
--   staff_dim    st_ID, st_role             -> headcount and pay bands
--
-- REPORT SECTIONS  (OLAP operation per section)
--   1  PAYROLL BY YEAR, 2019-2025            ROLL-UP
--   2  FOCUS YEAR BY BRANCH                  SLICE on the year
--   3  CHOSEN BRANCH x ROLE                  DICE
--   4  COMPOSITION CHECK                     diagnostic
--   5  SUMMARY STATISTICS                    ROLL-UP
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
ACCEPT branch     CHAR   DEFAULT 'Kuala Lumpur' PROMPT 'Branch city for section 5 (default Kuala Lumpur): '

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
       CENTER 'GLOW BEAUTY - 1. PAYROLL BY YEAR, 2019 - 2025' SKIP 1 -
       CENTER 'WHAT WAS PAID, AND HOW EACH PAYSLIP WAS COMPOSED' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year   HEADING 'YEAR'                FORMAT 9999
COLUMN headcount  HEADING 'HEADS'               FORMAT 990
COLUMN payslips   HEADING 'PAY|SLIPS'           FORMAT 9,990
-- wide enough for the COMPUTE SUM row: seven years of payroll is an
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
    -- payslip, carrying its year, branch and staff attributes as they
    -- stood on the payment date (the ETL resolved each SCD2 key that
    -- way, so no version filter is needed here)
    SELECT d.cal_year,
           sd.st_ID,
           f.base_amount, f.bonus_amount, f.deduction_amount,
           f.gross_amount, f.net_amount
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
PROMPT   BONUS % OF GROSS and DED % OF BASE are exact in every year.
PROMPT   BASE PER HEAD is only comparable across years up to 2022.
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
COLUMN base_tot  HEADING 'BASE (RM)'          FORMAT 9,999,990.00
COLUMN bonus_tot HEADING 'BONUS (RM)'         FORMAT 9,999,990.00
COLUMN gross_tot HEADING 'GROSS (RM)'         FORMAT 9,999,990.00
COLUMN base_head HEADING 'BASE PER|HEAD (RM)' FORMAT 99,990.00
COLUMN share_pct HEADING 'SHARE OF|PAYROLL %' FORMAT 990.0
COLUMN regime    HEADING 'LEVELS'             FORMAT A12
COLUMN br_ID     NOPRINT

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF base_tot bonus_tot gross_tot ON REPORT

WITH pay AS (
    SELECT b.br_ID, b.br_city, sd.st_ID,
           f.base_amount, f.bonus_amount, f.gross_amount
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
       base_tot / NULLIF(headcount, 0)                       AS base_head,
       ROUND(RATIO_TO_REPORT(gross_tot) OVER () * 100, 1)    AS share_pct,
       -- whether BASE PER HEAD on this line may be compared with any
       -- other line - see the header note on measurement regimes
       CASE
           WHEN &focus_year <= 2022 THEN 'genuine'
           WHEN &focus_year <= 2024 AND br_ID = 6 THEN 'genuine'
           ELSE 'randomised'
       END                                                   AS regime,
       br_ID
FROM   by_branch
ORDER  BY gross_tot DESC;

PROMPT
PROMPT   SHARE OF PAYROLL and HEADS are real in every year. Compare
PROMPT   BASE PER HEAD across branches only where LEVELS says genuine.
PROMPT


-- ###################################################################
-- SECTION 3 - DICE: CHOSEN BRANCH x ROLE
-- OLAP: DICE - a selection on TWO dimensions at once
--         branch_dim  restricted to &branch
--         date_dim    restricted to &focus_y
--       then rolled up by staff_dim role.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. &branch &focus_y: PAY BANDS BY ROLE' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN st_role   HEADING 'ROLE'               FORMAT A20
COLUMN headcount HEADING 'HEADS'              FORMAT 990
COLUMN payslips  HEADING 'PAY|SLIPS'          FORMAT 9,990
COLUMN base_head HEADING 'BASE PER|HEAD (RM)' FORMAT 99,990.00
COLUMN gross_tot HEADING 'GROSS (RM)'         FORMAT 9,999,990.00
COLUMN share_pct HEADING 'SHARE OF|BRANCH %'  FORMAT 990.0
COLUMN bar       HEADING 'PAY BAND'           FORMAT A24
COLUMN regime    HEADING 'LEVELS'             FORMAT A12

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL' OF gross_tot ON REPORT

WITH pay AS (
    -- st_role is taken from the staff_dim version in force on the
    -- payment date. A mid-year role change would therefore place the
    -- same person in two role lines; headcounts would then sum above
    -- the branch total. No role changes exist in this dataset, but
    -- that is the reading to apply if one ever appears.
    SELECT sd.st_role, sd.st_ID, b.br_ID,
           f.base_amount, f.gross_amount
    FROM   salary_payment_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   branch_dim b  ON b.branch_key = f.branch_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    WHERE  d.date_key <> 0
    AND    d.cal_year = &focus_year
    AND    UPPER(b.br_city) = UPPER('&branch')
),
by_role AS (
    SELECT st_role,
           MAX(br_ID)            AS br_ID,
           COUNT(DISTINCT st_ID) AS headcount,
           COUNT(*)              AS payslips,
           SUM(base_amount)      AS base_tot,
           SUM(gross_amount)     AS gross_tot
    FROM   pay
    GROUP  BY st_role
)
SELECT st_role, headcount, payslips,
       base_tot / NULLIF(headcount, 0)                    AS base_head,
       gross_tot,
       ROUND(RATIO_TO_REPORT(gross_tot) OVER () * 100, 1) AS share_pct,
       -- scaled to the best-paid role in this branch, which always
       -- draws the full width; every other band is drawn against it
       RPAD('#', GREATEST(1,
            ROUND((base_tot / NULLIF(headcount, 0))
                / NULLIF(MAX(base_tot / NULLIF(headcount, 0)) OVER (), 0)
                  * 24)), '#')                            AS bar,
       -- the pay BAND is only a band where levels are genuine. From
       -- 2023 base pay is re-drawn at random independently of role,
       -- so the ranking below is noise unless this column says so.
       CASE
           WHEN &focus_year <= 2022 THEN 'genuine'
           WHEN &focus_year <= 2024 AND br_ID = 6 THEN 'genuine'
           ELSE 'randomised'
       END                                                AS regime
FROM   by_role
ORDER  BY base_head DESC;

PROMPT
PROMPT   If LEVELS says randomised, the ordering is NOT a pay structure
PROMPT   - base pay was re-drawn independently of role that year. Run
PROMPT   with a focus year of 2022 or earlier for the real bands.
PROMPT   No rows at all means the branch had no staff on payroll in the
PROMPT   focus year - Ipoh only appears from February 2023.
PROMPT


-- ###################################################################
-- SECTION 4 - COMPOSITION CHECK  (diagnostic)
-- Not an analysis section. It establishes that the ratios section 1
-- reports are structural, and that the fact's own arithmetic holds
-- row by row.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. PAYSLIP COMPOSITION CHECK BY YEAR' SKIP 1 -
       CENTER 'DIAGNOSTIC - THE ERROR COLUMNS MUST BE 0' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cal_year   HEADING 'YEAR'                  FORMAT 9999
COLUMN payslips   HEADING 'PAY|SLIPS'             FORMAT 9,990
COLUMN with_bonus HEADING 'WITH A|BONUS'          FORMAT 9,990
COLUMN min_rate   HEADING 'DED RATE|MIN %'       FORMAT 990.00
COLUMN avg_rate   HEADING 'DED RATE|AVG %'       FORMAT 990.00
COLUMN max_rate   HEADING 'DED RATE|MAX %'       FORMAT 990.00
COLUMN gross_err  HEADING 'BASE+BONUS|<> GROSS'   FORMAT 9,990
COLUMN net_err    HEADING 'GROSS-DED|<> NET'      FORMAT 9,990

WITH pay AS (
    SELECT d.cal_year,
           f.base_amount, f.bonus_amount, f.deduction_amount,
           f.gross_amount, f.net_amount
    FROM   salary_payment_fact f
    JOIN   date_dim d ON d.date_key = f.date_key
    WHERE  d.date_key <> 0
)
SELECT cal_year,
       COUNT(*)                                                     AS payslips,
       SUM(CASE WHEN bonus_amount > 0 THEN 1 ELSE 0 END)            AS with_bonus,
       -- per-payslip ratio, not a ratio of the totals: min = max is
       -- what proves the rate is a flat statutory deduction rather
       -- than an average that happens to land near 11%
       ROUND(MIN(deduction_amount / NULLIF(base_amount, 0)) * 100, 2) AS min_rate,
       ROUND(AVG(deduction_amount / NULLIF(base_amount, 0)) * 100, 2) AS avg_rate,
       ROUND(MAX(deduction_amount / NULLIF(base_amount, 0)) * 100, 2) AS max_rate,
       SUM(CASE WHEN ABS(base_amount + bonus_amount - gross_amount) > 0.01
                THEN 1 ELSE 0 END)                                  AS gross_err,
       SUM(CASE WHEN ABS(gross_amount - deduction_amount - net_amount) > 0.01
                THEN 1 ELSE 0 END)                                  AS net_err
FROM   pay
GROUP  BY cal_year
ORDER  BY cal_year;

PROMPT
PROMPT   MIN = AVG = MAX = 11.00 from 2023 onward is the 11% EPF rate
PROMPT   applied per payslip. Both error columns must read 0.
PROMPT


-- ###################################################################
-- SECTION 5 - SUMMARY STATISTICS
-- OLAP: ROLL-UP to a single company-wide row per metric
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 5. STAFF SALARY SUMMARY STATISTICS' SKIP 1 -
       CENTER 'ALL BRANCHES 2019 - 2025, FOCUS YEAR &focus_y' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN metric_name  HEADING 'METRIC' FORMAT A40
COLUMN metric_value HEADING 'VALUE'  FORMAT A34

WITH pay AS (
    SELECT d.cal_year, MOD(d.cal_year_month, 100) AS mth,
           sd.st_ID,
           f.base_amount, f.bonus_amount, f.deduction_amount,
           f.gross_amount, f.net_amount
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
           -- the trough in base per head, restricted to the years
           -- whose levels are genuine
           MIN(cal_year) KEEP (DENSE_RANK FIRST ORDER BY
               CASE WHEN cal_year <= 2022 THEN base_head END ASC NULLS LAST) AS low_yr,
           MIN(CASE WHEN cal_year <= 2022 THEN base_head END)            AS low_head
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
UNION ALL SELECT 'Lowest base per head, 2019-2022',
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
