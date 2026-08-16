-- ===================================================================
-- drop_all.sql                  TOTAL RESET OF THE DWH SCHEMA
--
-- *******************************************************************
-- *                                                                 *
-- *   THIS DESTROYS EVERY OBJECT IN THE SCHEMA YOU ARE CONNECTED    *
-- *   AS. Tables, views, sequences, procedures - all of it, both    *
-- *   the warehouse AND the operational database.                   *
-- *                                                                 *
-- *   THERE IS NO UNDO. A dropped table cannot be rolled back.      *
-- *                                                                 *
-- *   Reloading afterwards means re-running SQL*Loader over ~1.2     *
-- *   million CSV rows. Budget a few minutes.                        *
-- *                                                                 *
-- *******************************************************************
--
-- Usage:
--   sqlplus dwh/<password>@XE
--   @c:\Users\laoli\Downloads\datawarehouseAnalysis\drop_all.sql
--
-- CONNECT AS dwh. Never run this as SYSTEM or SYS - it would try to
-- drop whatever schema you happen to be in.
--
-- ===================================================================
-- WHICH RESET DO YOU ACTUALLY WANT?
-- ===================================================================
--   clear_dwh.sql         empties the WAREHOUSE data, keeps every
--                         table, leaves the OLTP untouched. This is
--                         what you want 9 times out of 10 - it lets
--                         you re-run the loads without touching
--                         SQL*Loader again.
--
--   drop_all.sql          (this file) destroys the objects
--                         themselves, OLTP included. Use it when the
--                         DDL itself changed, or when the schema has
--                         got into a state you cannot reason about.
--
-- ===================================================================
-- WHY A LOOP INSTEAD OF A LIST OF DROP STATEMENTS
-- ===================================================================
-- Tables have to be dropped in child-first order or the foreign keys
-- reject the drop. CASCADE CONSTRAINTS removes the FKs pointing at a
-- table as it goes, so the loop can take them in any order and still
-- succeed. PURGE skips the recycle bin, so the space comes back
-- immediately instead of leaving BIN$... objects behind.
--
-- The loop also catches anything the project created that a hand-
-- written list would miss - a leftover staging view, a procedure from
-- an earlier version, an index you added by hand.
-- ===================================================================

SET SERVEROUTPUT ON
SET LINESIZE 200
SET PAGESIZE 200


-- ===================================================================
-- STEP 0  PREVIEW - run this section ON ITS OWN first
-- ===================================================================
PROMPT
PROMPT ============================================================
PROMPT  STEP 0  What is about to be destroyed
PROMPT ============================================================

SELECT USER AS connected_as FROM dual;
-- MUST say DWH. If it says SYSTEM or SYS, STOP and reconnect.

SELECT object_type, COUNT(*) AS how_many
FROM   user_objects
GROUP BY object_type
ORDER BY object_type;

SELECT table_name,
       (SELECT COUNT(*) FROM user_tab_columns c
        WHERE c.table_name = t.table_name) AS cols
FROM   user_tables t
ORDER BY table_name;

PROMPT
PROMPT  >>> If that list contains anything you did NOT create for this
PROMPT  >>> project, STOP NOW. Everything above will be destroyed.
PROMPT


-- ===================================================================
-- STEP 1  DROP ALL TABLES  (warehouse + operational)
-- ===================================================================
PROMPT ============================================================
PROMPT  STEP 1  Dropping tables
PROMPT ============================================================
BEGIN
    FOR t IN (SELECT table_name FROM user_tables ORDER BY table_name) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP TABLE "' || t.table_name
                              || '" CASCADE CONSTRAINTS PURGE';
            DBMS_OUTPUT.PUT_LINE('  dropped table    ' || t.table_name);
        EXCEPTION
            WHEN OTHERS THEN
                -- Keep going: one stubborn table must not stop the reset
                DBMS_OUTPUT.PUT_LINE('  *** FAILED table ' || t.table_name
                                     || ' - ' || SQLERRM);
        END;
    END LOOP;
END;
/


-- ===================================================================
-- STEP 2  DROP ALL VIEWS
-- Dropping a table does NOT drop the views built on it - they are just
-- left INVALID, so they have to go separately.
-- ===================================================================
PROMPT ============================================================
PROMPT  STEP 2  Dropping views
PROMPT ============================================================
BEGIN
    FOR v IN (SELECT view_name FROM user_views ORDER BY view_name) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP VIEW "' || v.view_name || '"';
            DBMS_OUTPUT.PUT_LINE('  dropped view     ' || v.view_name);
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  *** FAILED view  ' || v.view_name
                                     || ' - ' || SQLERRM);
        END;
    END LOOP;
END;
/


-- ===================================================================
-- STEP 3  DROP ALL SEQUENCES
-- The 8 surrogate-key sequences plus any OLTP ones. Emptying a table
-- never resets its sequence, so these must go too or a rebuild would
-- carry on from the old numbers.
-- ===================================================================
PROMPT ============================================================
PROMPT  STEP 3  Dropping sequences
PROMPT ============================================================
BEGIN
    FOR s IN (SELECT sequence_name FROM user_sequences
              ORDER BY sequence_name) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP SEQUENCE "' || s.sequence_name || '"';
            DBMS_OUTPUT.PUT_LINE('  dropped sequence ' || s.sequence_name);
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  *** FAILED seq   ' || s.sequence_name
                                     || ' - ' || SQLERRM);
        END;
    END LOOP;
END;
/


-- ===================================================================
-- STEP 4  DROP ALL PROCEDURES, FUNCTIONS, PACKAGES AND TYPES
-- Every load_*_initial, load_*_incremental and maintain_*_scd2.
-- (Triggers and indexes went with their tables in STEP 1.)
-- ===================================================================
PROMPT ============================================================
PROMPT  STEP 4  Dropping procedures, functions, packages
PROMPT ============================================================
BEGIN
    FOR o IN (SELECT object_name, object_type
              FROM   user_objects
              WHERE  object_type IN ('PROCEDURE','FUNCTION','PACKAGE',
                                     'TYPE','SYNONYM')
              ORDER BY object_type, object_name) LOOP
        BEGIN
            EXECUTE IMMEDIATE 'DROP ' || o.object_type || ' "'
                              || o.object_name || '"';
            DBMS_OUTPUT.PUT_LINE('  dropped ' || RPAD(LOWER(o.object_type), 9)
                                 || o.object_name);
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('  *** FAILED ' || o.object_type || ' '
                                     || o.object_name || ' - ' || SQLERRM);
        END;
    END LOOP;
END;
/


-- ===================================================================
-- STEP 5  EMPTY THE RECYCLE BIN
-- Anything dropped without PURGE is still occupying space as a BIN$...
-- object. This reclaims it.
-- ===================================================================
PROMPT ============================================================
PROMPT  STEP 5  Purging the recycle bin
PROMPT ============================================================
PURGE RECYCLEBIN;


-- ===================================================================
-- STEP 6  VERIFY - the schema must now be empty
-- ===================================================================
PROMPT
PROMPT ============================================================
PROMPT  STEP 6  Verification
PROMPT ============================================================

SELECT object_type, COUNT(*) AS still_there
FROM   user_objects
GROUP BY object_type
ORDER BY object_type;
-- NO ROWS = the schema is completely clean.

SELECT COUNT(*) AS tables_left    FROM user_tables;
SELECT COUNT(*) AS views_left     FROM user_views;
SELECT COUNT(*) AS sequences_left FROM user_sequences;
SELECT COUNT(*) AS recyclebin     FROM user_recyclebin;
-- all four must be 0

-- Space handed back to the tablespace
SELECT ROUND(SUM(bytes) / 1024 / 1024, 1) AS mb_still_used
FROM   user_segments;
-- expect no rows, or 0


-- ===================================================================
-- ALTERNATIVE: drop and recreate the USER itself
-- ===================================================================
-- The loops above leave the dwh account in place with its privileges.
-- If you would rather start from a genuinely new account, do this
-- instead - but it needs a SYSDBA connection, and dwh must not be
-- logged in at the time.
--
--   sqlplus / as sysdba
--
--   DROP USER dwh CASCADE;
--   CREATE USER dwh IDENTIFIED BY yourpassword;
--   GRANT CONNECT, RESOURCE TO dwh;
--   GRANT CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE TO dwh;
--   GRANT UNLIMITED TABLESPACE TO dwh;
--
-- DROP USER ... CASCADE removes every object the user owns in one go.


-- ===================================================================
-- REBUILDING FROM NOTHING
-- ===================================================================
-- 1. operational tables
--      @operational_DB\01_create_operational_db.sql
--
-- 2. the CSVs - data first, then data2 / data3
--      cd sqlloader_control_files
--      load_all.bat dwh <password> XE
--      load_all.bat dwh <password> XE "c:\...\datawarehouseAnalysis\data2"
--
-- 3. warehouse tables
--      @create_dwh.sql
--
-- 4. date dimension, then holidays
--      @initial_loading\init_data_dim\initial_load_date_dim.sql
--      (cd initial_loading\init_data_dim
--       python gen_holidays.py 2019 2022 > holiday_update.sql)
--      @initial_loading\init_data_dim\holiday_update.sql
--
-- 5. dimensions - run the seven init_dimension scripts 01..07
--
-- 6. facts - run the five init_fact scripts 01..05
--
-- 7. check it all with initial_loading\validate_initial_loading.sql
--
-- Then follow LOADING_GUIDE.md Part B for data2 / data3.
-- ===================================================================
