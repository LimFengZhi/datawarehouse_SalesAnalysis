SET SERVEROUTPUT ON

CREATE OR REPLACE PROCEDURE load_supplier_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
    CURSOR new_suppliers_cursor IS
        SELECT s.*
        FROM   supplier_staging_v s
        WHERE  NOT EXISTS (SELECT 1 FROM supplier_dim d
                           WHERE d.sup_ID = s.sup_ID);
BEGIN
    FOR rec IN new_suppliers_cursor LOOP
        INSERT INTO supplier_dim (
            supplier_key, sup_ID, sup_name, sup_phone, sup_email,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_supplier_key.NEXTVAL,
            rec.sup_ID, rec.clean_sup_name, rec.clean_sup_phone,
            rec.clean_sup_email,
            DATE '2019-01-01',
            DATE '9999-12-31',
            'Y'
        );
        v_new := v_new + 1;
    END LOOP;

    SELECT COUNT(*) INTO v_total FROM supplier_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SUPPLIER_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New suppliers inserted : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Already present        : '
        || (v_total - v_new));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in SUPPLIER_DIM subsequent load: '
            || SQLERRM);
        RAISE;
END;
/