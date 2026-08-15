-- ===================================================================
-- 03_init_purchase_fact.sql     PURCHASE_FACT
-- Grain: one row per restocking purchase line  (10,615 rows)
-- Source: PURCHASE
--
-- This is your COGS fact. Branch profitability =
--   order_fact revenue - purchase_fact cost
--   - salary_payment_fact - branch_expense_fact
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW purchase_fact_staging_v AS
SELECT
    dd.date_key,
    ud.supplier_key,
    bd.branch_key,
    pd.product_key,

    p.purchase_ID,                                -- degenerate dim / PK

    p.purchase_qty,
    p.purchase_unit_cost,

    -- Measure
    ROUND(p.purchase_qty * p.purchase_unit_cost, 2)
                                                   AS purchase_total_cost

FROM purchase      p
JOIN date_dim     dd ON dd.cal_date   = TRUNC(p.purchase_date)
JOIN supplier_dim ud ON ud.sup_ID     = p.sup_ID
                    AND ud.is_current_flag = 'Y'
JOIN branch_dim   bd ON bd.br_ID      = p.br_ID
                    AND bd.is_current_flag = 'Y'
JOIN product_dim  pd ON pd.product_ID = p.product_ID
                    AND pd.is_current_flag = 'Y';

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- purchase_ID from the source is the PK and a degenerate dimension.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_purchase_fact_initial AS
    v_count   NUMBER;
    v_source  NUMBER;
    v_dropped NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM purchase_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('PURCHASE_FACT already contains data. '
            || 'Delete it first if you intend to reload.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_source FROM purchase;

    INSERT INTO purchase_fact (
        date_key, supplier_key, branch_key, product_key,
        purchase_ID, purchase_qty, purchase_unit_cost,
        purchase_total_cost
    )
    SELECT
        date_key, supplier_key, branch_key, product_key,
        purchase_ID, purchase_qty, purchase_unit_cost,
        purchase_total_cost
    FROM purchase_fact_staging_v;

    v_count   := SQL%ROWCOUNT;
    v_dropped := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('PURCHASE_FACT initial load completed: '
        || v_count || ' records inserted.');

    IF v_dropped <> 0 THEN
        DBMS_OUTPUT.PUT_LINE('*** WARNING: ' || v_dropped
            || ' source rows did NOT load - a dimension lookup failed.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('All ' || v_source
            || ' source rows resolved every dimension key.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in PURCHASE_FACT initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_purchase_fact_initial;

-- Expect 10615 in both columns
SELECT (SELECT COUNT(*) FROM purchase_fact) AS fact_rows,
       (SELECT COUNT(*) FROM purchase)      AS source_rows
FROM dual;

-- Which lookup failed, if any. Both must return 0.
SELECT COUNT(*) AS no_date FROM purchase p
WHERE NOT EXISTS (SELECT 1 FROM date_dim dd
                  WHERE dd.cal_date = TRUNC(p.purchase_date));

SELECT COUNT(*) AS no_supplier FROM purchase p
WHERE NOT EXISTS (SELECT 1 FROM supplier_dim ud
                  WHERE ud.sup_ID = p.sup_ID
                    AND ud.is_current_flag = 'Y');

-- Cost by supplier
SELECT s.sup_name,
       ROUND(SUM(f.purchase_total_cost), 2) AS total_cost,
       SUM(f.purchase_qty)                  AS units
FROM purchase_fact f
JOIN supplier_dim s ON s.supplier_key = f.supplier_key
GROUP BY s.sup_name
ORDER BY total_cost DESC;

-- Gross margin per product category: revenue vs cost.
-- Purchase cost should sit well below sell price.
SELECT p.product_category,
       ROUND(SUM(f.purchase_total_cost), 2) AS cogs,
       ROUND(AVG(f.purchase_unit_cost), 2)  AS avg_unit_cost
FROM purchase_fact f
JOIN product_dim p ON p.product_key = f.product_key
GROUP BY p.product_category
ORDER BY cogs DESC;
