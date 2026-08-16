-- ===================================================================
-- 03_init_purchase_fact.sql     PURCHASE_FACT
-- Grain: one row per restocking purchase line (10,615 rows in data\)
-- Source: PURCHASE
--
--   SECTION 1: staging VIEW - OLTP cleansing ONLY
--   SECTION 2: no sequence   - the PK is the degenerate purchase_ID
--   SECTION 3: PROCEDURE     - resolves surrogate keys, then inserts
--   SECTION 4: run + verification
--
-- THE VIEW DOES NOT TOUCH THE DIMENSIONS - natural keys out
-- (product_ID, br_ID, sup_ID) and the raw purchase_date.
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
    p.purchase_ID,                                -- degenerate dim / PK

    -- ---------- NATURAL keys ----------
    p.product_ID,
    p.br_ID,
    p.sup_ID,
    TRUNC(p.purchase_date)                         AS purchase_date,

    -- ---------- cleansed measures ----------
    CASE
        WHEN p.purchase_qty IS NULL OR p.purchase_qty <= 0 THEN 1
        WHEN p.purchase_qty > 99999 THEN 99999
        ELSE p.purchase_qty
    END                                            AS clean_purchase_qty,

    CASE
        WHEN p.purchase_unit_cost IS NULL OR p.purchase_unit_cost < 0
            THEN 0
        ELSE p.purchase_unit_cost
    END                                            AS clean_unit_cost,

    ROUND(
        CASE WHEN p.purchase_qty IS NULL OR p.purchase_qty <= 0
             THEN 1 ELSE p.purchase_qty END
      * CASE WHEN p.purchase_unit_cost IS NULL OR p.purchase_unit_cost < 0
             THEN 0 ELSE p.purchase_unit_cost END, 2)
                                                   AS purchase_total_cost,

    -- ---------- data quality flags ----------
    CASE WHEN p.purchase_qty IS NULL OR p.purchase_qty <= 0
              OR p.purchase_qty > 99999
         THEN 'Y' ELSE 'N' END                     AS qty_corrected,
    CASE WHEN p.purchase_unit_cost IS NULL OR p.purchase_unit_cost < 0
         THEN 'Y' ELSE 'N' END                     AS cost_corrected

FROM purchase p
WHERE p.purchase_ID   IS NOT NULL
  AND p.product_ID    IS NOT NULL
  AND p.br_ID         IS NOT NULL
  AND p.sup_ID        IS NOT NULL
  AND p.purchase_date IS NOT NULL;

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- purchase_ID from the source is the PK and a degenerate dimension.
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_purchase_fact_initial AS
    v_count    NUMBER;
    v_errors   NUMBER := 0;
    v_orphaned NUMBER := 0;
    v_source   NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM purchase_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('PURCHASE_FACT already contains data. Use '
            || 'load_purchase_fact_incremental for updates.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_source FROM purchase;

    INSERT INTO purchase_fact (
        date_key, supplier_key, branch_key, product_key,
        purchase_ID, purchase_qty, purchase_unit_cost,
        purchase_total_cost
    )
    SELECT
        d.date_key,
        u.supplier_key,
        b.branch_key,
        p.product_key,
        ls.purchase_ID,
        ls.clean_purchase_qty,
        ls.clean_unit_cost,
        ls.purchase_total_cost
    FROM purchase_fact_staging_v ls
    JOIN date_dim     d ON d.cal_date   = ls.purchase_date
    JOIN supplier_dim u ON u.sup_ID     = ls.sup_ID
                       AND u.is_current_flag = 'Y'
    JOIN branch_dim   b ON b.br_ID      = ls.br_ID
                       AND b.is_current_flag = 'Y'
    JOIN product_dim  p ON p.product_ID = ls.product_ID
                       AND p.is_current_flag = 'Y';

    v_count := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   purchase_fact_staging_v
    WHERE  qty_corrected = 'Y' OR cost_corrected = 'Y';

    v_orphaned := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('PURCHASE_FACT initial load completed:');
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
        DBMS_OUTPUT.PUT_LINE('Error in PURCHASE_FACT initial load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
EXEC load_purchase_fact_initial;

SELECT (SELECT COUNT(*) FROM purchase_fact) AS fact_rows,
       (SELECT COUNT(*) FROM purchase)      AS source_rows
FROM dual;

SELECT (SELECT COUNT(*) FROM purchase)
     - (SELECT COUNT(*) FROM purchase_fact_staging_v) AS rejected_by_view
FROM dual;
-- expect 0

-- Which DIMENSION lookup failed, if any. Both must return 0.
SELECT COUNT(*) AS no_date FROM purchase_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                  WHERE d.cal_date = ls.purchase_date);

SELECT COUNT(*) AS no_supplier FROM purchase_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM supplier_dim u
                  WHERE u.sup_ID = ls.sup_ID
                    AND u.is_current_flag = 'Y');

-- Cost by supplier
SELECT s.sup_name,
       ROUND(SUM(f.purchase_total_cost), 2) AS total_cost,
       SUM(f.purchase_qty)                  AS units
FROM purchase_fact f
JOIN supplier_dim s ON s.supplier_key = f.supplier_key
GROUP BY s.sup_name
ORDER BY total_cost DESC;

-- COGS per product category. Purchase cost should sit well below the
-- sell price.
SELECT p.product_category,
       ROUND(SUM(f.purchase_total_cost), 2) AS cogs,
       ROUND(AVG(f.purchase_unit_cost), 2)  AS avg_unit_cost
FROM purchase_fact f
JOIN product_dim p ON p.product_key = f.product_key
GROUP BY p.product_category
ORDER BY cogs DESC;
