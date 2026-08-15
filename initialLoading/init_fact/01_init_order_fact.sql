-- ===================================================================
-- 01_init_order_fact.sql        ORDER_FACT
-- Grain: one row per product line on an order  (349,396 rows)
-- Source: ORDER_DETAIL joined to ORDERS
--
--   SECTION 1: staging VIEW - resolves surrogate keys + measures
--   SECTION 2: no sequence   - the PK is the degenerate order_det_ID
--   SECTION 3: PROCEDURE     - initial load
--   SECTION 4: run + verification
--
-- ALL 7 DIMENSIONS MUST BE LOADED FIRST. Every join below is an
-- INNER JOIN, so an unresolved key silently drops the row - the
-- procedure compares source vs loaded counts and shouts if they differ.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
--
-- date_key is LOOKED UP, not calculated. date_dim uses a sequence
-- surrogate (1, 2, 3 ...), so the only way to get a row's date_key is
-- to join date_dim on the calendar date.
-- ===================================================================
CREATE OR REPLACE VIEW order_fact_staging_v AS
SELECT
    dd.date_key,
    pd.product_key,
    cd.customer_key,
    sd.staff_key,
    bd.branch_key,
    o.order_ID,
    od.order_det_ID,
    o.order_status,

    od.order_quantity                              AS order_qty,
    od.order_unit_price,

    -- Measures. NVL guards the nullable discount/tax columns so a NULL
    -- can never poison the additive totals.
    ROUND(od.order_quantity * od.order_unit_price, 2)
                                                   AS order_gross_amt,
    ROUND(NVL(od.order_discount, 0), 2)            AS order_discount_amt,
    ROUND(NVL(od.order_tax, 0), 2)                 AS order_tax_amt,
    ROUND(  od.order_quantity * od.order_unit_price
          - NVL(od.order_discount, 0)
          + NVL(od.order_tax, 0), 2)               AS order_total_amt

FROM order_detail od
JOIN orders       o  ON o.order_ID    = od.order_ID
JOIN date_dim     dd ON dd.cal_date   = TRUNC(o.order_date)
JOIN product_dim  pd ON pd.product_ID = od.product_ID
                    AND pd.is_current_flag = 'Y'
JOIN customer_dim cd ON cd.cus_ID     = o.cus_ID
                    AND cd.is_current_flag = 'Y'
JOIN staff_dim    sd ON sd.st_ID      = o.st_ID
                    AND sd.is_current_flag = 'Y'
JOIN branch_dim   bd ON bd.br_ID      = o.br_ID
                    AND bd.is_current_flag = 'Y';

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- Facts carry no surrogate key. order_det_ID comes straight from the
-- source system and is both the primary key and a degenerate dimension.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_order_fact_initial AS
    v_count   NUMBER;
    v_source  NUMBER;
    v_dropped NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM order_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('ORDER_FACT already contains data. '
            || 'Delete it first if you intend to reload.');
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
        date_key, product_key, customer_key, staff_key, branch_key,
        order_ID, order_det_ID, order_status,
        order_qty, order_unit_price, order_gross_amt,
        order_discount_amt, order_tax_amt, order_total_amt
    FROM order_fact_staging_v;

    v_count   := SQL%ROWCOUNT;
    v_dropped := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('ORDER_FACT initial load completed: '
        || v_count || ' records inserted.');

    IF v_dropped <> 0 THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: ' || v_dropped
            || ' source rows did NOT load - a dimension lookup failed. '
            || 'Run the orphan checks in SECTION 4.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('All ' || v_source
            || ' source rows resolved every dimension key.');
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

-- Expect 349396 in both columns
SELECT (SELECT COUNT(*) FROM order_fact)   AS fact_rows,
       (SELECT COUNT(*) FROM order_detail) AS source_rows
FROM dual;

-- If any row failed to load, these show WHICH dimension broke.
-- All five must return 0.
SELECT COUNT(*) AS no_date FROM order_detail od
JOIN orders o ON o.order_ID = od.order_ID
WHERE NOT EXISTS (SELECT 1 FROM date_dim dd
                  WHERE dd.cal_date = TRUNC(o.order_date));

SELECT COUNT(*) AS no_product FROM order_detail od
WHERE NOT EXISTS (SELECT 1 FROM product_dim pd
                  WHERE pd.product_ID = od.product_ID
                    AND pd.is_current_flag = 'Y');

SELECT COUNT(*) AS no_customer FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM customer_dim cd
                  WHERE cd.cus_ID = o.cus_ID
                    AND cd.is_current_flag = 'Y');

SELECT COUNT(*) AS no_staff FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM staff_dim sd
                  WHERE sd.st_ID = o.st_ID AND sd.is_current_flag = 'Y');

SELECT COUNT(*) AS no_branch FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM branch_dim bd
                  WHERE bd.br_ID = o.br_ID AND bd.is_current_flag = 'Y');

-- Measures must reconcile: gross - discount + tax = total
SELECT COUNT(*) AS bad_arithmetic FROM order_fact
WHERE ABS(order_gross_amt - order_discount_amt + order_tax_amt
          - order_total_amt) > 0.01;

-- Product revenue by year. Net of discount, ex-tax.
-- Expect roughly 5.48m / 4.57m / 4.14m / 7.47m for Completed orders.
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
