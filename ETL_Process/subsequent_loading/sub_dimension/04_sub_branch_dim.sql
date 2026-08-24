SET SERVEROUTPUT ON

CREATE OR REPLACE PROCEDURE load_branch_dim_incremental AS
    v_new   NUMBER := 0;
    v_total NUMBER := 0;
    CURSOR new_branches_cursor IS
        SELECT s.*
        FROM   branch_staging_v s
        WHERE  NOT EXISTS (SELECT 1 FROM branch_dim d
                           WHERE d.br_ID = s.br_ID);
BEGIN
    FOR rec IN new_branches_cursor LOOP
        INSERT INTO branch_dim (
            branch_key, br_ID, br_name, br_city, br_state, br_email,
            effective_start_date, effective_end_date, is_current_flag
        ) VALUES (
            seq_branch_key.NEXTVAL,
            rec.br_ID, rec.clean_br_name, rec.clean_br_city,
            rec.clean_br_state, rec.clean_br_email,
            DATE '2019-01-01',
            DATE '9999-12-31',
            'Y'
        );
        v_new := v_new + 1;
    END LOOP;

    SELECT COUNT(*) INTO v_total FROM branch_staging_v;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('BRANCH_DIM subsequent load completed:');
    DBMS_OUTPUT.PUT_LINE(' - Source records scanned : ' || v_total);
    DBMS_OUTPUT.PUT_LINE(' - New branches inserted  : ' || v_new);
    DBMS_OUTPUT.PUT_LINE(' - Already present        : '
        || (v_total - v_new));

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        DBMS_OUTPUT.PUT_LINE('Error in BRANCH_DIM subsequent load: '
            || SQLERRM);
        RAISE;
END;
/
