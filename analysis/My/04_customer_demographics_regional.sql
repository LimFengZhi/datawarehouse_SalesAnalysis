CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
TTITLE OFF
BTITLE OFF
SET DEFINE ON
SET PAGESIZE 60
SET LINESIZE 100
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF
SET TERMOUT ON

ACCEPT start_year NUMBER DEFAULT 2019 PROMPT 'Enter the START year of the analysis (default 2019): '
ACCEPT end_year   NUMBER DEFAULT 2025 PROMPT 'Enter the END year of the analysis   (default 2025): '

SET TERMOUT OFF
COLUMN run_dt NEW_VALUE run_dt NOPRINT
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY') AS run_dt FROM dual;

COLUMN yr_range NEW_VALUE yr_range NOPRINT
SELECT TO_CHAR(&start_year) || ' - ' || TO_CHAR(&end_year) AS yr_range FROM dual;
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
       CENTER 'GLOW BEAUTY - A. ANNUAL CUSTOMER VALUE BY LOYALTY TIER' SKIP 1 -
       CENTER 'STORED cus_loyalty_tier, &yr_range' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cus_loyalty_tier HEADING 'LOYALTY|TIER'      FORMAT A9
COLUMN cal_year         HEADING 'YEAR'              FORMAT 9999
COLUMN customers        HEADING 'ACTIVE|CUSTOMERS'  FORMAT 999,990
COLUMN pct_customers    HEADING '% OF TOTAL|CUSTOMERS' FORMAT 990.0
COLUMN avg_acv          HEADING 'AVG ACV|(RM)'      FORMAT 99,990.00
COLUMN pct_at_risk      HEADING '% OF TIER|AT RISK' FORMAT 990.0

BREAK ON cus_loyalty_tier SKIP 1
COMPUTE AVG LABEL 'Tier Avg ACV:' OF avg_acv ON cus_loyalty_tier

WITH tier_year AS (
    SELECT cus_loyalty_tier,
           cal_year,
           COUNT(DISTINCT cus_ID) AS customers,
           AVG(annual_acv)        AS avg_acv,
           SUM(is_at_risk)        AS at_risk_count
    FROM   customer_profile_value_v
    WHERE  cal_year BETWEEN &start_year AND &end_year
    GROUP  BY cus_loyalty_tier, cal_year
)
SELECT cus_loyalty_tier,
       cal_year,
       customers,
       ROUND(customers * 100.0
             / SUM(customers) OVER (PARTITION BY cal_year), 1) AS pct_customers,
       ROUND(avg_acv, 2)                                       AS avg_acv,
       ROUND(at_risk_count * 100.0 / NULLIF(customers, 0), 1)  AS pct_at_risk
FROM   tier_year
ORDER  BY DECODE(cus_loyalty_tier, 'Platinum', 1, 'Gold', 2, 'Silver', 3, 'Bronze', 4),
          cal_year;


CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES

PROMPT
PROMPT ==================================================
PROMPT DRILL-DOWN: ONE YEAR, ONE LOYALTY TIER
PROMPT ==================================================
PROMPT

ACCEPT drill_year NUMBER DEFAULT 2025      PROMPT 'Enter the year to drill into (default 2025): '
ACCEPT drill_tier CHAR   DEFAULT 'Platinum' PROMPT 'Enter the loyalty tier (Bronze/Silver/Gold/Platinum, default Platinum): '

TTITLE CENTER '+==========================================================+' SKIP 1 -
       CENTER 'GLOW BEAUTY - B. DRILL-DOWN BY AGE BAND AND GENDER' SKIP 1 -
       CENTER 'LOYALTY TIER &drill_tier, YEAR &drill_year' SKIP 1 -
       CENTER '+==========================================================+' SKIP 1 -
       LEFT 'DATE: &run_dt' RIGHT 'PAGE: ' FORMAT 999 SQL.PNO SKIP 2

COLUMN cus_age_group HEADING 'AGE BAND'          FORMAT A24
COLUMN female_cnt    HEADING 'FEMALE'            FORMAT 999,990
COLUMN male_cnt      HEADING 'MALE'              FORMAT 999,990
COLUMN customers     HEADING 'CUSTOMERS'         FORMAT 999,990
COLUMN pct_of_tier   HEADING '% OF TIER|MEMBERS' FORMAT 990.0
COLUMN avg_acv       HEADING 'AVG ACV|(RM)'      FORMAT 99,990.00
COLUMN pct_at_risk   HEADING '% AT|RISK'         FORMAT 990.0

BREAK ON REPORT
COMPUTE SUM LABEL 'ALL AGES' OF female_cnt male_cnt customers ON REPORT

WITH by_age AS (
    SELECT cus_age_group,
           COUNT(DISTINCT CASE WHEN cus_gender = 'Female' THEN cus_ID END) AS female_cnt,
           COUNT(DISTINCT CASE WHEN cus_gender = 'Male'   THEN cus_ID END) AS male_cnt,
           COUNT(DISTINCT cus_ID) AS customers,
           AVG(annual_acv)        AS avg_acv,
           SUM(is_at_risk)        AS at_risk_count
    FROM   customer_profile_value_v
    WHERE  cal_year = &drill_year
    AND    UPPER(cus_loyalty_tier) = UPPER(TRIM('&drill_tier'))
    GROUP  BY cus_age_group
)
SELECT cus_age_group,
       female_cnt,
       male_cnt,
       customers,
       ROUND(customers * 100.0 / SUM(customers) OVER (), 1)   AS pct_of_tier,
       ROUND(avg_acv, 2)                                      AS avg_acv,
       ROUND(at_risk_count * 100.0 / NULLIF(customers, 0), 1) AS pct_at_risk
FROM   by_age
ORDER  BY cus_age_group;


DROP VIEW customer_profile_value_v;
DROP VIEW customer_annual_trend_v;
DROP VIEW customer_annual_value_v;

PROMPT
PROMPT +==========================================================+
PROMPT |  END OF ANNUAL CUSTOMER VALUE AND SEGMENTATION REPORT    |
PROMPT +==========================================================+
PROMPT

TTITLE OFF
BTITLE OFF
CLEAR COLUMNS
CLEAR BREAKS
CLEAR COMPUTES
UNDEFINE start_year
UNDEFINE end_year
UNDEFINE drill_year
UNDEFINE drill_tier
SET FEEDBACK ON
SET VERIFY ON
SET ECHO ON
