SET SERVEROUTPUT ON


CREATE OR REPLACE PROCEDURE load_service_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
    CURSOR new_services_cursor IS
        SELECT s.*
        FROM   service_staging_v s
        WHERE  NOT EXISTS (SELECT 1 FROM service_dim d
                           WHERE d.serv_ID = s.serv_ID);
BEGIN
    FOR rec IN new_services_cursor LOOP
        INSERT INTO service_dim (
            service_key, serv_ID, serv_name, serv_category, serv_price,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_service_key.NEXTVAL,
            rec.serv_ID, rec.clean_serv_name, rec.clean_serv_category,
            rec.clean_serv_price,
            DATE '2019-01-01',
            DATE '9999-12-31',
            'Y'
        );
        v_new := v_new + 1;
    END LOOP;

    SELECT COUNT(*) INTO v_total FROM service_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('SERVICE_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New services inserted  : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Already present        : '
        || (v_total - v_new));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in SERVICE_DIM subsequent load: '
            || SQLERRM);
        RAISE;
END;
/
