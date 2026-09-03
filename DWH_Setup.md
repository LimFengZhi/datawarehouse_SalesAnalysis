# DWH Setup

Build the whole Glow Beauty warehouse from an empty schema: OLTP → CSVs → star schema → initial
load → two subsequent loads. Fourteen steps, in this order — **each one depends on the one before,
and getting them out of order fails silently rather than loudly.**

| | |
|---|---|
| **Dataset** | `sales_data5\` — 2019–2025, 17 branches, ~1.7 M source rows |
| **Requirements** | Oracle XE 11.2, SQL\*Plus, SQL\*Loader, Python 3 (holidays only) |
| **Time** | ~2 minutes for the whole build |
| **Connect as** | `sqlplus dwh/abcxyz@XE` (swap in your own password) |

> **Paths** below assume the repo sits at `C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis`.
> If yours is elsewhere, swap that prefix everywhere.
>
> **Tablespace** — give the `dwh` user room before you start, or the load dies with `ORA-01653`
> half way through. As SYSDBA:
> ```sql
> ALTER USER dwh DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
> ```
> (XE's `SYSTEM` tablespace is capped at 600 MB; `USERS` autoextends to 11 GB.)

---

## Step 0 — Wipe the schema *(rebuilds only)*

Skip this on a fresh user. On a schema that already holds a previous build it is the only clean
start — it drops **every** object, OLTP included.

```sql
@C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\drop_all.sql
```
✅ `SELECT COUNT(*) FROM user_tables;` → **0**

---

# PART A — First build (2019–2023)

## Step 1 — Create the OLTP tables

```sql
@C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\operational_DB\create_operational_db.sql
```
✅ **13 tables** (the source system: branch, staff, customer, product, service, supplier,
branch_utils, salary_payment, orders, order_detail, reservation, reservation_detail, purchase)

## Step 2 — Load the 2019–2023 CSVs

```
cd C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\operational_DB\sqlloader_control_files
.\load_all.bat dwh abcxyz XE "C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\sales_data5\data19_23"
```

`load_all.bat` switches into the CSV folder, then loads all 13 tables **parents before children**
(`orders` before `customer` would bounce every row with `ORA-02291`). Logs land next to the script
as `<table>_data19_23.log`; a `.bad` file appearing means *this* run rejected rows.

✅ ~1 minute. Check the log tail:

```sql
SELECT 'customer' t, COUNT(*) n FROM customer
UNION ALL SELECT 'orders',       COUNT(*) FROM orders
UNION ALL SELECT 'order_detail', COUNT(*) FROM order_detail;
-- expect 25866 / 222296 / 491657
```

## Step 3 — Create the warehouse

```sql
@C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\dwh\create_dwh.sql
```
✅ **12 tables** = 7 dimensions + 5 facts

## Step 4 — Initial loading: date → dimensions → facts

Each script creates its staging view, sequence and procedure, **and runs it**. In this order:

```sql
cd C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading
```
```sql
-- 4a. the calendar (everything else resolves its date_key against this)
@init_data_dim\initial_load_date_dim.sql

-- 4b. the six source-fed dimensions
@init_dimension\01_init_branch_dim.sql
@init_dimension\02_init_supplier_dim.sql
@init_dimension\03_init_service_dim.sql
@init_dimension\04_init_product_dim.sql
@init_dimension\05_init_staff_dim.sql
@init_dimension\06_init_customer_dim.sql

-- 4c. the five facts
@init_fact\01_init_order_fact.sql
@init_fact\02_init_reservation_fact.sql
@init_fact\03_init_purchase_fact.sql
@init_fact\04_init_salary_payment_fact.sql
@init_fact\05_init_branch_utils_fact.sql
```

✅ Expected row counts:

| | rows |
|---|---:|
| `date_dim` | **1,827** (1,826 days 2019-01-01..2023-12-31 + the Unknown member) |
| dimensions | **13 / 7 / 18 / 48 / 244 / 25,866** (branch, supplier, service, product, staff, customer) |
| facts | **481,611 / 97,596 / 33,430 / 12,103 / 4,680** |

`order_fact` is one row per **(order, product)**: `order_detail` has 491,657 lines, but 9,932 repeat
a product already on the same order and the staging view sums those into one row. It is the slow
one — give it a few minutes.

There is no utilities dimension: `branch_utils_fact` carries `util_name` on the row.

## Step 5 — Validate the initial load

```sql
@C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\validate_initial_loading.sql
```

✅ Every check labelled **"must be 0"** comes back 0, and each fact row count equals its source.
The business-pattern section should show Petaling Jaya on top, **zero** completed reservations
between 18 Mar–3 May 2020 and Jun–Aug 2021 (salons legally closed), and revenue dipping in 2020–21.

*(Holiday counts read 0 until Step 14 — see the note there.)*

---

# PART B — Adding data24 (2024)

This **appends**. Nothing from Part A is deleted.

## Step 6 — Create the 16 subsequent procedures *(first time only)*

These scripts are **create-only** — each defines one procedure and executes nothing. The `EXEC`
calls all live in the two `exec_sub_proc*` files.

```sql
cd C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading
```
```sql
@sub_dimension\01_sub_date_dim.sql          @maintain_SCD2\01_maintain_product_dim.sql
@sub_dimension\02_sub_supplier_dim.sql      @maintain_SCD2\02_maintain_service_dim.sql
@sub_dimension\03_sub_product_dim.sql       @maintain_SCD2\03_maintain_staff_dim.sql
@sub_dimension\04_sub_branch_dim.sql        @maintain_SCD2\04_maintain_customer_dim.sql
@sub_dimension\05_sub_service_dim.sql
@sub_dimension\06_sub_staff_dim.sql         @sub_fact\01_sub_order_fact.sql
@sub_dimension\07_sub_customer_dim.sql      @sub_fact\02_sub_reservation_fact.sql
                                            @sub_fact\03_sub_purchase_fact.sql
                                            @sub_fact\04_sub_salary_payment_fact.sql
                                            @sub_fact\05_sub_branch_utils_fact.sql
```

*(Run them one per line — the two columns above are only to keep this page short.)*

The three layers split by **attribute, not by operation**: `sub_dimension` inserts new natural keys
*and* overwrites the untracked attributes on existing ones (name, email, category — Type 1, in
place), `maintain_SCD2` only **versions** the tracked ones (price · position+status ·
tier+city+state — Type 2), `sub_fact` inserts new fact rows and refreshes changed ones.
Only four dimensions are SCD2: `branch_dim` and `supplier_dim` keep no history, so they have no
maintain script — their `sub_dimension` procedure is their complete sync.

## Step 7 — Validate the procedures compiled

```sql
SELECT object_name, status FROM user_objects
WHERE object_type = 'PROCEDURE' AND status <> 'VALID' ORDER BY 1;
```
✅ **No rows.** If one is INVALID, `PLS-00905` will hide the real message later — get it now with
`SELECT line, text FROM user_errors WHERE name = '<PROC>' ORDER BY sequence;`

*(Step 10 re-checks this: its STEP 0 counts all 16 and refuses to run if any is missing or invalid.)*

## Step 8 — Load the 2024 CSVs

```
cd C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\operational_DB\sqlloader_control_files
.\load_all.bat dwh abcxyz XE "C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\sales_data5\data24"
```

Same control files, different folder — every `.ctl` uses `APPEND`, so rows are added and IDs
continue where `data19_23` stopped. `supplier`, `product` and `service` log **0 rows**: those files
are header-only because 2024 adds no new ones (it adds 4 branches, 69 staff, 6,485 customers).

✅ `branch` 17 · `staff` 313 · `customer` 32,496 · `orders` 296,460 · `order_detail` 655,056

## Step 9 — Apply the 2024 price rise

```sql
@C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\sales_data5\data24\99_price_increase_2024.sql
```

Eight top sellers go up, effective 2024-01-01. The 2024 order lines already carry the new prices,
so this brings the OLTP `product` table into step with them. **Must run before Step 10**, which
turns the change into dimension history — `maintain_SCD2` compares the dimension against the OLTP,
so the OLTP has to carry the new prices already or there is nothing to detect.

## Step 10 — Run the data24 load

```sql
@C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading\exec_sub_proc24.sql
```

One file, in the only safe order: **STEP 0** checks all 16 procedures · **STEP 1** extends the
calendar through `DATE '2024-12-31'` then inserts new records · **STEP 2**
`maintain_product_dim_scd2(DATE '2024-01-01')` — the SCD2 effective date is a business date,
because *when* a price changed is not in the data · **STEP 3** the five facts — each finds its own
START (the newest date already loaded into itself); the argument is only the window END
(`p_end_date`, default SYSDATE), capped at `DATE '2024-12-31'` so this run loads data24 only.

✅ 366 new days · 4 branches · 69 staff · 6,485 customers · **8 expired / 8 new** product versions ·
facts now **642,619 / 129,736 / 42,734 / 15,474 / 5,904**

**Why the calendar comes first:** every fact staging view uses `INNER JOIN`. An unresolved key does
not raise an error — the row is silently **dropped**. If `date_dim` stopped at 2023-12-31, all
161,093 new order rows would vanish with no warning.

**Idempotent:** run it twice, the second pass reports 0 inserted / 0 expired / 0 updated.

---

# PART C — Adding data25 (2025)

## Step 11 — Load the 2025 CSVs

```
cd C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\operational_DB\sqlloader_control_files
.\load_all.bat dwh abcxyz XE "C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\sales_data5\data25"
```
✅ `supplier` 8 · `product` 56 · `staff` 319 · `customer` 39,175 (`branch` and `service` are
header-only here)

## Step 12 — Apply the 2025 price changes

```sql
@C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\sales_data5\data25\99_price_change_2025.sql
```

Eight products **and — for the first time — six services**. Products 4 and 16 rise for the *second*
time, so they end up with three versions each.

## Step 13 — Run the data25 load

```sql
@C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading\exec_sub_proc25.sql
```

✅ 365 new days · 1 supplier (HIM Care Labs) · 8 products (the men's line) · 6 staff · 6,824
customers · **8+8 product and 6+6 service versions**

**End state, all three loads:**

| | rows |
|---|---:|
| `branch_dim` / `supplier_dim` / `staff_dim` / `customer_dim` | 17 / 8 / 319 / 39,175 |
| `product_dim` | **72 = 56 current + 16 expired** (products 4 and 16 carry three versions) |
| `service_dim` | 24 = 18 current + 6 expired |
| `date_dim` | 2,558 = 2,557 days 2019–2025 + Unknown |
| `order_fact` / `reservation_fact` | 857,664 / 166,658 |
| `purchase_fact` / `salary_payment_fact` / `branch_utils_fact` | 53,933 / 18,934 / 7,128 |

Then validate again:

```sql
@C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\ETL_Process\subsequent_loading\validate_subsequent_loading.sql
```
✅ Calendar continuity, dimension coverage, SCD2 integrity for the four versioned dimensions (one
current row per key, no expired row still open, no overlapping ranges) plus exactly-one-row-per-key
for `branch_dim` / `supplier_dim`, fact-vs-source counts, business patterns — all "must be 0"
checks at 0.

---

# Step 14 — Holidays (Python)

`date_dim` loads every day with `holiday_ind = 'N'`; the real Malaysian public holidays come from
the Python `holidays` package. One run covering **2019–2026** flags every year in one go.

```
python -m venv .venv
.venv\Scripts\activate
pip install holidays
```
```
cd C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\init_data_dim
python gen_holidays.py 2019 2026 > holiday_update.sql
```
```sql
@C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\ETL_Process\initial_loading\init_data_dim\holiday_update.sql

SELECT cal_year, COUNT(*) AS holidays FROM date_dim
WHERE holiday_ind = 'Y' GROUP BY cal_year ORDER BY cal_year;
-- every year 2019..2025 present, none zero
```

✅ 108 holiday dates, 14 distinct holidays.

> Run it here (once, at the end) **or** right after Step 4a and again after each calendar
> extension — the generated file resets only the years it covers. Doing it at the end means the
> "holidays" column in the Step 5 validation reads 0 until now.
>
> Never hand-edit `holiday_update.sql`; regenerate it.

---

## The whole thing, copy-paste

```
-- 0.  @drop_all.sql                                   (rebuilds only)
-- 1.  @operational_DB\create_operational_db.sql
-- 2.  cd operational_DB\sqlloader_control_files
--     .\load_all.bat dwh abcxyz XE "...\sales_data5\data19_23"
-- 3.  @dwh\create_dwh.sql
-- 4.  @ETL_Process\initial_loading\init_data_dim\initial_load_date_dim.sql
--     @ETL_Process\initial_loading\init_dimension\01..06
--     @ETL_Process\initial_loading\init_fact\01..05
-- 5.  @ETL_Process\initial_loading\validate_initial_loading.sql
-- 6.  @ETL_Process\subsequent_loading\sub_dimension\01..07
--     @ETL_Process\subsequent_loading\maintain_SCD2\01..04
--     @ETL_Process\subsequent_loading\sub_fact\01..05          (create-only)
-- 7.  check user_objects: no INVALID procedure
-- 8.  .\load_all.bat dwh abcxyz XE "...\sales_data5\data24"
-- 9.  @sales_data5\data24\99_price_increase_2024.sql
-- 10. @ETL_Process\subsequent_loading\exec_sub_proc24.sql
-- 11. .\load_all.bat dwh abcxyz XE "...\sales_data5\data25"
-- 12. @sales_data5\data25\99_price_change_2025.sql
-- 13. @ETL_Process\subsequent_loading\exec_sub_proc25.sql
--     @ETL_Process\subsequent_loading\validate_subsequent_loading.sql
-- 14. python gen_holidays.py 2019 2026 > holiday_update.sql
--     @ETL_Process\initial_loading\init_data_dim\holiday_update.sql
```

---

## Three levels of reset

| Script | What it does | When |
|---|---|---|
| `TRUNCATE TABLE order_fact;` | one fact table | a single load went wrong |
| [dwh/clear_dwh.sql](dwh/clear_dwh.sql) | empties all dims + facts, drops the 7 sequences, **keeps the tables and the OLTP** | re-run the warehouse build without touching SQL\*Loader |
| [drop_all.sql](drop_all.sql) | destroys every object, OLTP included | the DDL changed, or you are switching data trees |

`clear_dwh.sql` is the one you want almost every time; `drop_all.sql` costs another full
SQL\*Loader run over ~1.7 million rows.

**Dimensions need `DELETE`, not `TRUNCATE`** — Oracle blocks `TRUNCATE` on a parent table while an
enabled foreign key references it, even when the child is empty (`ORA-02266`). Facts have no
children, so `TRUNCATE` works there and is much faster.

---

## When something goes wrong

| Error | Cause | Fix |
|---|---|---|
| `SQL*Loader-500 / 553: file not found` | ran `sqlldr` from the wrong folder — `INFILE` is relative to your current directory | use `load_all.bat`, which handles it |
| `ORA-01950: no privileges on tablespace` | no quota | `ALTER USER dwh QUOTA UNLIMITED ON users;` as SYSDBA |
| `ORA-01653 / ORA-01654: unable to extend` | the tablespace is full | move the schema to `USERS` (autoextends) — see the note at the top |
| `ORA-02291: parent key not found` | loaded a child before its parent | follow the load order; `load_all.bat` already does |
| `ORA-00001: unique constraint violated` | the same CSV loaded twice, or an older revision loaded on top | `TRUNCATE` and reload; `drop_all.sql` to switch trees |
| `ORA-02290: check constraint violated` | a status/gender outside the allowed list | values are case-sensitive: `Completed`, not `complete` |
| `ORA-02266: unique/primary keys referenced` | `TRUNCATE` on a dimension | use `DELETE`, or `clear_dwh.sql` |
| `PLS-00905: object is invalid` | the procedure compiled with errors | `SELECT line, text FROM user_errors WHERE name = '<PROC>' ORDER BY sequence;` |
| `ORA-00903: invalid table name` on `ORDER` | `ORDER` is reserved in Oracle | the table is named **ORDERS** |
| **loads 0 rows, no error** | a dimension is empty, or `date_dim` does not reach the transaction dates | run the dry-run below |

A silent 0-row load is the expensive one. Run the exact join the procedure uses — if it returns 0,
a dimension is the problem; drop one join at a time until the count jumps:

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
JOIN branch_dim   b ON b.br_ID      = ls.br_ID;   -- branch_dim is not SCD2
```

```sql
-- does date_dim cover the transactions?
SELECT (SELECT MIN(cal_date) FROM date_dim WHERE date_key <> 0) AS dim_first_day,
       (SELECT MAX(cal_date) FROM date_dim WHERE date_key <> 0) AS dim_last_day,
       (SELECT MIN(order_date) FROM orders)                     AS first_order,
       (SELECT MAX(order_date) FROM orders)                     AS last_order
FROM dual;
-- last_order after dim_last_day  -> EXEC load_date_dim_incremental(DATE '<year>-12-31');
-- first_order before dim_first_day -> the initial date_dim script must start 2019-01-01
```

---

## Regenerating the CSVs

```
cd C:\Users\ASUS\Desktop\datawarehouse_SalesAnalysis\sales_data5
python gen_sales_data5.py            # ~2 min, rewrites all three folders, then self-verifies
python gen_sales_data5.py --verify   # only re-check the CSVs already on disk
```

The generator is seeded, so the output is identical every run. It ends with an integrity pass over
the files it wrote (FKs, ID continuity, folder routing, price eras, tax, therapist schedules,
closed-salon days, the Ipoh supplier rule) and prints the counts, a per-branch P&L and the pattern
checks. **If you change anything in it, every count above moves** — re-run it and update the two
`validate_*.sql` files, the two `exec_sub_proc*` files, `dwh\clear_dwh.sql`, this file and the
READMEs. See [sales_data5/README.md](sales_data5/README.md) for the full data story.
