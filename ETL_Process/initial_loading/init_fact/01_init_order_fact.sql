-- ===================================================================
-- 01_init_order_fact.sql        ORDER_FACT
-- Grain: one row per PRODUCT per ORDER
-- Source: ORDER_DETAIL joined to ORDERS
--
--   SECTION 1: staging VIEW - OLTP cleansing + line aggregation
--   SECTION 2: no sequence   - PK is composite (dimension keys +
--                              order_ID); (order_ID, product_key) is
--                              unique by grain (no constraint) and drives the NOT EXISTS
--   SECTION 3: PROCEDURE     - resolves surrogate keys, then inserts
--   SECTION 4: run
--
-- GRAIN: the ERD carries no order-line ID on the fact, so the fact is
-- one row per (order, product). The OLTP can put the same product on
-- two lines of one order (it happens on ~2 % of lines), and those
-- lines would otherwise collide on the composite PK - so the staging
-- view GROUPs BY (order_ID, product_ID) and SUMs qty / discount / tax.
-- line_count says how many OLTP lines were folded into the row; it is
-- not stored on the fact, only used by the loads and the validation.
--
-- The view never touches the dimensions: it exposes NATURAL keys
-- (cus_ID, br_ID, st_ID, product_ID) and the raw order_date. The
-- surrogate-key lookups live in the procedure, and the same view is
-- reused by the incremental load in ETL_Process\subsequent_loading\sub_fact\.
--
-- MONEY: order_detail stores NO unit price (order_unit_price no longer
-- exists). The unit price of a line is the PRODUCT's price in force on
-- the order date, i.e. product_dim.product_unit_price of the SCD2
-- version whose effective range contains orders.order_date. So the
-- view emits qty / discount / tax only, and order_total_amt is computed
-- in the PROCEDURE, where the product_dim version is already joined:
--     order_total_amt = SUM(qty) * p.product_unit_price - SUM(discount) + SUM(tax)
--     order_net_amt   = SUM(qty) * p.product_unit_price - SUM(discount)
-- (one order date -> one price version, so summing first is exact).
-- order_net_amt is order_total_amt without the SST: the tax is collected
-- for the government, so it is net_amt - not total_amt - that analysis
-- queries should sum as revenue.
-- ===================================================================

SET SERVEROUTPUT ON

-- ===================================================================
-- SECTION 1: CORE ETL TRANSFORMATION LOGIC (VIEW)
-- ===================================================================
CREATE OR REPLACE VIEW order_fact_staging_v AS
SELECT
    o.order_ID,                                   -- degenerate dim
    od.product_ID,                                -- (order_ID, product_ID) = the grain

    -- ---------- NATURAL keys, resolved to surrogates in SECTION 3 ----
    o.cus_ID,
    o.br_ID,
    o.st_ID,
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

    -- Quantity must be at least 1 per line - the OLTP CHECK says > 0,
    -- but a staging view should never assume the source honoured it.
    -- Summed over the lines of the same product in the order.
    SUM(CASE
            WHEN od.order_qty IS NULL OR od.order_qty <= 0 THEN 1
            WHEN od.order_qty > 999 THEN 999
            ELSE od.order_qty
        END)                                       AS clean_order_qty,

    -- Money components, summed over the folded lines. The unit price is
    -- NOT here (see header): the procedure multiplies clean_order_qty
    -- by the product_dim price.
    SUM(ROUND(NVL(od.order_discount, 0), 2))       AS clean_discount_amt,
    SUM(ROUND(NVL(od.order_tax, 0), 2))            AS clean_tax_amt,

    -- How many OLTP order_detail lines were folded into this row
    COUNT(*)                                       AS line_count,

    -- ---------- data quality flags ----------
    MAX(CASE WHEN od.order_qty IS NULL OR od.order_qty <= 0
                  OR od.order_qty > 999
             THEN 'Y' ELSE 'N' END)                AS qty_corrected,
    CASE WHEN o.order_status IS NULL
         THEN 'Y' ELSE 'N' END                     AS status_defaulted,
    MAX(CASE WHEN od.order_discount IS NULL OR od.order_tax IS NULL
             THEN 'Y' ELSE 'N' END)                AS money_defaulted

FROM order_detail od
JOIN orders o ON o.order_ID = od.order_ID
-- Rows missing a key cannot be loaded at all. Excluding them HERE makes
-- the loss explicit and countable, instead of letting a dimension join
-- drop them silently later.
WHERE o.order_ID      IS NOT NULL
  AND o.order_date    IS NOT NULL
  AND o.cus_ID        IS NOT NULL
  AND o.br_ID         IS NOT NULL
  AND o.st_ID         IS NOT NULL
  AND od.product_ID   IS NOT NULL
GROUP BY o.order_ID, od.product_ID, o.cus_ID, o.br_ID, o.st_ID,
         TRUNC(o.order_date), o.order_status;

-- ===================================================================
-- SECTION 3: ETL (INITIAL LOADING)
-- This is where the natural keys become surrogate keys, and where the
-- product_dim price turns qty / discount / tax into order_total_amt.
-- ===================================================================
CREATE OR REPLACE PROCEDURE load_order_fact_initial AS
    v_count    NUMBER;
    v_errors   NUMBER := 0;
    v_orphaned NUMBER := 0;
    v_source   NUMBER := 0;
    v_lines    NUMBER := 0;
BEGIN
    SELECT COUNT(*) INTO v_count FROM order_fact;

    IF v_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('ORDER_FACT already contains data. Use '
            || 'load_order_fact_incremental for updates.');
        RETURN;
    END IF;

    -- Source grain is (order, product): count the distinct pairs, not
    -- the order_detail lines, or duplicate-product lines would look
    -- like rows that failed to load.
    SELECT COUNT(*) INTO v_source
    FROM  (SELECT DISTINCT order_ID, product_ID FROM order_detail);
    SELECT COUNT(*) INTO v_lines FROM order_detail;

    INSERT INTO order_fact (
        date_key, product_key, customer_key, staff_key, branch_key,
        order_ID, order_status,
        order_qty, order_discount_amt, order_tax_amt, order_total_amt,
        order_net_amt
    )
    SELECT
        d.date_key,
        p.product_key,
        c.customer_key,
        s.staff_key,
        b.branch_key,
        ls.order_ID,
        ls.clean_order_status,
        ls.clean_order_qty,
        ls.clean_discount_amt,
        ls.clean_tax_amt,
        -- Unit price = the product_dim version in force on the order
        -- date (joined below), so a later price change (new SCD2
        -- version) never rewrites history.
        ROUND(  ls.clean_order_qty * p.product_unit_price
              - ls.clean_discount_amt
              + ls.clean_tax_amt, 2)                AS order_total_amt,
        -- the same base terms without the tax = revenue
        ROUND(  ls.clean_order_qty * p.product_unit_price
              - ls.clean_discount_amt, 2)           AS order_net_amt
    -- Each SCD2 join picks the version IN FORCE ON THE ORDER DATE, not
    -- whichever version happens to be current at load time - so a
    -- backfill after later maintenance still lands on the right version.
    FROM order_fact_staging_v ls
    JOIN date_dim     d ON d.cal_date   = ls.order_date
    JOIN product_dim  p ON p.product_ID = ls.product_ID
                       AND ls.order_date BETWEEN p.effective_start_date
                                             AND p.effective_end_date
    JOIN customer_dim c ON c.cus_ID     = ls.cus_ID
                       AND ls.order_date BETWEEN c.effective_start_date
                                             AND c.effective_end_date
    JOIN staff_dim    s ON s.st_ID      = ls.st_ID
                       AND ls.order_date BETWEEN s.effective_start_date
                                             AND s.effective_end_date
    JOIN branch_dim   b ON b.br_ID      = ls.br_ID;

    v_count := SQL%ROWCOUNT;

    -- How many rows the cleansing had to repair
    SELECT COUNT(*) INTO v_errors
    FROM   order_fact_staging_v
    WHERE  qty_corrected = 'Y'
       OR  status_defaulted = 'Y' OR money_defaulted = 'Y';

    -- How many source (order, product) groups never made it, for any reason
    v_orphaned := v_source - v_count;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('ORDER_FACT initial load completed:');
    DBMS_OUTPUT.PUT_LINE(' - OLTP order lines read   : ' || v_lines);
    DBMS_OUTPUT.PUT_LINE(' - (order, product) groups : ' || v_source);
    DBMS_OUTPUT.PUT_LINE(' - Records inserted        : ' || v_count);
    DBMS_OUTPUT.PUT_LINE(' - Data quality corrections: ' || v_errors);
    DBMS_OUTPUT.PUT_LINE(' - Source groups not loaded: ' || v_orphaned);

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
-- SECTION 4: RUN
-- ===================================================================
EXEC load_order_fact_initial;
