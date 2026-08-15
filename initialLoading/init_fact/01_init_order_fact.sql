-- ===================================================================
-- 01_init_order_fact.sql        ORDER_FACT
-- Grain: one row per product line on an order  (349,396 rows in data\)
-- Source: ORDER_DETAIL joined to ORDERS
--
--   SECTION 1: staging VIEW - OLTP cleansing ONLY
--   SECTION 2: no sequence   - the PK is the degenerate order_det_ID
--   SECTION 3: PROCEDURE     - resolves surrogate keys, then inserts
--   SECTION 4: run + verification
--
-- THE VIEW DOES NOT TOUCH THE DIMENSIONS.
-- It exposes the NATURAL keys (cus_ID, br_ID, st_ID, product_ID) and
-- the raw order_date. The surrogate-key lookups live in SECTION 3.
-- Three reasons that split matters:
--   1. the view compiles and can be inspected before any dimension is
--      loaded - it depends only on the OLTP tables
--   2. is_current_flag = 'Y' is a LOAD-TIME decision, not a cleansing
--      rule, so it belongs in the procedure where it is visible
--   3. the same view serves BOTH the initial load and the incremental
--      one in subsequentLoading\sub_fact\, and the incremental needs
--      the raw date to apply its lookback window
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- OLTP cleansing only. Natural keys out, no dimension joins.
-- ===================================================================
CREATE OR REPLACE VIEW order_fact_staging_v AS
SELECT
    od.order_det_ID,                              -- degenerate dim / PK
    o.order_ID,                                   -- degenerate dim

    -- ---------- NATURAL keys, resolved to surrogates in SECTION 3 ----
    o.cus_ID,
    o.br_ID,
    o.st_ID,
    od.product_ID,
    TRUNC(o.order_date)                            AS order_date,

    -- ---------- cleansed attributes ----------
    -- All statuses are kept (not just Completed) so the warehouse can
    -- report cancellation and fulfilment rates. Filter in your queries.
    CASE
        WHEN UPPER(TRIM(o.order_status)) IN ('COMPLETED','COMPLETE','DONE')
            THEN 'Completed'
        WHEN UPPER(TRIM(o.order_status)) IN ('CANCELLED','CANCELED','VOID')
            THEN 'Cancelled'
        WHEN UPPER(TRIM(o.order_status)) IN ('PROCESSING','IN PROGRESS')
            THEN 'Processing'
        WHEN UPPER(TRIM(o.order_status)) IN ('PENDING','NEW')
            THEN 'Pending'
        WHEN o.order_status IS NULL THEN 'Pending'
        ELSE INITCAP(TRIM(o.order_status))
    END                                            AS clean_order_status,

    -- Quantity must be at least 1 - the OLTP CHECK says > 0, but a
    -- staging view should never assume the source honoured it.
    CASE
        WHEN od.order_quantity IS NULL OR od.order_quantity <= 0 THEN 1
        WHEN od.order_quantity > 999 THEN 999
        ELSE od.order_quantity
    END                                            AS clean_order_qty,

    CASE
        WHEN od.order_unit_price IS NULL OR od.order_unit_price < 0
            THEN 0
        ELSE od.order_unit_price
    END                                            AS clean_unit_price,

    ROUND(NVL(od.order_discount, 0), 2)            AS clean_discount_amt,
    ROUND(NVL(od.order_tax, 0), 2)                 AS clean_tax_amt,

    -- ---------- derived measures ----------
    ROUND(
        CASE WHEN od.order_quantity IS NULL OR od.order_quantity <= 0
             THEN 1 ELSE od.order_quantity END
      * CASE WHEN od.order_unit_price IS NULL OR od.order_unit_price < 0
             THEN 0 ELSE od.order_unit_price END, 2)
                                                   AS order_gross_amt,
    ROUND(
        CASE WHEN od.order_quantity IS NULL OR od.order_quantity <= 0
             THEN 1 ELSE od.order_quantity END
      * CASE WHEN od.order_unit_price IS NULL OR od.order_unit_price < 0
             THEN 0 ELSE od.order_unit_price END
      - NVL(od.order_discount, 0)
      + NVL(od.order_tax, 0), 2)                   AS order_total_amt,

    -- ---------- data quality flags ----------
    CASE WHEN od.order_quantity IS NULL OR od.order_quantity <= 0
              OR od.order_quantity > 999
         THEN 'Y' ELSE 'N' END                     AS qty_corrected,
    CASE WHEN od.order_unit_price IS NULL OR od.order_unit_price < 0
         THEN 'Y' ELSE 'N' END                     AS price_corrected,
    CASE WHEN o.order_status IS NULL
         THEN 'Y' ELSE 'N' END                     AS status_defaulted,
    CASE WHEN od.order_discount IS NULL OR od.order_tax IS NULL
         THEN 'Y' ELSE 'N' END                     AS money_defaulted

FROM order_detail od
JOIN orders o ON o.order_ID = od.order_ID
-- Rows missing a key cannot be loaded at all. Excluding them HERE makes
-- the loss explicit and countable, instead of letting a dimension join
-- drop them silently later.
WHERE od.order_det_ID IS NOT NULL
  AND o.order_ID      IS NOT NULL
  AND o.order_date    IS NOT NULL
  AND o.cus_ID        IS NOT NULL
  AND o.br_ID         IS NOT NULL
  AND o.st_ID         IS NOT NULL
  AND od.product_ID   IS NOT NULL;

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- Facts carry no surrogate key. order_det_ID comes straight from the
-- source and is both the primary key and a degenerate dimension.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- This is where the natural keys become surrogate keys.
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_order_fact_initial AS
    v_count    NUMBER;
    v_errors   NUMBER := 0;
    v_orphaned NUMBER := 0;
    v_source   NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM order_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('ORDER_FACT already contains data. Use '
            || 'load_order_fact_incremental for updates.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_source FROM order_detail;

    INSERT INTO order_fact (
        date_key, product_key, customer_key, staff_key, branch_key,
        order_ID, order_det_ID, order_status,
        order_qty, order_unit_price, order_gross_amt,
        order_discount_amt, order_tax_amt, order_total_amt
    )
    SELECT
        d.date_key,
        p.product_key,
        c.customer_key,
        s.staff_key,
        b.branch_key,
        ls.order_ID,
        ls.order_det_ID,
        ls.clean_order_status,
        ls.clean_order_qty,
        ls.clean_unit_price,
        ls.order_gross_amt,
        ls.clean_discount_amt,
        ls.clean_tax_amt,
        ls.order_total_amt
    FROM order_fact_staging_v ls
    JOIN date_dim     d ON d.cal_date   = ls.order_date
    JOIN product_dim  p ON p.product_ID = ls.product_ID
                       AND p.is_current_flag = 'Y'
    JOIN customer_dim c ON c.cus_ID     = ls.cus_ID
                       AND c.is_current_flag = 'Y'
    JOIN staff_dim    s ON s.st_ID      = ls.st_ID
                       AND s.is_current_flag = 'Y'
    JOIN branch_dim   b ON b.br_ID      = ls.br_ID
                       AND b.is_current_flag = 'Y';

    v_count := SQL%ROWCOUNT;

    -- How many rows the cleansing had to repair
    SELECT COUNT(*) INTO v_errors
    FROM   order_fact_staging_v
    WHERE  qty_corrected = 'Y' OR price_corrected = 'Y'
       OR  status_defaulted = 'Y' OR money_defaulted = 'Y';

    -- How many source rows never made it, for any reason
    v_orphaned := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('ORDER_FACT initial load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Records inserted        : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Data quality corrections: ' || v_errors);
    DBMS_OUTPUT.PUT_LINE(' - Source rows not loaded  : ' || v_orphaned);

    IF v_orphaned <> 0 THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: a dimension lookup failed for '
            || 'those rows. Run the orphan checks in SECTION 4.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in ORDER_FACT initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_order_fact_initial;

-- Expect fact_rows = source_rows
SELECT (SELECT COUNT(*) FROM order_fact)   AS fact_rows,
       (SELECT COUNT(*) FROM order_detail) AS source_rows
FROM dual;

-- Rows the STAGING VIEW itself rejected (a NULL key in the source)
SELECT (SELECT COUNT(*) FROM order_detail)
     - (SELECT COUNT(*) FROM order_fact_staging_v) AS rejected_by_view
FROM dual;
-- expect 0

-- Which DIMENSION lookup failed, if any. All five must return 0.
SELECT COUNT(*) AS no_date FROM order_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                  WHERE d.cal_date = ls.order_date);

SELECT COUNT(*) AS no_product FROM order_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM product_dim p
                  WHERE p.product_ID = ls.product_ID
                    AND p.is_current_flag = 'Y');

SELECT COUNT(*) AS no_customer FROM order_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM customer_dim c
                  WHERE c.cus_ID = ls.cus_ID
                    AND c.is_current_flag = 'Y');

SELECT COUNT(*) AS no_staff FROM order_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM staff_dim s
                  WHERE s.st_ID = ls.st_ID AND s.is_current_flag = 'Y');

SELECT COUNT(*) AS no_branch FROM order_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM branch_dim b
                  WHERE b.br_ID = ls.br_ID AND b.is_current_flag = 'Y');

-- Measures must reconcile: gross - discount + tax = total
SELECT COUNT(*) AS bad_arithmetic FROM order_fact
WHERE ABS(order_gross_amt - order_discount_amt + order_tax_amt
          - order_total_amt) > 0.01;

-- Product revenue by year, net of discount and ex-tax.
-- Expect roughly 5.48m / 4.57m / 4.14m / 7.47m for 2019-2022.
SELECT d.cal_year,
       ROUND(SUM(f.order_gross_amt - f.order_discount_amt), 2) AS net_revenue,
       COUNT(*) AS order_lines
FROM order_fact f
JOIN date_dim d ON d.date_key = f.date_key
WHERE f.order_status = 'Completed'
GROUP BY d.cal_year
ORDER BY d.cal_year;

-- Branch ranking. Expect Kuala Lumpur top, Melaka last.
SELECT b.br_city,
       ROUND(SUM(f.order_gross_amt - f.order_discount_amt), 2) AS net_revenue
FROM order_fact f
JOIN branch_dim b ON b.branch_key = f.branch_key
WHERE f.order_status = 'Completed'
GROUP BY b.br_city
ORDER BY net_revenue DESC;
