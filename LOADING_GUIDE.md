# Loading Guide

End to end, from an empty schema to a seven-year, seventeen-branch warehouse.

Three parts:

- **Part A — first build.** The OLTP tables, the 2019–2023 CSVs in
  [sales_data5/data19_23/](sales_data5/data19_23/) (13 branches), and the whole warehouse.
  ~960,000 source rows.
- **Part B — adding data24.** The 2024 rows in [sales_data5/data24/](sales_data5/data24/)
  *without* wiping what Part A built. ~300,000 more rows, four new branches with their teams,
  and the 2024-01-01 price rise that becomes SCD Type 2 history.
- **Part C — adding data25.** The 2025 rows in [sales_data5/data25/](sales_data5/data25/):
  ~400,000 more rows, the HIM Essentials men's line (8 products) and its supplier, and the
  2025-01-01 product **and service** price changes.

Connect as your schema user for everything:

```
sqlplus dwh/yourpassword@XE
```


> **Other data trees.** The earlier revisions (`sales_data\`, `sales_data2\`, `sales_data3\` —
> 2018–2025, 13 branches) were moved to the gitignored `trash\` folder. They still load with the same
> control files, but their IDs start at 1 too, so none of them can be loaded into the same OLTP as
> `sales_data5\`, and their counts differ from every number below. The ETL date constants, the
> `execute_*` scripts, the validation counts and this guide are written for `sales_data5\`.
> **Space:** `sales_data5\` is ~1.3 M source rows (+30 % on rev 3); with the `dwh` schema in the XE
> `SYSTEM` tablespace that was already nearly full after rev 3, run `drop_all.sql` first and give the
> schema room (an autoextending tablespace) or you will hit `ORA-01653`.

---

## What you have

```
datawarehouse_SalesAnalysis\
├── operational_DB\                     THE SOURCE SYSTEM (OLTP)
│   ├── create_operational_db.sql           13 CREATE TABLEs
│   └── sqlloader_control_files\            13 .ctl + load_all.bat / .sh
│
├── sales_data5\                        THE RAW CSVs (revision 5: one generator, three load folders)
│   ├── gen_sales_data5.py                  regenerates all three folders (seeded)
│   ├── data19_23\   13 CSVs, 2019-2023    13 branches
│   ├── data24\      13 CSVs, 2024       + 99_price_increase_2024.sql   (+ 4 branches)
│   └── data25\      13 CSVs, 2025       + 99_price_change_2025.sql     (+ men's line)
│
├── dwh\                                THE WAREHOUSE SCHEMA
│   ├── create_dwh.sql                      12 tables: 7 dims + 5 facts
│   └── clear_dwh.sql                       empty it, keep the tables
│
├── ETL_Process\                        THE ETL
│   ├── initial_loading\
│   │   ├── init_data_dim\   date_dim + gen_holidays.py
│   │   ├── init_dimension\  the 6 source-fed dimensions
│   │   ├── init_fact\       the 5 fact tables
│   │   └── validate_initial_loading.sql     all Part A checks
│   └── subsequent_loading\
│       ├── sub_dimension\   NEW dimension records only     (create-only)
│       ├── maintain_SCD2\   CHANGED records -> versions    (create-only)
│       ├── sub_fact\        new + changed fact rows        (create-only)
│       ├── execute_sub_procedure.sql        RUNS the data24 load (2024)
│       ├── execute_sub2.sql                 RUNS the data25 load (2025)
│       └── validate_subsequent_loading.sql  all Part B / C checks
│
├── analysis\                           reporting queries
└── drop_all.sql                        destroy every object in the schema
```

The numbered `subsequent_loading` scripts only CREATE views and procedures — the `execute_*` files
run them. The `initial_loading` scripts create **and run** their own procedure.

Paths below are written in full from `c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\`.
If you keep the repo elsewhere, swap that prefix.

---

# PART A — First build (2019–2023)

## A1. Create the OLTP tables

```sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\operational_DB\create_operational_db.sql
SELECT COUNT(*) FROM user_tables;    -- expect 13
```

If you get `ORA-01950: no privileges on tablespace 'USERS'`, connect as SYSDBA and run
`GRANT UNLIMITED TABLESPACE TO dwh;`.

## A2. Load the 2019–2023 CSVs

```
cd c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\operational_DB\sqlloader_control_files
load_all.bat dwh yourpassword XE
```

With no 4th argument the script defaults to `..\..\sales_data5\data19_23`. It switches into that
folder so each control file finds its CSV, then loads all 13 tables in dependency order. Logs land
next to the script, **suffixed with the data folder** so a later run against `data24\` doesn't
overwrite them — check `branch_data19_23.log` first:

```
Table BRANCH:
  13 Rows successfully loaded.
  0 Rows not loaded due to data errors.
```

Expect 4–8 minutes, nearly all of it in `order_detail` (490,685 rows).

**Why the order matters.** `orders.cus_ID` is a foreign key to `customer.cus_ID`, checked on every
row. Load `orders` before `customer` and all 222,246 rows bounce with `ORA-02291`. Parents before
children — `load_all.bat` already does this.

Verify:

```sql
SELECT 'customer' t, COUNT(*) n FROM customer
UNION ALL SELECT 'orders',       COUNT(*) FROM orders
UNION ALL SELECT 'order_detail', COUNT(*) FROM order_detail;
-- expect 26182 / 222246 / 490685
```

## A3. Create the warehouse tables

```sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\dwh\create_dwh.sql
-- expect 12 tables: 7 dimensions + 5 facts
```

## A4. Date dimension, then holidays

```sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\init_data_dim\initial_load_date_dim.sql
-- expect 1827 rows (1,826 days 2019-01-01..2023-12-31 + the Unknown member)
```

Holidays are **not** automatic — every day loads with `holiday_ind = 'N'`:

```
cd c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\init_data_dim
python gen_holidays.py 2019 2023 > holiday_update.sql
```
```sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\init_data_dim\holiday_update.sql
SELECT COUNT(*) FROM date_dim WHERE holiday_ind = 'Y';   -- must be > 0
```

## A5. Dimensions

Run all six, in order — each one creates its staging view, sequence and procedure, then runs it:

```sql
cd c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\init_dimension
```
```sql
@01_init_branch_dim.sql
@02_init_supplier_dim.sql
@03_init_service_dim.sql
@04_init_product_dim.sql
@05_init_staff_dim.sql
@06_init_customer_dim.sql
```

Expect 13 / 7 / 18 / 48 / 244 / 26,182. (There is no utilities dimension: `branch_utils_fact`
carries `util_name` on the row.)

Every SCD2 dimension row starts its first version on `DATE '2018-01-01'` — before the start of
recorded history (2019-01-01). Facts resolve their keys by date, so a 2019 order line finds a
version that already exists.

## A6. Facts

```sql
cd c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\init_fact
```
```sql
@01_init_order_fact.sql
@02_init_reservation_fact.sql
@03_init_purchase_fact.sql
@04_init_salary_payment_fact.sql
@05_init_branch_utils_fact.sql
```

Expect 480,753 / 97,740 / 33,508 / 12,103 / 4,680.

`order_fact` is one row per (order, product): `order_detail` has 490,685 lines, but 9,932 of them
repeat a product that is already on the same order, and the staging view sums those into one row
(the procedure prints both numbers). `reservation_fact` is one row per (reservation, service,
therapist) — in this data that is always one detail line, so its count equals the source.

`order_fact` is the slow one — 480k rows joined to five dimensions. Give it several minutes.

## A7. Validate everything

One script runs every Part A check — row counts, orphans, duplicate keys, failed dimension
lookups, measure arithmetic and the COVID/revenue patterns:

```sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\validate_initial_loading.sql
```

Every check labelled "must be 0" that comes back non-zero tells you exactly which table and which
lookup to investigate. The business-pattern section should show Petaling Jaya as the top branch,
zero completed reservations between 18 Mar–3 May 2020 and Jun–Aug 2021, revenue that dips in
2020–2021 and jumps in 2022 (the e-commerce launch).

---

# PART B — Adding data24 (2024)

This appends. Nothing from Part A is deleted.

**Do the steps in this order.** Each one depends on the one before, and getting them out of order
fails *silently* rather than loudly — see the note at the end of this part.

## B1. Load the 2024 CSVs

```
cd c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\operational_DB\sqlloader_control_files
load_all.bat dwh yourpassword XE "c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\sales_data5\data24"
```

The 4th argument points the same control files at the other folder. Every file in `data24\` is
named exactly like its counterpart in `data19_23\` with identical headers, and every `.ctl` uses
`APPEND`, so the rows are added to the existing tables. IDs continue from where `data19_23\`
stopped — no collisions.

`supplier_data24.log`, `product_data24.log` and `service_data24.log` will show **0 rows**. That is
correct: those files are header-only because data24 adds no new suppliers, products or services
(it adds 4 branches, 69 staff and 6,314 customers).

**Nothing to clean before a re-run.** SQL\*Loader overwrites its log each time — it never appends.
And `load_all.bat` deletes any old `.bad` before each table loads, so a `.bad` file present
afterwards always means *this* run rejected rows. No `.bad` file means nothing was rejected.

Verify the totals are now `data19_23` + `data24`:

```sql
SELECT 'branch'   t, COUNT(*) n, 17     expected FROM branch
UNION ALL SELECT 'staff',        COUNT(*), 313    FROM staff
UNION ALL SELECT 'product',      COUNT(*), 48     FROM product
UNION ALL SELECT 'service',      COUNT(*), 18     FROM service
UNION ALL SELECT 'customer',     COUNT(*), 32496  FROM customer
UNION ALL SELECT 'orders',       COUNT(*), 296460 FROM orders
UNION ALL SELECT 'order_detail', COUNT(*), 655056 FROM order_detail
UNION ALL SELECT 'reservation',  COUNT(*), 98369  FROM reservation
UNION ALL SELECT 'reservation_detail', COUNT(*), 129874 FROM reservation_detail
UNION ALL SELECT 'purchase',       COUNT(*), 42820 FROM purchase
UNION ALL SELECT 'salary_payment', COUNT(*), 15474 FROM salary_payment
UNION ALL SELECT 'branch_utils',   COUNT(*), 5904  FROM branch_utils;
```

## B2. Apply the 2024 price rise

```sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\sales_data5\data24\99_price_increase_2024.sql
```

Eight top sellers go up, effective 2024-01-01. The 2024 order lines in data24 already carry the
new prices (the 2019–2023 lines loaded in Part A carry the old ones), so this brings the OLTP
`product` table into step with them.

Must run **before** B4, which turns the change into dimension history.

## B3. Create the 18 procedures (first time only)

The `subsequent_loading` numbered scripts are **create-only** — each defines one procedure and
executes nothing. Run all 18 once, in any order:

```sql
cd c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading
```
```sql
@sub_dimension\01_sub_date_dim.sql
@sub_dimension\02_sub_supplier_dim.sql
@sub_dimension\03_sub_product_dim.sql
@sub_dimension\04_sub_branch_dim.sql
@sub_dimension\05_sub_service_dim.sql
@sub_dimension\06_sub_staff_dim.sql
@sub_dimension\07_sub_customer_dim.sql
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
@sub_fact\05_sub_branch_utils_fact.sql
```

Already ran them for an earlier load? Skip this step — the procedures are still there.

## B4. Run the whole load

```sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading\execute_sub_procedure.sql
```

One file does everything, in the only safe order:

- **STEP 0** — checks all 18 procedures exist and are VALID before calling any of them
- **STEP 1** — extends the calendar to 2024, then inserts the NEW records: the 4 branches
  (Seremban, Kuantan, Subang Jaya, Bukit Jalil), 69 staff (their teams plus the 2024 growth
  hires) and 6,314 customers; suppliers / products / services report 0
- **STEP 2** — turns the price rise into SCD2 history:
  `maintain_product_dim_scd2(DATE '2024-01-01')` expires the 8 old price versions on 2023-12-31
  and opens the new ones on 2024-01-01. `product_dim` now holds 56 rows — 48 current + 8 expired
- **STEP 3** — the facts, each backfilled with `(DATE '2024-01-01')`. The window opens one day
  early by design (`src_date >= p_load_date - 1`) and has no upper bound, so one call loads all of
  data24. The `NOT EXISTS` anti-join skips anything already loaded. The 2019–2023 rows keep the
  expired (old-price) product versions by date, the 2024 rows take the new ones

**Why the calendar comes first.** Every fact staging view uses `INNER JOIN` to resolve its
dimension keys. An unresolved key does not raise an error — the row is silently **dropped**. If
`date_dim` stopped at 2023-12-31, all 161,093 new order rows would vanish with no warning.

**Idempotent:** run the file twice and the second pass reports 0 inserted, 0 expired, 0 updated.

## B5. Holidays for the new years

The 2024 days arrive with `holiday_ind = 'N'`, so regenerate over the wider range:

```
cd c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\init_data_dim
python gen_holidays.py 2019 2024 > holiday_update.sql
```
```sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\init_data_dim\holiday_update.sql

SELECT cal_year, COUNT(*) AS holidays FROM date_dim
WHERE holiday_ind = 'Y' GROUP BY cal_year ORDER BY cal_year;
-- every year 2019..2024 present, none zero
```

The generated file resets **only the years it covers**, so a partial regeneration
(`gen_holidays.py 2024 2024`) leaves 2019–2023 untouched.

## B6. Validate everything

```sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading\validate_subsequent_loading.sql
```

Covers calendar continuity, dimension coverage, SCD2 integrity (one current row per key, no
dangling 9999-12-31 end dates, no orphaned facts), version history, fact-vs-source counts and the
business patterns. Every "must be 0" that is not 0 names the table to investigate.

---

# PART C — Adding data25 (2025)

Same pattern as Part B, different files. The procedures from B3 are reused as-is.

```
cd c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\operational_DB\sqlloader_control_files
load_all.bat dwh yourpassword XE "c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\sales_data5\data25"
```
```sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\sales_data5\data25\99_price_change_2025.sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading\execute_sub2.sql
```
```
cd c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\init_data_dim
python gen_holidays.py 2019 2025 > holiday_update.sql
```
```sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\init_data_dim\holiday_update.sql
@c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading\validate_subsequent_loading.sql
```

`branch` and `service` are header-only in `data25\` (0 rows, correct). `execute_sub2.sql` extends the
calendar to 2025, adds 1 supplier (HIM Care Labs), 8 products (the HIM Essentials men's line 49–54 and
two face masks), 6 staff and 6,805 customers, dates **both** `maintain_product_dim_scd2` and
`maintain_service_dim_scd2` at `2025-01-01`, and backfills the facts from `DATE '2025-01-01'`.

End state, all three loads:

| | rows |
|---|---:|
| `branch` / `supplier` / `staff` / `customer` | 17 / 8 / 319 / 39,301 |
| `product_dim` | **72 = 56 current + 16 expired** (products 4 and 16 carry three versions) |
| `service_dim` | 24 = 18 current + 6 expired |
| `date_dim` | 2,558 = 2,557 days 2019–2025 + Unknown |
| `order_fact` / `reservation_fact` | 855,935 / 167,087 |
| `purchase_fact` / `salary_payment_fact` / `branch_utils_fact` | 54,020 / 18,934 / 7,128 |

---

## Order of everything, at a glance

```
PART A                                  PART B                                    PART C
A1  create_operational_db.sql           B1  load_all.bat ... "...\data24"         C1  load_all.bat ... "...\data25"
A2  load_all.bat  (data19_23)           B2  99_price_increase_2024.sql            C2  99_price_change_2025.sql
A3  dwh\create_dwh.sql                  B3  create the 18 procedures (once)       C3  execute_sub2.sql
A4  date_dim + holidays 2019-2023       B4  execute_sub_procedure.sql             C4  regenerate holidays to 2025
A5  dimensions                          B5  regenerate holidays to 2024           C5  validate_subsequent_loading.sql
A6  facts                               B6  validate_subsequent_loading.sql
A7  validate_initial_loading.sql
```

---

## Regenerating the CSVs

```
cd c:\Users\laoli\OneDrive\Desktop\datawarehouse_SalesAnalysis\sales_data5
python gen_sales_data5.py            # ~2 minutes, rewrites all three folders, then self-verifies
python gen_sales_data5.py --verify   # only re-check the CSVs already on disk
```

The generator is seeded, so the output is identical every run. It ends with an integrity pass over
the files it wrote (FKs, ID continuity across folders, folder routing, no order before registration,
no therapist double-booked, no booking while salons were closed, price eras, tax, Ipoh's supplier
rule, launch dates) and prints the counts quoted above plus a per-branch P&L and the pattern checks. If you change anything in it, re-run it and then update the expected counts in the
two `validate_*.sql` files, the two `execute_*` files, `dwh\clear_dwh.sql` and the READMEs
(remember `order_fact` counts distinct (order, product) pairs, not `order_detail` lines).

---

## Three levels of reset

| Script | What it does | When |
|---|---|---|
| `TRUNCATE TABLE order_fact;` | one fact table | a single load went wrong |
| [dwh/clear_dwh.sql](dwh/clear_dwh.sql) | empties all dims + facts, drops the 7 sequences, **keeps the tables and the OLTP** | re-run the warehouse build without touching SQL\*Loader |
| [drop_all.sql](drop_all.sql) | destroys every object in the schema, OLTP included | the DDL changed, or you are switching to another data tree (an old revision from `trash\`) |

`clear_dwh.sql` is the one you want almost every time. `drop_all.sql` costs you another full
SQL\*Loader run over ~1.7 million rows.

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
| `ORA-01653 / ORA-01654: unable to extend table/index ... in tablespace SYSTEM` | the tablespace holding the warehouse is full | the dataset must be smaller for that tablespace, or the schema needs to live in a larger/autoextending tablespace |
| `ORA-02291: parent key not found` | loaded a child before its parent | follow the load order |
| `ORA-00001: unique constraint violated` | loaded the same CSV twice, loaded an old revision on top of `sales_data5\`, or a sequence was not reset | `TRUNCATE` and reload; `clear_dwh.sql` drops the sequences; `drop_all.sql` to switch trees |
| `ORA-01861: literal does not match format string` | date format mismatch | the `.ctl` files already set `DATE 'YYYY-MM-DD'` per column |
| `ORA-02290: check constraint violated` | a status or gender value outside the allowed list | values are case-sensitive: `Completed`, not `complete` |
| `ORA-12899: value too large for column` | a value longer than the column | widen the column, or check the mapping |
| `ORA-00942: table or view does not exist` | a step was skipped, or you are the wrong user | check the order above |
| `ORA-02266: unique/primary keys referenced by enabled foreign keys` | `TRUNCATE` on a dimension | use `DELETE`, or `clear_dwh.sql` |
| `PLS-00905: object ... is invalid` | the procedure compiled with errors | `SELECT line, text FROM user_errors WHERE name = '<PROC>' ORDER BY sequence;` — that shows the real message |
| **loads 0 rows, no error** | a dimension is empty, or `date_dim` does not reach the transaction dates, or the dimension's `effective_start_date` is later than the transactions (must be 2018-01-01) | run the dry-run query below |
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
JOIN product_dim  p ON p.product_ID = ls.product_ID
   AND ls.order_date BETWEEN p.effective_start_date AND p.effective_end_date
JOIN customer_dim c ON c.cus_ID     = ls.cus_ID
   AND ls.order_date BETWEEN c.effective_start_date AND c.effective_end_date
JOIN staff_dim    s ON s.st_ID      = ls.st_ID
   AND ls.order_date BETWEEN s.effective_start_date AND s.effective_end_date
JOIN branch_dim   b ON b.br_ID      = ls.br_ID
   AND ls.order_date BETWEEN b.effective_start_date AND b.effective_end_date;
```

Then drop one join at a time until the count jumps — that names the culprit. Or check the usual
suspects directly:

```sql
-- does date_dim cover the transactions?
SELECT (SELECT MIN(cal_date) FROM date_dim WHERE date_key <> 0) AS dim_first_day,
       (SELECT MAX(cal_date) FROM date_dim WHERE date_key <> 0) AS dim_last_day,
       (SELECT MIN(order_date) FROM orders)                     AS first_order,
       (SELECT MAX(order_date) FROM orders)                     AS last_order
FROM dual;
-- last_order after dim_last_day -> EXEC load_date_dim_incremental(2025);
-- first_order before dim_first_day -> the initial date_dim script must start 2019-01-01

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
