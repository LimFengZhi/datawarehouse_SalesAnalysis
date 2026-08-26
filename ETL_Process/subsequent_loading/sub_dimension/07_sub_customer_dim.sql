SET SERVEROUTPUT ON

CREATE OR REPLACE PROCEDURE load_customer_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
    CURSOR new_customers_cursor IS
        SELECT s.*
        FROM   customer_staging_v s
        WHERE  NOT EXISTS (SELECT 1 FROM customer_dim d
                           WHERE d.cus_ID = s.cus_ID);
BEGIN
    FOR rec IN new_customers_cursor LOOP
        INSERT INTO customer_dim (
            customer_key, cus_ID, cus_name, cus_email, cus_gender, cus_city,
            cus_state, cus_age_group, cus_loyalty_tier,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_customer_key.NEXTVAL,
            rec.cus_ID, rec.clean_cus_name, rec.clean_cus_email,
            rec.clean_cus_gender, rec.clean_cus_city, rec.clean_cus_state,
            rec.derived_cus_age_group, rec.clean_cus_loyalty_tier,
            DATE '2019-01-01',
            DATE '9999-12-31',
            'Y'
        );
        v_new := v_new + 1;
    END LOOP;

    SELECT COUNT(*) INTO v_total FROM customer_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('CUSTOMER_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New customers inserted : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Already present        : '
        || (v_total - v_new));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in CUSTOMER_DIM subsequent load: '
            || SQLERRM);
        RAISE;
END;
/
