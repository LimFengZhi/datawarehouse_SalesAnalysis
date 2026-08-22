-- ===================================================================
-- 04_staff_productivity_profit.sql
-- STAFF PRODUCTIVITY ANALYSIS - REVENUE vs LABOR COST PER THERAPIST
--   by position -> by branch -> one branch's therapists -> that
--   branch's wasted-hours breakdown
--
-- Run in SQL*Plus as the warehouse owner:
--   sqlplus dwh/yourpassword@XE
--   @c:\Users\user\OneDrive\Desktop\datawarehouse_SalesAnalysis\analysis\Adam\04_staff_productivity_profit.sql
--
-- PARAMETERS (prompted)
--   branch   city name for the section 3/4 therapist-level drill
--            (default Kuala Lumpur)
--
-- SCOPE - ONLY THERAPISTS
--   reservation_fact.staff_key only ever resolves to Beauty Therapist
--   or Senior Therapist - Sales Assistant, Cashier, Receptionist and
--   Branch Manager never deliver a booked service, so they never
--   appear here. This report is about the two positions that actually
--   generate service revenue, not the whole workforce; salary
--   structure across all six positions is 01's job.
--
-- THE QUESTION
--   "Profit per therapist" needs a cost side, and salary_payment_fact
--   is paid per MONTH while reservation_fact is booked per SERVICE -
--   there is no direct link from one booking to a slice of salary.
--   This report allocates a therapist's monthly labor cost (base +
--   bonus, the company's actual payroll outlay - see 01's MEASURE
--   DEFINITIONS on why bonus counts and the EPF deduction does not)
--   across the hours they actually delivered COMPLETED bookings that
--   same month:
--       cost per hour = SUM(base_amount + bonus_amount) that month
--                      / SUM(res_duration in Completed bookings) that month
--
--   ===============================================================
--   THE LIMITATION - READ THIS BEFORE QUOTING AN ABSOLUTE RM FIGURE
--   ===============================================================
--   There is no shift-schedule table in this warehouse, so "hours
--   worked" here means hours spent IN a completed booking, not hours
--   PAID for. A therapist's real working day includes time between
--   appointments, walk-in cover, training and admin that this report
--   cannot see. That means COST PER HOUR here is inflated relative to
--   true cost-per-paid-hour, for every therapist, by roughly the same
--   proportion - so the ABSOLUTE ratios are not a literal profit/loss
--   statement. The COMPARISON between positions and branches is still
--   valid, because the same blind spot affects everyone the same way.
--   Read every RCR (revenue-to-cost ratio) below as relative
--   cost-effectiveness, not as an audited P&L line.
--
-- WHAT IT ANSWERS
--   1. Does a Senior Therapist's higher pay come with higher revenue
--      per hour, or does the seniority premium not show up in output?
--   2. Which branches get the most service revenue per RM of labor
--      cost, and does that line up with which branches sell the most?
--   3. Inside one branch, how wide is the spread between the best and
--      weakest individual therapist?
--   4. Inside that same branch, which therapists' numbers are dragged
--      down by cancellations/no-shows rather than genuinely low output -
--      a scheduling fix vs a coaching one?
--
-- MEASURE DEFINITIONS
--   Hours          = SUM(res_duration) / 60, Completed bookings only
--   Revenue        = serv_total_amt - serv_tax_amt (net of discount,
--                    tax excluded - same convention as every other
--                    report here), Completed bookings only
--   Labor cost     = SUM(base_amount + bonus_amount), the same
--                    (st_ID, cal_year_month) the hours were earned in
--   RCR            = revenue / labor cost. Above 1.00 means the
--                    service revenue in that slice exceeds the
--                    allocated labor cost; see THE LIMITATION above
--                    for why this is a relative, not absolute, read
--   Wasted hours % = (Cancelled + No-Show hours) / all scheduled
--                    hours. res_duration is populated even when a
--                    booking never happened - the slot was still
--                    blocked on the calendar
--
--   Grouped on natural keys throughout (st_ID, br_ID) - staff_dim and
--   branch_dim are both SCD2, so one person or branch can own several
--   surrogate rows and must still roll up as one line.
--
-- FACTS USED  (two)
--   reservation_fact      159,977 rows, the service side
--   salary_payment_fact   19,517 rows, the cost side - joined to
--                         reservation_fact by (st_ID, cal_year_month),
--                         never by staff_key or date_key directly
--
-- DIMENSIONS USED  (three)
--   date_dim     cal_year_month              -> the join key between facts
--   staff_dim    st_ID, st_position           -> section 1, 3
--   branch_dim   br_ID, br_city               -> section 2, 3
--
-- REPORT SECTIONS  (OLAP operation per section)
--   1  REVENUE vs COST BY POSITION            ROLL-UP - the core finding
--   2  REVENUE vs COST BY BRANCH              ROLL-UP
--   3  CHOSEN BRANCH - EVERY THERAPIST         DICE
--   4  CHOSEN BRANCH - WASTED HOURS BY THERAPIST   DICE - the solution lens
--
-- WHAT TO LOOK FOR
--   - Section 1: REV PER HOUR is nearly identical between the two
--     positions (services are priced by the SERVICE, not by who
--     performs them) - but COST PER HOUR is not, because Senior
--     Therapist base pay is roughly 55-90% higher than Beauty
--     Therapist pay for the same output. RCR is the number that makes
--     this visible; REV PER HOUR alone hides it completely
--   - Section 2: branch RCR sits in a much narrower band than position
--     RCR - branch is a weak lens here, position is the strong one
--   - Section 4: FLAG classifies each therapist against THIS BRANCH's
--     own average RCR and average wasted hours % (recalculated per
--     branch, not a fixed number) - NEEDS COACHING has no cancellation
--     excuse available; CHECK SCHEDULING likely does
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

ACCEPT branch CHAR DEFAULT 'Kuala Lumpur' PROMPT 'Branch city for sections 3-4 (default Kuala Lumpur): '

-- ---- values reused in every title ---------------------------------
SET TERMOUT OFF
COLUMN run_dt  NEW_VALUE run_dt  NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

SPOOL staff_productivity_profit_output.txt


-- ###################################################################
-- SECTION 1 - REVENUE vs COST BY POSITION  (the core finding)
-- OLAP: ROLL-UP to position grain, company-wide.
-- ###################################################################
TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 1. REVENUE vs LABOR COST, BY POSITION' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

-- wide enough for company-wide totals: Beauty Therapist alone reaches
-- RM 14.2m revenue / RM 24.5m labor cost, and a narrower format
-- prints ##### instead
COLUMN st_position   HEADING 'POSITION'           FORMAT A18
COLUMN heads         HEADING 'THERA-|PISTS'       FORMAT 990
COLUMN hours         HEADING 'HOURS'              FORMAT 999,990.0
COLUMN revenue       HEADING 'REVENUE (RM)'       FORMAT 99,999,990.00
COLUMN rev_hr        HEADING 'REV PER|HOUR (RM)'  FORMAT 9,990.00
COLUMN labor_cost    HEADING 'LABOR COST (RM)'    FORMAT 99,999,990.00
COLUMN cost_hr       HEADING 'COST PER|HOUR (RM)' FORMAT 9,990.00
COLUMN rcr           HEADING 'RCR'                FORMAT 990.00

WITH hrs AS (
    SELECT sd.st_ID, sd.st_position, d.cal_year_month,
           SUM(f.res_duration) / 60                    AS hours,
           SUM(f.serv_total_amt - f.serv_tax_amt)       AS revenue
    FROM   reservation_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    WHERE  f.res_status = 'Completed' AND d.date_key <> 0
    GROUP  BY sd.st_ID, sd.st_position, d.cal_year_month
),
cost AS (
    SELECT sd.st_ID, d.cal_year_month,
           SUM(sp.base_amount + sp.bonus_amount) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   date_dim   d  ON d.date_key   = sp.date_key
    JOIN   staff_dim  sd ON sd.staff_key = sp.staff_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID, d.cal_year_month
),
-- one row per (person, month) with both sides present - a month with
-- salary paid but zero completed bookings has no hours to divide by,
-- so it is excluded here rather than divide by zero
joined AS (
    SELECT h.st_position, h.st_ID, h.hours, h.revenue, c.labor_cost
    FROM   hrs h
    JOIN   cost c ON c.st_ID = h.st_ID AND c.cal_year_month = h.cal_year_month
)
SELECT st_position,
       COUNT(DISTINCT st_ID)                              AS heads,
       SUM(hours)                                         AS hours,
       SUM(revenue)                                       AS revenue,
       SUM(revenue) / NULLIF(SUM(hours),0)                AS rev_hr,
       SUM(labor_cost)                                    AS labor_cost,
       SUM(labor_cost) / NULLIF(SUM(hours),0)              AS cost_hr,
       ROUND(SUM(revenue) / NULLIF(SUM(labor_cost),0), 2) AS rcr
FROM   joined
GROUP  BY st_position
ORDER  BY rcr DESC;

PROMPT
PROMPT   REV PER HOUR barely moves between positions. COST PER HOUR
PROMPT   does - that gap, not the revenue side, is what RCR is showing.
PROMPT


-- ###################################################################
-- SECTION 2 - REVENUE vs COST BY BRANCH
-- OLAP: ROLL-UP to branch grain, company-wide.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 2. REVENUE vs LABOR COST, BY BRANCH' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN br_city    HEADING 'BRANCH'              FORMAT A15
COLUMN heads      HEADING 'THERA-|PISTS'        FORMAT 990
COLUMN hours      HEADING 'HOURS'               FORMAT 99,990.0
COLUMN revenue    HEADING 'REVENUE (RM)'        FORMAT 9,999,990.00
COLUMN rev_hr     HEADING 'REV PER|HOUR (RM)'   FORMAT 9,990.00
COLUMN labor_cost HEADING 'LABOR COST (RM)'     FORMAT 9,999,990.00
COLUMN cost_hr    HEADING 'COST PER|HOUR (RM)'  FORMAT 9,990.00
COLUMN rcr        HEADING 'RCR'                 FORMAT 990.00

WITH hrs AS (
    SELECT b.br_ID, b.br_city, sd.st_ID, d.cal_year_month,
           SUM(f.res_duration) / 60                    AS hours,
           SUM(f.serv_total_amt - f.serv_tax_amt)       AS revenue
    FROM   reservation_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    JOIN   branch_dim b  ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed' AND d.date_key <> 0
    GROUP  BY b.br_ID, b.br_city, sd.st_ID, d.cal_year_month
),
cost AS (
    SELECT sd.st_ID, d.cal_year_month,
           SUM(sp.base_amount + sp.bonus_amount) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   date_dim   d  ON d.date_key   = sp.date_key
    JOIN   staff_dim  sd ON sd.staff_key = sp.staff_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID, d.cal_year_month
),
joined AS (
    SELECT h.br_ID, h.br_city, h.st_ID, h.hours, h.revenue, c.labor_cost
    FROM   hrs h
    JOIN   cost c ON c.st_ID = h.st_ID AND c.cal_year_month = h.cal_year_month
)
SELECT br_city,
       COUNT(DISTINCT st_ID)                              AS heads,
       SUM(hours)                                         AS hours,
       SUM(revenue)                                       AS revenue,
       SUM(revenue) / NULLIF(SUM(hours),0)                AS rev_hr,
       SUM(labor_cost)                                    AS labor_cost,
       SUM(labor_cost) / NULLIF(SUM(hours),0)              AS cost_hr,
       ROUND(SUM(revenue) / NULLIF(SUM(labor_cost),0), 2) AS rcr
FROM   joined
GROUP  BY br_ID, br_city
ORDER  BY rcr DESC;

PROMPT
PROMPT   RCR barely moves branch to branch - every branch has roughly
PROMPT   the same MIX of Beauty and Senior Therapists, so branch alone
PROMPT   does not explain cost-effectiveness. Position does (section 1).
PROMPT


-- ###################################################################
-- SECTION 3 - DICE: CHOSEN BRANCH, EVERY THERAPIST
-- OLAP: DICE - branch_dim restricted to &branch, rolled up by
--       individual therapist rather than by position or branch.
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 3. &branch: EVERY THERAPIST, RANKED' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN st_id       HEADING 'STAFF|ID'          FORMAT 99990
COLUMN st_position HEADING 'POSITION'          FORMAT A16
COLUMN hours       HEADING 'HOURS'             FORMAT 9,990.0
COLUMN services    HEADING 'SERVICES'          FORMAT 9,990
-- a therapist with 1,500+ hours across the dataset clears RM 100k -
-- wide enough that a narrower format prints ##### instead
COLUMN revenue     HEADING 'REVENUE (RM)'      FORMAT 999,990.00
COLUMN rev_hr      HEADING 'REV PER|HOUR (RM)' FORMAT 9,990.00
COLUMN rcr         HEADING 'RCR'               FORMAT 990.00

WITH hrs AS (
    SELECT sd.st_ID, sd.st_position, d.cal_year_month,
           SUM(f.res_duration) / 60                    AS hours,
           COUNT(*)                                     AS services,
           SUM(f.serv_total_amt - f.serv_tax_amt)       AS revenue
    FROM   reservation_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    JOIN   branch_dim b  ON b.branch_key = f.branch_key
    WHERE  f.res_status = 'Completed' AND d.date_key <> 0
    AND    UPPER(b.br_city) = UPPER('&branch')
    GROUP  BY sd.st_ID, sd.st_position, d.cal_year_month
),
cost AS (
    SELECT sd.st_ID, d.cal_year_month,
           SUM(sp.base_amount + sp.bonus_amount) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   date_dim   d  ON d.date_key   = sp.date_key
    JOIN   staff_dim  sd ON sd.staff_key = sp.staff_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID, d.cal_year_month
),
joined AS (
    SELECT h.st_ID, h.st_position, h.hours, h.services, h.revenue,
           c.labor_cost
    FROM   hrs h
    JOIN   cost c ON c.st_ID = h.st_ID AND c.cal_year_month = h.cal_year_month
)
SELECT st_ID, st_position,
       SUM(hours)                                          AS hours,
       SUM(services)                                        AS services,
       SUM(revenue)                                        AS revenue,
       SUM(revenue) / NULLIF(SUM(hours),0)                 AS rev_hr,
       ROUND(SUM(revenue) / NULLIF(SUM(labor_cost),0), 2)  AS rcr
FROM   joined
GROUP  BY st_ID, st_position
ORDER  BY rev_hr DESC;

PROMPT
PROMPT   No rows means the branch name did not match, or has no
PROMPT   therapists yet. Compare the best and weakest REV PER HOUR
PROMPT   here to section 1's company average for context.
PROMPT


-- ###################################################################
-- SECTION 4 - DICE: CHOSEN BRANCH, WASTED HOURS BY THERAPIST
-- OLAP: DICE - branch_dim restricted to &branch, same population as
-- section 3, now measured by cancellation/no-show exposure alongside
-- RCR - the lens that turns "who's weak" into "why they're weak."
-- ###################################################################
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - 4. &branch: WASTED HOURS BY THERAPIST' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN flag         HEADING 'FLAG'             FORMAT A31
COLUMN st_id        HEADING 'STAFF|ID'         FORMAT 99990
COLUMN st_position  HEADING 'POSITION'         FORMAT A16
COLUMN wasted_pct   HEADING 'WASTED|HOURS %'   FORMAT 990.0
COLUMN wasted_hours HEADING 'WASTED|HOURS'     FORMAT 9,990.0
COLUMN all_hours    HEADING 'SCHEDULED|HOURS'  FORMAT 9,990.0
COLUMN rcr          HEADING 'RCR'              FORMAT 990.00

BREAK ON flag SKIP 1

WITH branch_activity AS (
    SELECT sd.st_ID, sd.st_position, d.cal_year_month, f.res_status, f.res_duration,
           CASE WHEN f.res_status = 'Completed' THEN f.serv_total_amt - f.serv_tax_amt ELSE 0 END AS revenue
    FROM   reservation_fact f
    JOIN   date_dim   d  ON d.date_key   = f.date_key
    JOIN   staff_dim  sd ON sd.staff_key = f.staff_key
    JOIN   branch_dim b  ON b.branch_key = f.branch_key
    WHERE  d.date_key <> 0
    AND    UPPER(b.br_city) = UPPER('&branch')
),
per_therapist AS (
    SELECT st_ID, st_position,
           SUM(res_duration) / 60                                                                 AS all_hours,
           SUM(CASE WHEN res_status IN ('Cancelled','No-Show') THEN res_duration ELSE 0 END) / 60  AS wasted_hours,
           SUM(revenue)                                                                            AS revenue
    FROM   branch_activity
    GROUP  BY st_ID, st_position
),
cost AS (
    SELECT sd.st_ID, d.cal_year_month,
           SUM(sp.base_amount + sp.bonus_amount) AS labor_cost
    FROM   salary_payment_fact sp
    JOIN   date_dim   d  ON d.date_key   = sp.date_key
    JOIN   staff_dim  sd ON sd.staff_key = sp.staff_key
    WHERE  d.date_key <> 0
    GROUP  BY sd.st_ID, d.cal_year_month
),
therapist_cost AS (
    SELECT ba.st_ID, SUM(c.labor_cost) AS labor_cost
    FROM   (SELECT DISTINCT st_ID, cal_year_month FROM branch_activity) ba
    JOIN   cost c ON c.st_ID = ba.st_ID AND c.cal_year_month = ba.cal_year_month
    GROUP  BY ba.st_ID
),
by_therapist AS (
    SELECT pt.st_ID, pt.st_position,
           ROUND(pt.wasted_hours / NULLIF(pt.all_hours,0) * 100, 1) AS wasted_pct,
           pt.wasted_hours,
           pt.all_hours,
           ROUND(pt.revenue / NULLIF(tc.labor_cost,0), 2)           AS rcr
    FROM   per_therapist pt
    JOIN   therapist_cost tc ON tc.st_ID = pt.st_ID
)
SELECT CASE
           WHEN rcr <  AVG(rcr) OVER () AND wasted_pct <= AVG(wasted_pct) OVER () THEN 'NEEDS COACHING'
           WHEN rcr <  AVG(rcr) OVER () AND wasted_pct >  AVG(wasted_pct) OVER () THEN 'CHECK SCHEDULING'
           WHEN rcr >= AVG(rcr) OVER () AND wasted_pct >  AVG(wasted_pct) OVER () THEN 'STRONG DESPITE CANCELLATIONS'
           ELSE                                                                        'PERFORMING WELL'
       END AS flag,
       st_id, st_position, wasted_pct, wasted_hours, all_hours, rcr
FROM   by_therapist
ORDER  BY flag, wasted_pct DESC;

PROMPT
PROMPT   FLAG compares each therapist to THIS BRANCH's own average RCR
PROMPT   and average wasted hours % - NEEDS COACHING means their output
PROMPT   is weak and cancellations are not unusually high, so it is not
PROMPT   an easy excuse; CHECK SCHEDULING means cancellations are the
PROMPT   more likely explanation. The averages are recalculated fresh
PROMPT   for whichever branch is chosen above.
PROMPT

PROMPT +==========================================================+
PROMPT |        END OF STAFF PRODUCTIVITY PROFIT REPORT           |
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
UNDEFINE branch
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
