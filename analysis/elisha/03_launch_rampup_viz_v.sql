-- ===================================================================
-- 03_launch_rampup_viz_v.sql
-- LAUNCH RAMP-UP VIEW FOR VISUALIZATION - ZERO-FILLED (Power BI /
-- Tableau / Excel / etc.)
--
-- Run once in SQL*Plus as the warehouse owner to (re)create it:
--   sqlplus dwh/yourpassword@XE
--   @analysis\elisha\03_launch_rampup_viz_v.sql
--
-- WHY THIS VIEW EXISTS (separate from LAUNCH_ADOPTION_VIZ_V)
--   LAUNCH_ADOPTION_VIZ_V is GROUPed BY item x branch x month, so a
--   month with zero completed sales for an item produces NO ROW at
--   all, not a row with sales_value = 0. A line chart built directly
--   on it therefore has a GAP at that month, and Power BI silently
--   draws a smooth line across the gap instead of dropping to zero -
--   which HIDES the most important finding in this query: the 2021
--   service cohort's three-month crater during the Jun-Aug 2021 FMCO
--   lockdown (M3/M4/M5 = 0 in the SQL*Plus report). This view fixes
--   that by scaffolding every item x months-since-launch (0..5)
--   combination explicitly, and NVL-ing missing sales to 0, so a
--   zero month is a real zero row a line chart can plot.
--
-- GRAIN: channel x item x months_since_launch (0..5), summed across
-- ALL branches - matches 03_launch_adoption.sql's Section 2 grain,
-- which also sums the ramp-up across branches. If you need a
-- branch-level ramp-up, use LAUNCH_ADOPTION_VIZ_V directly instead
-- (its per-branch grain does not need zero-filling for that use, the
-- gap issue only bites a line chart drawn along the months axis).
-- ===================================================================

CREATE OR REPLACE VIEW LAUNCH_RAMPUP_VIZ_V AS
WITH ITEM_BASE AS (
    -- one row per item (channel/item_ID), deduplicated across branches
    SELECT DISTINCT
        channel, item_ID, item_name, item_category, launch_date, launch_year
    FROM LAUNCH_ADOPTION_VIZ_V
),
MONTH_SCAFFOLD AS (
    -- the six offsets charted: 0 (launch month) through 5
    SELECT LEVEL - 1 AS months_since_launch
    FROM DUAL CONNECT BY LEVEL <= 6
),
ITEM_MONTH_SCAFFOLD AS (
    -- every item x every offset - a guaranteed row even where no
    -- sale occurred, which is the whole point of this view
    SELECT
        ib.channel, ib.item_ID, ib.item_name, ib.item_category,
        ib.launch_date, ib.launch_year,
        ms.months_since_launch,
        ADD_MONTHS(ib.launch_date, ms.months_since_launch) AS month_start
    FROM ITEM_BASE ib
    CROSS JOIN MONTH_SCAFFOLD ms
)
SELECT
    sc.channel,
    sc.item_ID,
    sc.item_name,
    sc.item_category,
    sc.launch_date,
    sc.launch_year,
    sc.months_since_launch,
    -- 1-indexed label matching the SQL*Plus report's M1..M6 columns
    -- (months_since_launch is 0-indexed internally: 0 = launch month)
    'M' || TO_CHAR(sc.months_since_launch + 1) AS month_label,
    sc.month_start,
    NVL(SUM(la.sales_value), 0) AS sales_value,
    NVL(SUM(la.txn_count), 0)   AS txn_count
FROM ITEM_MONTH_SCAFFOLD sc
LEFT JOIN LAUNCH_ADOPTION_VIZ_V la
    ON  la.item_ID  = sc.item_ID
    AND la.channel  = sc.channel
    AND la.month_start = sc.month_start
GROUP BY
    sc.channel, sc.item_ID, sc.item_name, sc.item_category,
    sc.launch_date, sc.launch_year, sc.months_since_launch,
    sc.month_start;

PROMPT View LAUNCH_RAMPUP_VIZ_V created (or replaced).
PROMPT Every item now has exactly 6 rows (months_since_launch 0-5),
PROMPT with explicit 0 sales where nothing was sold - point your
PROMPT ramp-up line chart at THIS view, not LAUNCH_ADOPTION_VIZ_V.
PROMPT

-- ===================================================================
-- Formatted preview - proves the 2021 service cohort now shows real
-- zeros for the FMCO lockdown months (Jun-Aug 2021).
-- ===================================================================
SET PAGESIZE 60
SET LINESIZE 100

COLUMN item_name           FORMAT A28           HEADING 'Item Name'
COLUMN months_since_launch FORMAT 990           HEADING 'Months'
COLUMN sales_value         FORMAT 999,990.00    HEADING 'Sales (RM)'

TTITLE CENTER 'LAUNCH_RAMPUP_VIZ_V - Preview (2021 cohort)' SKIP 2

SELECT item_name, months_since_launch, sales_value
FROM LAUNCH_RAMPUP_VIZ_V
WHERE launch_year = 2021
ORDER BY item_name, months_since_launch;

CLEAR COLUMNS
TTITLE OFF
SET PAGESIZE 14
PROMPT
PROMPT Preview complete. View LAUNCH_RAMPUP_VIZ_V remains in the
PROMPT schema for your visualization tool to query directly.
