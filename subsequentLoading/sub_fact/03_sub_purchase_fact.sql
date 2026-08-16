-- ===================================================================
-- 03_sub_purchase_fact.sql    PURCHASE_FACT - SUBSEQUENT LOAD
--
--   SECTION 1: no new view - reuses purchase_fact_staging_v
--   SECTION 2: no sequence - the PK is the degenerate purchase_ID
--   SECTION 3: PROCEDURE - insert new lines, then update changed ones
--   SECTION 4: run + verification
--
-- SCOPE: this is the COGS fact. It has no status column, so STEP 2
-- only catches corrections - a quantity re-counted at goods-in, or a
-- unit cost amended after the supplier invoice arrives. Those do
-- happen, and they move branch profitability, so they are refreshed.
--
-- Backfill the whole of data2 (2023-2024):
--     EXEC load_purchase_fact_incremental(DATE '2023-01-01');
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: STAGING VIEW - REUSED, NOT RECREATED
-- purchase_fact_staging_v is defined in
--   initialLoading\init_fact\03_init_purchase_fact.sql
-- OLTP cleansing only: natural keys (product_ID, br_ID, sup_ID) and
-- the raw purchase_date. Surrogate joins are written out below.
-- ===================================================================

-- ===================================================================
-- SECTION 2: SEQUENCE - NOT REQUIRED
-- ===================================================================

-- ===================================================================
-- SECTION 3: ETL (SUBSEQUENT / INCREMENTAL LOADING)
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_purchase_fact_incremental(
    p_load_date IN DATE DEFAULT SYSDATE
) AS
    v_from    DATE   := TRUNC(p_load_date) - 1;
    v_count   NUMBER := 0;
    v_updated NUMBER := 0;
    v_errors  NUMBER := 0;
BEGIN
    -- ---------------------------------------------------------------
    -- STEP 1: insert new restocking lines
    -- ---------------------------------------------------------------
    INSERT INTO purchase_fact (
        date_key, supplier_key, branch_key, product_key,
        purchase_ID, purchase_qty, purchase_unit_cost,
        purchase_total_cost
    )
    SELECT
        d.date_key, u.supplier_key, b.branch_key, p.product_key,
        ls.purchase_ID, ls.clean_purchase_qty, ls.clean_unit_cost,
        ls.purchase_total_cost
    FROM purchase_fact_staging_v ls
    JOIN date_dim     d ON d.cal_date   = ls.purchase_date
    JOIN supplier_dim u ON u.sup_ID     = ls.sup_ID
                       AND u.is_current_flag = 'Y'
    JOIN branch_dim   b ON b.br_ID      = ls.br_ID
                       AND b.is_current_flag = 'Y'
    JOIN product_dim  p ON p.product_ID = ls.product_ID
                       AND p.is_current_flag = 'Y'
    WHERE ls.purchase_date >= v_from
    AND   NOT EXISTS (SELECT 1 FROM purchase_fact f
                      WHERE f.purchase_ID = ls.purchase_ID);

    v_count := SQL%ROWCOUNT;

    -- ---------------------------------------------------------------
    -- STEP 2: refresh corrected quantities or costs.
    -- purchase_total_cost is refreshed with them so qty * cost = total
    -- continues to hold.
    -- ---------------------------------------------------------------
    UPDATE purchase_fact f
    SET   (purchase_qty, purchase_unit_cost, purchase_total_cost) =
          (SELECT ls.clean_purchase_qty, ls.clean_unit_cost,
                  ls.purchase_total_cost
           FROM   purchase_fact_staging_v ls
           WHERE  ls.purchase_ID = f.purchase_ID)
    WHERE EXISTS (
        SELECT 1
        FROM   purchase_fact_staging_v ls
        WHERE  ls.purchase_ID = f.purchase_ID
          AND  ls.purchase_date >= v_from
          AND (   NVL(f.purchase_qty, -1)
                    <> NVL(ls.clean_purchase_qty, -1)
               OR NVL(f.purchase_unit_cost, -1)
                    <> NVL(ls.clean_unit_cost, -1) ));

    v_updated := SQL%ROWCOUNT;

    SELECT COUNT(*) INTO v_errors
    FROM   purchase_fact_staging_v
    WHERE  purchase_date >= v_from
    AND   (qty_corrected = 'Y' OR cost_corrected = 'Y');

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('PURCHASE_FACT incremental load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Window from             : '
        || TO_CHAR(v_from, 'YYYY-MM-DD'));
    DBMS_OUTPUT.PUT_LINE(' - New records inserted    : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Existing records updated: ' || v_updated);
    DBMS_OUTPUT.PUT_LINE(' - Data quality corrections: ' || v_errors);

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in PURCHASE_FACT incremental load: '
            || SQLERRM);
        RAISE;
END;
/

-- ===================================================================
-- SECTION 4: RUN + VERIFICATION
-- ===================================================================
-- EXEC load_purchase_fact_incremental;                 -- daily
-- Procedure created above. The EXEC now lives in the folder runner
--   00_run_all_sub_facts.sql
-- so every call and its arguments sit in ONE place.
--   EXEC load_purchase_fact_incremental(DATE '2023-01-01'); -- backfill data2

SELECT (SELECT COUNT(*) FROM purchase_fact) AS fact_rows,
       (SELECT COUNT(*) FROM purchase)      AS source_rows
FROM dual;

-- Which lookup dropped rows, if any. Both must be 0.
SELECT COUNT(*) AS no_date FROM purchase_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM date_dim d
                  WHERE d.cal_date = ls.purchase_date);

SELECT COUNT(*) AS no_supplier FROM purchase_fact_staging_v ls
WHERE NOT EXISTS (SELECT 1 FROM supplier_dim u
                  WHERE u.sup_ID = ls.sup_ID AND u.is_current_flag = 'Y');

-- Cost never exceeds the shelf price it was bought against
SELECT COUNT(*) AS cost_above_price
FROM   purchase_fact f
JOIN   product_dim p ON p.product_key = f.product_key
WHERE  f.purchase_unit_cost > p.product_unit_price;
-- expect 0

-- COGS by year and branch - feeds branch profitability
SELECT d.cal_year, b.br_city,
       ROUND(SUM(f.purchase_total_cost), 2) AS cogs
FROM purchase_fact f
JOIN date_dim   d ON d.date_key   = f.date_key
JOIN branch_dim b ON b.branch_key = f.branch_key
GROUP BY d.cal_year, b.br_city
ORDER BY d.cal_year, cogs DESC;

-- Re-run the EXEC above: expect 0 inserted, 0 updated.
