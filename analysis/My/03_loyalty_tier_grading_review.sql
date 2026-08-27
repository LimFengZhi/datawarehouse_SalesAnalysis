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

ACCEPT start_year NUMBER DEFAULT 2023 PROMPT 'Enter the START year of the analysis (default 2023): '
ACCEPT end_year   NUMBER DEFAULT 2025 PROMPT 'Enter the END year of the analysis   (default 2025): '

SET TERMOUT OFF
COLUMN run_dt NEW_VALUE run_dt NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN yr_range NEW_VALUE yr_range NOPRINT
SELECT TO_CHAR(&start_year) || ' - ' || TO_CHAR(&end_year) AS yr_range FROM dual;

COLUMN ey_lbl NEW_VALUE ey_lbl NOPRINT
SELECT TRIM(TO_CHAR(&end_year)) AS ey_lbl FROM dual;
CLEAR COLUMNS
SET TERMOUT ON

CREATE OR REPLACE VIEW customer_annual_value_v AS
SELECT
    COALESCE(p.cus_ID,   s.cus_ID)   AS cus_ID,
    COALESCE(p.cal_year, s.cal_year) AS cal_year,
    NVL(p.product_rev, 0) + NVL(s.service_rev, 0) AS annual_acv,
    NVL(p.product_rev, 0)                         AS product_rev,
    NVL(s.service_rev, 0)                         AS service_rev
FROM (
        SELECT c.cus_ID, d.cal_year, SUM(o.order_net_amt) AS product_rev
        FROM   order_fact   o
        JOIN   date_dim     d ON d.date_key     = o.date_key
        JOIN   customer_dim c ON c.customer_key = o.customer_key
        WHERE  o.order_status = 'Completed'
        GROUP  BY c.cus_ID, d.cal_year
     ) p
FULL OUTER JOIN (
        SELECT c.cus_ID, d.cal_year, SUM(r.serv_net_amt) AS service_rev
        FROM   reservation_fact r
        JOIN   date_dim     d ON d.date_key     = r.date_key
        JOIN   customer_dim c ON c.customer_key = r.customer_key
        WHERE  r.res_status = 'Completed'
        GROUP  BY c.cus_ID, d.cal_year
     ) s ON s.cus_ID = p.cus_ID AND s.cal_year = p.cal_year;


CREATE OR REPLACE VIEW customer_annual_trend_v AS
SELECT
    v.cus_ID,
    v.cal_year,
    v.annual_acv,
    v.product_rev,
    v.service_rev,
    LAG(v.annual_acv, 1, 0) OVER (PARTITION BY v.cus_ID ORDER BY v.cal_year) AS prev_year_acv,
    CASE WHEN v.annual_acv <
              LAG(v.annual_acv, 1, 0) OVER (PARTITION BY v.cus_ID ORDER BY v.cal_year)
         THEN 1 ELSE 0 END AS is_at_risk
FROM customer_annual_value_v v;

CREATE OR REPLACE VIEW customer_profile_value_v AS
SELECT
    t.cus_ID, t.cal_year, t.annual_acv, t.product_rev, t.service_rev,
    t.prev_year_acv, t.is_at_risk,
    c.cus_loyalty_tier,
    c.cus_age_group,
    c.cus_gender
FROM   customer_annual_trend_v t
JOIN   customer_dim c ON c.cus_ID = t.cus_ID
                     AND c.is_current_flag = 'Y';

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - A. ANNUAL SPEND DISTRIBUTION BY LOYALTY TIER' SKIP 1 -
       CENTER '&yr_range' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN tier_label HEADING 'LOYALTY|TIER'   FORMAT A9
COLUMN customers  HEADING 'CUSTOMER|YEARS' FORMAT 999,990
COLUMN min_acv    HEADING 'MIN|(RM)'       FORMAT 999,990.00
COLUMN p25_acv    HEADING 'P25|(RM)'       FORMAT 999,990.00
COLUMN med_acv    HEADING 'MEDIAN|(RM)'    FORMAT 999,990.00
COLUMN avg_acv    HEADING 'AVERAGE|(RM)'   FORMAT 999,990.00
COLUMN p75_acv    HEADING 'P75|(RM)'       FORMAT 999,990.00
COLUMN p90_acv    HEADING 'P90|(RM)'       FORMAT 999,990.00
COLUMN max_acv    HEADING 'MAX|(RM)'       FORMAT 999,990.00

BREAK ON REPORT

SELECT NVL(cus_loyalty_tier, 'ALL TIERS')                                  AS tier_label,
       COUNT(*)                                                            AS customers,
       ROUND(MIN(annual_acv), 2)                                           AS min_acv,
       ROUND(PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY annual_acv), 2)  AS p25_acv,
       ROUND(MEDIAN(annual_acv), 2)                                        AS med_acv,
       ROUND(AVG(annual_acv), 2)                                           AS avg_acv,
       ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY annual_acv), 2)  AS p75_acv,
       ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY annual_acv), 2)  AS p90_acv,
       ROUND(MAX(annual_acv), 2)                                           AS max_acv
FROM   customer_profile_value_v
WHERE  cal_year BETWEEN &start_year AND &end_year
GROUP  BY ROLLUP(cus_loyalty_tier)
ORDER  BY DECODE(cus_loyalty_tier, 'Platinum', 1, 'Gold', 2, 'Silver', 3, 'Bronze', 4, 5);


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
PROMPT ==================================================
PROMPT TIER GRADING REVIEW: STORED TIER VS EARNED TIER
PROMPT ==================================================
PROMPT

ACCEPT t_silver   NUMBER DEFAULT 940  PROMPT 'Silver   tier minimum annual spend RM (default 940): '
ACCEPT t_gold     NUMBER DEFAULT 1890 PROMPT 'Gold     tier minimum annual spend RM (default 1890): '
ACCEPT t_platinum NUMBER DEFAULT 3400 PROMPT 'Platinum tier minimum annual spend RM (default 3400): '

SET TERMOUT OFF
COLUMN ts_lbl NEW_VALUE ts_lbl NOPRINT
COLUMN tg_lbl NEW_VALUE tg_lbl NOPRINT
COLUMN tp_lbl NEW_VALUE tp_lbl NOPRINT
SELECT TRIM(TO_CHAR(&t_silver))   AS ts_lbl,
       TRIM(TO_CHAR(&t_gold))     AS tg_lbl,
       TRIM(TO_CHAR(&t_platinum)) AS tp_lbl
FROM   dual;
CLEAR COLUMNS
SET TERMOUT ON

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - B. TIER MIGRATION MATRIX' SKIP 1 -
       CENTER 'STORED TIER VS TIER EARNED ON &ey_lbl SPEND' SKIP 1 -
       CENTER 'THRESHOLDS: SILVER &ts_lbl / GOLD &tg_lbl / PLATINUM &tp_lbl' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN current_tier  HEADING 'CURRENT|TIER'      FORMAT A9
COLUMN e_bronze      HEADING 'EARNED|BRONZE'     FORMAT 999,990
COLUMN e_silver      HEADING 'EARNED|SILVER'     FORMAT 999,990
COLUMN e_gold        HEADING 'EARNED|GOLD'       FORMAT 999,990
COLUMN e_platinum    HEADING 'EARNED|PLATINUM'   FORMAT 999,990
COLUMN customers     HEADING 'TOTAL'             FORMAT 999,990
COLUMN pct_match     HEADING 'CORRECT|%'         FORMAT 990.0
COLUMN upgrade_cnt   HEADING 'SHOULD|UPGRADE'    FORMAT 999,990
COLUMN downgrade_cnt HEADING 'SHOULD|DOWNGRADE'  FORMAT 999,990

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL TIERS' OF e_bronze e_silver e_gold e_platinum -
                                 customers upgrade_cnt downgrade_cnt ON REPORT

WITH graded AS (
    SELECT v.cus_ID,
           v.cus_loyalty_tier AS current_tier,
           CASE WHEN v.annual_acv >= &t_platinum THEN 'Platinum'
                WHEN v.annual_acv >= &t_gold     THEN 'Gold'
                WHEN v.annual_acv >= &t_silver   THEN 'Silver'
                ELSE 'Bronze' END AS earned_tier,
           v.annual_acv
    FROM   customer_profile_value_v v
    WHERE  v.cal_year = &end_year
)
SELECT current_tier,
       COUNT(CASE WHEN earned_tier = 'Bronze'   THEN 1 END) AS e_bronze,
       COUNT(CASE WHEN earned_tier = 'Silver'   THEN 1 END) AS e_silver,
       COUNT(CASE WHEN earned_tier = 'Gold'     THEN 1 END) AS e_gold,
       COUNT(CASE WHEN earned_tier = 'Platinum' THEN 1 END) AS e_platinum,
       COUNT(*)                                             AS customers,
       ROUND(COUNT(CASE WHEN earned_tier = current_tier THEN 1 END) * 100.0
             / NULLIF(COUNT(*), 0), 1)                      AS pct_match,
       COUNT(CASE WHEN DECODE(earned_tier,  'Bronze',1,'Silver',2,'Gold',3,'Platinum',4)
                     > DECODE(current_tier, 'Bronze',1,'Silver',2,'Gold',3,'Platinum',4)
                  THEN 1 END)                               AS upgrade_cnt,
       COUNT(CASE WHEN DECODE(earned_tier,  'Bronze',1,'Silver',2,'Gold',3,'Platinum',4)
                     < DECODE(current_tier, 'Bronze',1,'Silver',2,'Gold',3,'Platinum',4)
                  THEN 1 END)                               AS downgrade_cnt
FROM   graded
GROUP  BY current_tier
ORDER  BY DECODE(current_tier, 'Platinum', 1, 'Gold', 2, 'Silver', 3, 'Bronze', 4);


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - C. UPGRADE ACTION LIST' SKIP 1 -
       CENTER 'CUSTOMERS WHOSE &ey_lbl SPEND EARNS A HIGHER TIER' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN current_tier HEADING 'CURRENT|TIER'      FORMAT A9
COLUMN earned_tier  HEADING 'EARNED|TIER'       FORMAT A9
COLUMN levels_up    HEADING 'LEVELS|UP'         FORMAT 990
COLUMN customers    HEADING 'CUSTOMERS'         FORMAT 999,990
COLUMN avg_acv      HEADING 'AVG ACV|(RM)'      FORMAT 99,990.00
COLUMN total_acv    HEADING 'TOTAL ACV|(RM)'    FORMAT 99,999,990
COLUMN pct_of_tier  HEADING '% OF THAT|TIER'    FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF customers total_acv ON REPORT

WITH graded AS (
    SELECT v.cus_ID,
           v.cus_loyalty_tier AS current_tier,
           CASE WHEN v.annual_acv >= &t_platinum THEN 'Platinum'
                WHEN v.annual_acv >= &t_gold     THEN 'Gold'
                WHEN v.annual_acv >= &t_silver   THEN 'Silver'
                ELSE 'Bronze' END AS earned_tier,
           v.annual_acv
    FROM   customer_profile_value_v v
    WHERE  v.cal_year = &end_year
),
moves AS (
    SELECT current_tier,
           earned_tier,
           DECODE(earned_tier,  'Bronze',1,'Silver',2,'Gold',3,'Platinum',4)
         - DECODE(current_tier, 'Bronze',1,'Silver',2,'Gold',3,'Platinum',4) AS levels_up,
           COUNT(*)                                         AS customers,
           AVG(annual_acv)                                  AS avg_acv,
           SUM(annual_acv)                                  AS total_acv,
           COUNT(*) * 100.0
             / SUM(COUNT(*)) OVER (PARTITION BY current_tier) AS pct_of_tier
    FROM   graded
    GROUP  BY current_tier, earned_tier
)
SELECT current_tier,
       earned_tier,
       levels_up,
       customers,
       ROUND(avg_acv, 2)    AS avg_acv,
       ROUND(total_acv)     AS total_acv,
       ROUND(pct_of_tier, 1) AS pct_of_tier
FROM   moves
WHERE  levels_up > 0
ORDER  BY levels_up DESC, customers DESC;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - D. DOWNGRADE WATCH LIST' SKIP 1 -
       CENTER 'CUSTOMERS WHOSE &ey_lbl SPEND NO LONGER EARNS THEIR TIER' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN current_tier HEADING 'CURRENT|TIER'   FORMAT A9
COLUMN earned_tier  HEADING 'EARNED|TIER'    FORMAT A9
COLUMN levels_down  HEADING 'LEVELS|DOWN'    FORMAT 990
COLUMN customers    HEADING 'CUSTOMERS'      FORMAT 999,990
COLUMN avg_acv      HEADING 'AVG ACV|(RM)'   FORMAT 99,990.00
COLUMN total_acv    HEADING 'TOTAL ACV|(RM)' FORMAT 99,999,990
COLUMN pct_of_tier  HEADING '% OF THAT|TIER' FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'TOTAL' OF customers total_acv ON REPORT

WITH graded AS (
    SELECT v.cus_ID,
           v.cus_loyalty_tier AS current_tier,
           CASE WHEN v.annual_acv >= &t_platinum THEN 'Platinum'
                WHEN v.annual_acv >= &t_gold     THEN 'Gold'
                WHEN v.annual_acv >= &t_silver   THEN 'Silver'
                ELSE 'Bronze' END AS earned_tier,
           v.annual_acv
    FROM   customer_profile_value_v v
    WHERE  v.cal_year = &end_year
),
moves AS (
    SELECT current_tier,
           earned_tier,
           DECODE(current_tier, 'Bronze',1,'Silver',2,'Gold',3,'Platinum',4)
         - DECODE(earned_tier,  'Bronze',1,'Silver',2,'Gold',3,'Platinum',4) AS levels_down,
           COUNT(*)                                           AS customers,
           AVG(annual_acv)                                    AS avg_acv,
           SUM(annual_acv)                                    AS total_acv,
           COUNT(*) * 100.0
             / SUM(COUNT(*)) OVER (PARTITION BY current_tier) AS pct_of_tier
    FROM   graded
    GROUP  BY current_tier, earned_tier
)
SELECT current_tier,
       earned_tier,
       levels_down,
       customers,
       ROUND(avg_acv, 2)     AS avg_acv,
       ROUND(total_acv)      AS total_acv,
       ROUND(pct_of_tier, 1) AS pct_of_tier
FROM   moves
WHERE  levels_down > 0
ORDER  BY levels_down DESC, customers DESC;

DROP VIEW customer_profile_value_v;
DROP VIEW customer_annual_trend_v;
DROP VIEW customer_annual_value_v;

PROMPT
PROMPT +==========================================================+
PROMPT |  END OF LOYALTY TIER GRADING REVIEW REPORT               |
PROMPT +==========================================================+
PROMPT

TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE start_year
UNDEFINE end_year
UNDEFINE t_silver
UNDEFINE t_gold
UNDEFINE t_platinum
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
