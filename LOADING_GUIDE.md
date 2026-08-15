# Loading the CSVs into Oracle

Loads ~700,000 rows across 14 tables into an Oracle XE schema using SQL\*Loader.
Takes 1–3 minutes.

## What you have

```
datawarehouseAnalysis\
├── 01_create_operational_db.sql     the 14 CREATE TABLE statements
├── data\                            the 14 .csv files
└── sqlloader_control_files\         the 14 .ctl files + load_all.bat / load_all.sh
```

The `.ctl` files and the `.csv` files live in **different folders**. `load_all.bat`
handles that for you — see step 2. It matters if you run `sqlldr` by hand.

## Order of operations

```
1. @01_create_operational_db.sql     create the tables
2. load_all.bat                      load the CSVs
3. verify                            row counts + integrity
4. create sequences                  only if you'll insert new rows later
```

Sequences come **last** on purpose. Every CSV already contains its own ID column, so
you don't need them to load. You need them for rows you insert *afterwards*, and each
must start above the highest ID already present — which you can't know until the data
is in. Create them first and your first manual insert collides with row 1 → `ORA-00001`.

---

## Step 1 — Create the tables

```
sqlplus dwh/yourpassword@XE
```

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\01_create_operational_db.sql

SELECT COUNT(*) FROM user_tables;    -- expect 14
```

If you get `ORA-01950: no privileges on tablespace 'USERS'`, connect as SYSDBA and run
`GRANT UNLIMITED TABLESPACE TO dwh;`, then try again.

---

## Step 2 — Load the data

```
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\sqlloader_control_files
load_all.bat dwh yourpassword XE
```

That's it. The script switches into `..\data` so each control file can find its CSV,
loads all 14 tables in dependency order, and writes one `.log` per table next to itself.

To load CSVs from somewhere else, pass the folder as a 4th argument:

```
load_all.bat dwh yourpassword XE "D:\my_csv_folder"
```

Linux/Mac: `./load_all.sh dwh yourpassword XE`

If your password contains `&`, `^`, `%` or `@`, wrap it in double quotes or cmd will
mangle it and you'll get `ORA-01017`.

### Loading one table by hand

You must be **inside the data folder** — `INFILE 'branch.csv'` in each `.ctl` is
resolved against your current directory, not against the `.ctl` file's location:

```
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\data
sqlldr dwh/yourpassword@XE control=..\sqlloader_control_files\branch.ctl log=branch.log
```

### Why the order matters

`orders.cus_ID` is a foreign key to `customer.cus_ID`, and Oracle checks it on every
row. Load `orders` first and all 161,470 rows are rejected with `ORA-02291`. Parents
before children, always:

```
branch, supplier, product, service, branch_utils_category    no dependencies
staff, customer                                              staff needs branch
branch_expense, salary_payment                               need branch / utils / staff
orders → order_detail                                        order_detail needs orders + product
reservation → reservation_detail
purchase                                                     needs product + branch + supplier
```

`load_all.bat` already uses this order.

---

## Step 3 — Read the logs

Each table writes `<table>.log` into `sqlloader_control_files\`. Look for:

```
Table BRANCH:
  5 Rows successfully loaded.
  0 Rows not loaded due to data errors.
```

If the error count isn't 0, the rejected rows are sitting in `<table>.bad` in the
`data\` folder — the original CSV lines, unchanged — and the log names the column and
the `ORA-` code.

**Re-run only the table that failed.** The control files use `APPEND`, so re-running
everything would double-insert the tables that already succeeded → `ORA-00001`.

---

## Step 4 — Verify

Expected row counts:

| Table | Rows | | Table | Rows |
|---|---:|---|---|---:|
| branch | 5 | | branch_expense | 1,440 |
| supplier | 6 | | salary_payment | 3,135 |
| product | 43 | | orders | 161,470 |
| service | 16 | | order_detail | 349,396 |
| branch_utils_category | 6 | | reservation | 65,110 |
| staff | 96 | | reservation_detail | 88,790 |
| customer | 26,000 | | purchase | 10,615 |

```sql
SELECT 'branch' t, COUNT(*) n FROM branch
UNION ALL SELECT 'customer',     COUNT(*) FROM customer
UNION ALL SELECT 'orders',       COUNT(*) FROM orders
UNION ALL SELECT 'order_detail', COUNT(*) FROM order_detail;
```

**Check for orphans** — must return 0:

```sql
SELECT COUNT(*) FROM orders o
WHERE NOT EXISTS (SELECT 1 FROM customer c WHERE c.cus_ID = o.cus_ID);
```

**Check the dates parsed** — this is the one that catches a silent date-format problem:

```sql
SELECT MIN(order_date), MAX(order_date) FROM orders;
-- expect 2019-01-01 and 2022-12-31

SELECT COUNT(*) FROM reservation
WHERE booking_date BETWEEN DATE '2021-06-01' AND DATE '2021-08-31';
-- expect 0 -- the FMCO lockdown is baked into the dataset
```

**End-to-end join test:**

```sql
SELECT TO_CHAR(o.order_date,'YYYY') yr, b.br_city,
       ROUND(SUM(od.order_quantity * od.order_unit_price - od.order_discount),2) revenue
FROM orders o
JOIN order_detail od ON od.order_ID = o.order_ID
JOIN branch b        ON b.br_ID     = o.br_ID
WHERE o.order_status = 'Completed'
GROUP BY TO_CHAR(o.order_date,'YYYY'), b.br_city
ORDER BY 1, 3 DESC;
```

Kuala Lumpur should top every year and Melaka should be last, matching the branch
ranking in [data/README_DATASET.md](data/README_DATASET.md).

---

## Step 5 — Sequences (only if you'll add data later)

Each sequence must start above the highest existing ID. Let Oracle write the DDL:

```sql
SELECT 'CREATE SEQUENCE seq_customer START WITH '||(MAX(cus_ID)+1)||
       ' INCREMENT BY 1 NOCACHE NOCYCLE;' FROM customer;
```

Then use it explicitly, and commit — sqlplus does **not** autocommit:

```sql
INSERT INTO orders (order_ID, cus_ID, br_ID, st_ID, order_date, order_status)
VALUES (seq_orders.NEXTVAL, 26001, 1, 48, DATE '2026-08-15', 'Completed');

INSERT INTO order_detail (order_det_ID, order_ID, product_ID, order_quantity,
                          order_unit_price, order_discount, order_tax)
VALUES (seq_order_detail.NEXTVAL, seq_orders.CURRVAL, 26, 2, 58.00, 0.00, 6.96);

COMMIT;
```

`seq_orders.CURRVAL` is the ID the previous statement just used, in your session only.
Never use `MAX(order_ID)+1` — two sessions read the same value and one gets `ORA-00001`.

Use `DATE '2026-08-15'` (an ANSI literal) rather than `'15-AUG-26'`. It always means
`YYYY-MM-DD` regardless of your session's `NLS_DATE_FORMAT`.

**If you bulk-load more CSVs later**, the sequence won't know about the new IDs. Resync it:

```sql
-- suppose MAX(cus_ID) is now 30000 but the sequence is only at 26050
ALTER SEQUENCE seq_customer INCREMENT BY 3950;
SELECT seq_customer.NEXTVAL FROM dual;    -- jump the gap
ALTER SEQUENCE seq_customer INCREMENT BY 1;
```

(Oracle 11.2 has no `ALTER SEQUENCE ... RESTART` — that arrived in 12.2.)

---

## Common problems

| Error | Cause | Fix |
|---|---|---|
| `SQL*Loader-500` / `553: file not found` | you ran `sqlldr` from the wrong folder — `INFILE` is relative to your **current directory** | `cd` into `data\` first, or just use `load_all.bat` |
| `ORA-01017: invalid username/password` | typo, or cmd mangled a password containing `& ^ % @` | quote the password |
| `ORA-01950: no privileges on tablespace` | user has no quota | `GRANT UNLIMITED TABLESPACE TO dwh;` as SYSDBA |
| `ORA-02291: parent key not found` | loaded a child before its parent | follow the load order above |
| `ORA-00001: unique constraint violated` | loaded the same table twice, or sequences created too early | `TRUNCATE` and reload; create sequences last |
| `ORA-01861: literal does not match format string` | date format mismatch | the supplied `.ctl` files already set `DATE 'YYYY-MM-DD'` per column — check you're using them |
| `ORA-02290: check constraint violated` | a status/gender value outside the allowed list | values are case-sensitive: `Completed`, not `complete` |
| `ORA-12899: value too large for column` | a value longer than the column | widen the column, or check your column mapping |
| `ORA-00942: table or view does not exist` | step 1 didn't run, or you're connected as the wrong user | re-run `01_create_operational_db.sql` as `dwh` |
| `ORA-00903: invalid table name` on `ORDER` | `ORDER` is reserved in Oracle | the table is named **ORDERS** |

### A note on `direct=true`

`sqlldr ... direct=true` is faster, but it bypasses foreign-key enforcement and can
leave constraints in `ENABLE NOVALIDATE`. For this dataset it saves about a minute and
costs you the integrity checking, so it isn't worth it. `load_all.bat` uses the
conventional path with `rows=5000`, which is fast enough.

---

## Reset and start over

Truncate **child-first** (the reverse of load order):

```sql
TRUNCATE TABLE order_detail;
TRUNCATE TABLE orders;
TRUNCATE TABLE reservation_detail;
TRUNCATE TABLE reservation;
TRUNCATE TABLE purchase;
TRUNCATE TABLE salary_payment;
TRUNCATE TABLE branch_expense;
TRUNCATE TABLE staff;
TRUNCATE TABLE customer;
TRUNCATE TABLE service;
TRUNCATE TABLE product;
TRUNCATE TABLE supplier;
TRUNCATE TABLE branch_utils_category;
TRUNCATE TABLE branch;
```

Or disable every foreign key, load in any order, then re-enable:

```sql
BEGIN
  FOR c IN (SELECT table_name, constraint_name FROM user_constraints
            WHERE constraint_type = 'R') LOOP
    EXECUTE IMMEDIATE 'ALTER TABLE '||c.table_name||
                      ' DISABLE CONSTRAINT '||c.constraint_name;
  END LOOP;
END;
/
-- ... truncate / load ...
BEGIN
  FOR c IN (SELECT table_name, constraint_name FROM user_constraints
            WHERE constraint_type = 'R') LOOP
    EXECUTE IMMEDIATE 'ALTER TABLE '||c.table_name||
                      ' ENABLE CONSTRAINT '||c.constraint_name;
  END LOOP;
END;
/
```

Re-enabling validates every existing row, so if it succeeds without error your
referential integrity is provably clean — a free full integrity check.
