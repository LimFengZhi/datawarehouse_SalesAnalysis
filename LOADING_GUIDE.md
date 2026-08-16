# Loading Guide

End to end, from an empty schema to a six-year warehouse.

Two parts:

- **Part A — first build.** The OLTP tables, the 2019–2022 CSVs in [data/](data/), and the whole
  warehouse. ~700,000 source rows.
- **Part B — adding data2.** The 2023–2024 expansion in [data2/](data2/) *without* wiping what
  Part A built. ~550,000 more rows, a new branch, new products, and a price rise that becomes
  SCD Type 2 history.

Connect as your schema user for everything:

```
sqlplus dwh/yourpassword@XE
```

---

## What you have

```
datawarehouseAnalysis\
├── operational_DB\01_create_operational_db.sql   14 OLTP CREATE TABLEs
├── create_dwh.sql                                13 warehouse tables
├── data\                    14 CSVs, 2019-2022
├── data2\                   14 CSVs, 2023-2024  + 99_price_increase_2023.sql
├── data3\                   14 CSVs, 2025       + 99_price_change_2025.sql
├── sqlloader_control_files\ 14 .ctl + load_all.bat
│
├── initial_loading\
│   ├── init_data_dim\   date_dim + gen_holidays.py
│   ├── init_dimension\  the 7 source-fed dimensions
│   ├── init_fact\       the 5 fact tables
│   └── validate_initial_loading.sql     all Part A checks
│
├── subsequent_loading\
│   ├── sub_dimension\   NEW dimension records only     (create-only)
│   ├── maintain_SCD2\   CHANGED records -> versions    (create-only)
│   ├── sub_fact\        new + changed fact rows        (create-only)
│   ├── execute_sub_procedure.sql        RUNS the data2 load (2023-24)
│   ├── execute_sub2.sql                 RUNS the data3 load (2025)
│   └── validate_subsequent_loading.sql  all Part B checks
│
├── clear_dwh.sql          empty the warehouse, keep the tables
└── drop_all.sql           destroy every object in the schema
```

The numbered `subsequent_loading` scripts only CREATE views and procedures — the `execute_*` files
run them. The `initial_loading` scripts create **and run** their own procedure.

---

# PART A — First build (2019–2022)

## A1. Create the OLTP tables

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\operational_DB\01_create_operational_db.sql
SELECT COUNT(*) FROM user_tables;    -- expect 14
```

If you get `ORA-01950: no privileges on tablespace 'USERS'`, connect as SYSDBA and run
`GRANT UNLIMITED TABLESPACE TO dwh;`.

## A2. Load the 2019–2022 CSVs

```
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\sqlloader_control_files
load_all.bat dwh yourpassword XE
```

The script switches into `..\data` so each control file finds its CSV, then loads all 14 tables in
dependency order. Logs land next to the script, **suffixed with the data folder** so a later run
against `data2\` doesn't overwrite them — check `branch_data.log` first:

```
Table BRANCH:
  5 Rows successfully loaded.
  0 Rows not loaded due to data errors.
```

Expect 1–3 minutes, nearly all of it in `order_detail` (349,396 rows).

**Why the order matters.** `orders.cus_ID` is a foreign key to `customer.cus_ID`, checked on every
row. Load `orders` before `customer` and all 161,470 rows bounce with `ORA-02291`. Parents before
children — `load_all.bat` already does this.

Verify:

```sql
SELECT 'customer' t, COUNT(*) n FROM customer
UNION ALL SELECT 'orders',       COUNT(*) FROM orders
UNION ALL SELECT 'order_detail', COUNT(*) FROM order_detail;
-- expect 26000 / 161470 / 349396
```

## A3. Create the warehouse tables

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\create_dwh.sql
-- expect 13 tables: 8 dimensions + 5 facts
```

## A4. Date dimension, then holidays

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\initial_loading\init_data_dim\initial_load_date_dim.sql
-- expect 1462 rows (1,461 days + the Unknown member)
```

Holidays are **not** automatic — every day loads with `holiday_ind = 'N'`:

```
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\initial_loading\init_data_dim
python gen_holidays.py 2019 2022 > holiday_update.sql
```
```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\initial_loading\init_data_dim\holiday_update.sql
SELECT COUNT(*) FROM date_dim WHERE holiday_ind = 'Y';   -- must be > 0
```

## A5. Dimensions

Run all seven, in order — each one creates its staging view, sequence and procedure, then runs it:

```sql
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\initial_loading\init_dimension
```
```sql
@01_init_branch_dim.sql
@02_init_branch_utils_dim.sql
@03_init_supplier_dim.sql
@04_init_service_dim.sql
@05_init_product_dim.sql
@06_init_staff_dim.sql
@07_init_customer_dim.sql
```

Expect 5 / 6 / 6 / 16 / 43 / 96 / 26,000.

## A6. Facts

```sql
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\initial_loading\init_fact
```
```sql
@01_init_order_fact.sql
@02_init_reservation_fact.sql
@03_init_purchase_fact.sql
@04_init_salary_payment_fact.sql
@05_init_branch_expense_fact.sql
```

Expect 349,396 / 88,790 / 10,615 / 3,135 / 1,440.

`order_fact` is the slow one — 349k rows joined to five dimensions. Give it a few minutes.

## A7. Validate everything

One script runs every Part A check — row counts, orphans, duplicate keys, failed dimension
lookups, measure arithmetic and the COVID/revenue patterns:

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\initial_loading\validate_initial_loading.sql
```

Every check labelled "must be 0" that comes back non-zero tells you exactly which table and which
lookup to investigate.

---

# PART B — Adding data2 (2023–2024)

This appends. Nothing from Part A is deleted.

**Do the steps in this order.** Each one depends on the one before, and getting them out of order
fails *silently* rather than loudly — see the note at the end of this part.

## B1. Load the 2023–2024 CSVs

```
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\sqlloader_control_files
load_all.bat dwh yourpassword XE "c:\Users\laoli\Downloads\datawarehouseAnalysis\data2"
```

The 4th argument points the same control files at the other folder. Every file in `data2\` is named
exactly like its counterpart in `data\` with identical headers, and every `.ctl` uses `APPEND`, so
the rows are added to the existing tables. IDs continue from where `data\` stopped — no collisions.

`supplier_data2.log` and `branch_utils_category_data2.log` will show **0 rows**. That is correct:
those two files are header-only because data2 adds no new suppliers or utility categories.

**Nothing to clean before a re-run.** SQL\*Loader overwrites its log each time — it never appends.
And `load_all.bat` now deletes any old `.bad` before each table loads, so a `.bad` file present
afterwards always means *this* run rejected rows. No `.bad` file means nothing was rejected.

Verify the totals are now `data` + `data2`:

```sql
SELECT 'branch'   t, COUNT(*) n, 6      expected FROM branch
UNION ALL SELECT 'staff',        COUNT(*), 114    FROM staff
UNION ALL SELECT 'product',      COUNT(*), 48     FROM product
UNION ALL SELECT 'service',      COUNT(*), 18     FROM service
UNION ALL SELECT 'customer',     COUNT(*), 32000  FROM customer
UNION ALL SELECT 'orders',       COUNT(*), 290709 FROM orders
UNION ALL SELECT 'order_detail', COUNT(*), 635340 FROM order_detail
UNION ALL SELECT 'reservation',  COUNT(*), 119663 FROM reservation
UNION ALL SELECT 'reservation_detail', COUNT(*), 156888 FROM reservation_detail
UNION ALL SELECT 'purchase',       COUNT(*), 16937 FROM purchase
UNION ALL SELECT 'salary_payment', COUNT(*), 5781  FROM salary_payment
UNION ALL SELECT 'branch_expense', COUNT(*), 2292  FROM branch_expense;
```

## B2. Apply the 2023 price rise

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\data2\99_price_increase_2023.sql
```

Seven top sellers go up, effective 2023-01-01. The data2 order lines already carry the new prices,
so this brings the OLTP `product` table into step with them.

Must run **before** B5, which turns the change into dimension history.

## B3. Create the 19 procedures (first time only)

The `subsequent_loading` numbered scripts are **create-only** — each defines one procedure and
executes nothing. Run all 19 once, in any order:

```sql
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\subsequent_loading
```
```sql
@sub_dimension\01_sub_date_dim.sql
@sub_dimension\02_sub_supplier_dim.sql
@sub_dimension\03_sub_product_dim.sql
@sub_dimension\04_sub_branch_dim.sql
@sub_dimension\05_sub_service_dim.sql
@sub_dimension\06_sub_branch_utils_dim.sql
@sub_dimension\07_sub_staff_dim.sql
@sub_dimension\08_sub_customer_dim.sql
@maintain_SCD2\01_maintain_supplier_dim.sql
@maintain_SCD2\02_maintain_product_dim.sql
@maintain_SCD2\03_maintain_branch_dim.sql
@maintain_SCD2\04_maintain_service_dim.sql
@maintain_SCD2\05_maintain_staff_dim.sql
@maintain_SCD2\06_maintain_customer_dim.sql
@sub_fact\01_sub_order_fact.sql
@sub_fact\02_sub_reservation_fact.sql
@sub_fact\03_sub_purchase_fact.sql
@sub_fact\04_sub_salary_payment_fact.sql
@sub_fact\05_sub_branch_expense_fact.sql
```

Already ran them for an earlier load? Skip this step — the procedures are still there.

## B4. Run the whole load

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\subsequent_loading\execute_sub_procedure.sql
```

One file does everything, in the only safe order:

- **STEP 0** — checks all 19 procedures exist and are VALID before calling any of them
- **STEP 1** — extends the calendar to 2024, then inserts the NEW records: the Ipoh branch, its
  18 staff, 5 products, 2 services and 6,000 customers
- **STEP 2** — turns the price rise into SCD2 history:
  `maintain_product_dim_scd2(DATE '2023-01-01')` expires the 7 old price versions on 2022-12-31
  and opens the new ones on 2023-01-01. `product_dim` now holds 55 rows — 48 current + 7 expired
- **STEP 3** — the facts, each backfilled with `(DATE '2023-01-01')`. The window opens one day
  early by design (`src_date >= p_load_date - 1`) and has no upper bound, so one call loads all of
  data2. The `NOT EXISTS` anti-join skips anything already loaded

**Why the calendar comes first.** Every fact staging view uses `INNER JOIN` to resolve its
dimension keys. An unresolved key does not raise an error — the row is silently **dropped**. If
`date_dim` stopped at 2022-12-31, all 285,944 new order lines would vanish with no warning.

**Idempotent:** run the file twice and the second pass reports 0 inserted, 0 expired, 0 updated.

## B5. Holidays for the new years

The 2023–24 days arrive with `holiday_ind = 'N'`, so regenerate over the wider range:

```
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\initial_loading\init_data_dim
python gen_holidays.py 2019 2024 > holiday_update.sql
```
```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\initial_loading\init_data_dim\holiday_update.sql

SELECT cal_year, COUNT(*) AS holidays FROM date_dim
WHERE holiday_ind = 'Y' GROUP BY cal_year ORDER BY cal_year;
-- every year 2019..2024 present, none zero
```

The generated file resets **only the years it covers**, so a partial regeneration
(`gen_holidays.py 2023 2024`) leaves 2019–2022 untouched.

## B6. Validate everything

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\subsequent_loading\validate_subsequent_loading.sql
```

Covers calendar continuity, dimension coverage, SCD2 integrity (one current row per key, no
dangling 9999-12-31 end dates, no orphaned facts), version history, fact-vs-source counts and the
business patterns. Every "must be 0" that is not 0 names the table to investigate.

## Loading data3 (2025) later

Same pattern, different file: load the `data3\` CSVs with `load_all.bat ... "...\data3"`, apply
`data3\99_price_change_2025.sql`, then run `execute_sub2.sql` and regenerate holidays to 2025.
The procedures from B3 are reused as-is.

---

## Order of everything, at a glance

```
PART A                                     PART B
A1  create OLTP tables                     B1  load_all.bat ... "...\data2"
A2  load_all.bat  (data)                   B2  99_price_increase_2023.sql
A3  create_dwh.sql                         B3  create the 19 procedures (once)
A4  date_dim + holidays                    B4  execute_sub_procedure.sql
A5  dimensions                             B5  regenerate holidays to 2024
A6  facts                                  B6  validate_subsequent_loading.sql
A7  validate_initial_loading.sql
```

---

## Three levels of reset

| Script | What it does | When |
|---|---|---|
| `TRUNCATE TABLE order_fact;` | one fact table | a single load went wrong |
| [clear_dwh.sql](clear_dwh.sql) | empties all dims + facts, drops the 8 sequences, **keeps the tables and the OLTP** | re-run the warehouse build without touching SQL\*Loader |
| [drop_all.sql](drop_all.sql) | destroys every object in the schema, OLTP included | the DDL changed, or the schema is unreasonable |

`clear_dwh.sql` is the one you want almost every time. `drop_all.sql` costs you another full
SQL\*Loader run over 1.2 million rows.

**Dimensions need `DELETE`, not `TRUNCATE`** — Oracle blocks `TRUNCATE` on a parent table whenever
an enabled foreign key references it, even when the child is empty (`ORA-02266`). Facts have no
children, so `TRUNCATE` works there and is much faster.

---

## Common problems

| Error | Cause | Fix |
|---|---|---|
| `SQL*Loader-500` / `553: file not found` | ran `sqlldr` from the wrong folder — `INFILE` is relative to your **current directory** | use `load_all.bat`, which handles it |
| `ORA-01017: invalid username/password` | typo, or cmd mangled a password containing `& ^ % @` | quote the password |
| `ORA-01950: no privileges on tablespace` | user has no quota | `GRANT UNLIMITED TABLESPACE TO dwh;` as SYSDBA |
| `ORA-02291: parent key not found` | loaded a child before its parent | follow the load order |
| `ORA-00001: unique constraint violated` | loaded the same CSV twice, or a sequence was not reset | `TRUNCATE` and reload; `clear_dwh.sql` drops the sequences |
| `ORA-01861: literal does not match format string` | date format mismatch | the `.ctl` files already set `DATE 'YYYY-MM-DD'` per column |
| `ORA-02290: check constraint violated` | a status or gender value outside the allowed list | values are case-sensitive: `Completed`, not `complete` |
| `ORA-12899: value too large for column` | a value longer than the column | widen the column, or check the mapping |
| `ORA-00942: table or view does not exist` | a step was skipped, or you are the wrong user | check the order above |
| `ORA-02266: unique/primary keys referenced by enabled foreign keys` | `TRUNCATE` on a dimension | use `DELETE`, or `clear_dwh.sql` |
| `PLS-00905: object ... is invalid` | the procedure compiled with errors | `SELECT line, text FROM user_errors WHERE name = '<PROC>' ORDER BY sequence;` — that shows the real message |
| **loads 0 rows, no error** | a dimension is empty, or `date_dim` does not reach the transaction dates | run the dry-run query below |
| `ORA-00903: invalid table name` on `ORDER` | `ORDER` is reserved in Oracle | the table is named **ORDERS** |

The last two are the ones that cost the most time — a silent 0-row load is not an error, and
`PLS-00905` deliberately hides the message you need.

### When a fact loads 0 rows

Run the exact join the procedure uses. If this returns a number but the load inserted nothing, the
"already contains data" guard stopped it. If it returns **0**, a dimension is the problem:

```sql
SELECT COUNT(*) AS would_insert
FROM order_fact_staging_v ls
JOIN date_dim     d ON d.cal_date   = ls.order_date
JOIN product_dim  p ON p.product_ID = ls.product_ID AND p.is_current_flag='Y'
JOIN customer_dim c ON c.cus_ID     = ls.cus_ID     AND c.is_current_flag='Y'
JOIN staff_dim    s ON s.st_ID      = ls.st_ID      AND s.is_current_flag='Y'
JOIN branch_dim   b ON b.br_ID      = ls.br_ID      AND b.is_current_flag='Y';
```

Then drop one join at a time until the count jumps — that names the culprit. Or check the usual
suspects directly:

```sql
-- does date_dim cover the transactions?
SELECT (SELECT MAX(cal_date) FROM date_dim WHERE date_key <> 0) AS dim_last_day,
       (SELECT MAX(order_date) FROM orders)                     AS last_order
FROM dual;
-- last_order after dim_last_day -> EXEC load_date_dim_incremental(2024);

-- are the dimensions populated, and flagged 'Y'?
SELECT 'customer_dim' d, COUNT(*) total,
       SUM(CASE WHEN is_current_flag='Y' THEN 1 ELSE 0 END) current_rows
FROM customer_dim
UNION ALL SELECT 'product_dim', COUNT(*),
       SUM(CASE WHEN is_current_flag='Y' THEN 1 ELSE 0 END) FROM product_dim;
```

And when a procedure is invalid, this shows the message `PLS-00905` is hiding:

```sql
SELECT line, text FROM user_errors
WHERE name = 'LOAD_ORDER_FACT_INITIAL' ORDER BY sequence;
```
