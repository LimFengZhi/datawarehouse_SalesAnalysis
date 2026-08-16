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
├── operationalDB\01_create_operational_db.sql    14 OLTP CREATE TABLEs
├── create_dwh.sql                                13 warehouse tables
├── data\                    14 CSVs, 2019-2022
├── data2\                   14 CSVs, 2023-2024  + 99_price_increase_2023.sql
├── sqlloader_control_files\ 14 .ctl + load_all.bat
│
├── initialLoading\
│   ├── init_data_dim\   date_dim + gen_holidays.py
│   ├── init_dimension\  the 7 source-fed dimensions
│   └── init_fact\       the 5 fact tables  (+ 00_diagnose.sql)
│
├── subsequentLoading\
│   ├── sub_dimension\   NEW dimension records only
│   ├── maintain_SCD2\   CHANGED dimension records -> versions
│   └── sub_fact\        new + changed fact rows
│
├── 00_clear_all.sql       empty the warehouse, keep the tables
├── 99_drop_everything.sql destroy every object in the schema
└── RUN_ALL.sql            Part A steps 3-6 in one command
```

Every `00_run_all_*.sql` runs its whole folder. The numbered files inside can also be run one at a
time when something goes wrong.

---

# PART A — First build (2019–2022)

## A1. Create the OLTP tables

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\operationalDB\01_create_operational_db.sql
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
@c:\Users\laoli\Downloads\datawarehouseAnalysis\initialLoading\init_data_dim\initial_load_date_dim.sql
-- expect 1462 rows (1,461 days + the Unknown member)
```

Holidays are **not** automatic — every day loads with `holiday_ind = 'N'`:

```
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\initialLoading\init_data_dim
python gen_holidays.py 2019 2022 > holiday_update.sql
```
```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\initialLoading\init_data_dim\holiday_update.sql
SELECT COUNT(*) FROM date_dim WHERE holiday_ind = 'Y';   -- must be > 0
```

## A5. Dimensions

Run all seven, in order — each one is self-contained and ends with its own verification:

```sql
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\initialLoading\init_dimension
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
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\initialLoading\init_fact
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

**Steps A3–A6 in one command:** `@RUN_ALL.sql` (it clears the warehouse first, so only use it when
that is what you want).

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

## B3. Extend the calendar, then the holidays

```sql
EXEC load_date_dim_incremental(2024);
SELECT COUNT(*) FROM date_dim;    -- expect 2193 (2,192 days + Unknown)
```

**This is the step people skip.** Without it `date_dim` stops at 2022-12-31 and every 2023–24
transaction fails its date lookup and is silently dropped in B6.

New years arrive with no holidays, so regenerate over the wider range:

```
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\initialLoading\init_data_dim
python gen_holidays.py 2019 2024 > holiday_update.sql
```
```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\initialLoading\init_data_dim\holiday_update.sql

SELECT cal_year, COUNT(*) AS holidays FROM date_dim
WHERE holiday_ind = 'Y' GROUP BY cal_year ORDER BY cal_year;
-- every year 2019..2024 present, none zero
```

The generated file resets **only the years it covers**, so a partial regeneration
(`gen_holidays.py 2023 2024`) leaves 2019–2022 untouched.

## B4. New dimension records

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\subsequentLoading\sub_dimension\00_run_all_sub_dimensions.sql
```

Insert-new-only. Adds the Ipoh branch, its 18 staff, 5 products, 2 services and 6,000 customers.
Nothing is updated or expired here.

```sql
SELECT 'branch_dim' t, COUNT(*) n, 6 expected FROM branch_dim
UNION ALL SELECT 'staff_dim',    COUNT(*), 114   FROM staff_dim
UNION ALL SELECT 'product_dim',  COUNT(*), 48    FROM product_dim
UNION ALL SELECT 'service_dim',  COUNT(*), 18    FROM service_dim
UNION ALL SELECT 'customer_dim', COUNT(*), 32000 FROM customer_dim;
```

## B5. SCD2 — turn the price rise into history

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\subsequentLoading\maintain_SCD2\00_run_all_maintain_scd2.sql
```

That runs every dimension with `SYSDATE` as the change date. For the price rise you want the **real**
date instead, so run product on its own first:

```sql
EXEC maintain_product_dim_scd2(DATE '2023-01-01');
-- expect 7 expired, 7 new versions
```

```sql
SELECT product_key, product_ID, product_name, product_unit_price,
       effective_start_date, effective_end_date, is_current_flag
FROM   product_dim
WHERE  product_ID IN (4, 12, 15, 16, 21, 23, 30)
ORDER  BY product_ID, product_key;
-- 14 rows: 7 flagged 'N' ending 2022-12-31, 7 flagged 'Y' from 2023-01-01
```

`product_dim` now holds **55 rows** — 48 current plus 7 expired. That is the point of Type 2: the
2019–2022 order lines keep pointing at the old `product_key` and still report the old price.

## B6. Facts

```sql
@c:\Users\laoli\Downloads\datawarehouseAnalysis\subsequentLoading\sub_fact\00_run_all_sub_facts.sql
```

Each script is preset to backfill all of data2:

```sql
EXEC load_order_fact_incremental(DATE '2023-01-01');   -- order_date >= 2022-12-31
```

**Just pass the first date you want — don't add a day.** The procedure filters
`src_date >= p_load_date - 1`, so it already opens the window one day early. That extra day is what
makes a daily run safe (it catches rows that arrived late for yesterday); on a backfill it simply
re-reads one already-loaded day, which the `NOT EXISTS` anti-join skips.

The window has **no upper bound**, so one call from an early date loads everything after it. For a
normal daily run, call it with no argument and it covers yesterday and today.

Two steps run per fact — **insert** new rows, then **update** rows already loaded whose values
moved. The update matters because `order_status` and `res_status` are not frozen: an order goes
Processing → Completed, a booking goes Confirmed → No-Show. Insert-only would freeze every booking
at Confirmed and report a no-show rate of zero forever.

Verify fact equals source:

```sql
SELECT 'order_fact' t, (SELECT COUNT(*) FROM order_fact) n,
       (SELECT COUNT(*) FROM order_detail) src FROM dual
UNION ALL SELECT 'reservation_fact', (SELECT COUNT(*) FROM reservation_fact),
       (SELECT COUNT(*) FROM reservation_detail) FROM dual
UNION ALL SELECT 'purchase_fact', (SELECT COUNT(*) FROM purchase_fact),
       (SELECT COUNT(*) FROM purchase) FROM dual
UNION ALL SELECT 'salary_payment_fact', (SELECT COUNT(*) FROM salary_payment_fact),
       (SELECT COUNT(*) FROM salary_payment) FROM dual
UNION ALL SELECT 'branch_expense_fact', (SELECT COUNT(*) FROM branch_expense_fact),
       (SELECT COUNT(*) FROM branch_expense) FROM dual;
```

Then six years of revenue:

```sql
SELECT d.cal_year,
       ROUND(SUM(f.order_gross_amt - f.order_discount_amt), 2) AS product_rev
FROM   order_fact f JOIN date_dim d ON d.date_key = f.date_key
WHERE  f.order_status = 'Completed'
GROUP  BY d.cal_year ORDER BY d.cal_year;
-- 2020-2021 dip (lockdowns), 2022 recovers, 2023-24 grow on
```

## Why B3 before B6 — the silent failure

Every fact staging view uses `INNER JOIN` to resolve its dimension keys. An unresolved key does not
raise an error; the row is simply **dropped**. Skip B3 and all 285,944 new order lines vanish with
no warning at all.

Each procedure counts what it lost and prints a warning, and the runner's SUMMARY 2 shows which
dimension is responsible. If a count looks wrong, that is the first place to look.

---

## Order of everything, at a glance

```
PART A                                     PART B
A1  create OLTP tables                     B1  load_all.bat ... "...\data2"
A2  load_all.bat  (data)                   B2  99_price_increase_2023.sql
A3  create_dwh.sql                         B3  load_date_dim_incremental(2024)
A4  date_dim + holidays                        + regenerate holidays
A5  dimensions                             B4  sub_dimension    (new records)
A6  facts                                  B5  maintain_SCD2    (changed records)
                                           B6  sub_fact         (new + changed)
```

---

## Three levels of reset

| Script | What it does | When |
|---|---|---|
| `TRUNCATE TABLE order_fact;` | one fact table | a single load went wrong |
| [00_clear_all.sql](00_clear_all.sql) | empties all dims + facts, drops the 8 sequences, **keeps the tables and the OLTP** | re-run the warehouse build without touching SQL\*Loader |
| [99_drop_everything.sql](99_drop_everything.sql) | destroys every object in the schema, OLTP included | the DDL changed, or the schema is unreasonable |

`00_clear_all.sql` is the one you want almost every time. `99_` costs you another full SQL\*Loader
run over 1.2 million rows.

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
| `ORA-00001: unique constraint violated` | loaded the same CSV twice, or a sequence was not reset | `TRUNCATE` and reload; `00_clear_all.sql` drops the sequences |
| `ORA-01861: literal does not match format string` | date format mismatch | the `.ctl` files already set `DATE 'YYYY-MM-DD'` per column |
| `ORA-02290: check constraint violated` | a status or gender value outside the allowed list | values are case-sensitive: `Completed`, not `complete` |
| `ORA-12899: value too large for column` | a value longer than the column | widen the column, or check the mapping |
| `ORA-00942: table or view does not exist` | a step was skipped, or you are the wrong user | check the order above |
| `ORA-02266: unique/primary keys referenced by enabled foreign keys` | `TRUNCATE` on a dimension | use `DELETE`, or `00_clear_all.sql` |
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
