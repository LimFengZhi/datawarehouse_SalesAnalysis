# Glow Beauty — Data Warehouse

**BAIT3003 Data Warehouse Technology** — a full Oracle star-schema warehouse built over a synthetic
Malaysian beauty-retail business: five branches selling skincare products and booking facial
services, seven years of trading (2019–2025), ~1.2 million source rows.

The project covers the whole pipeline: an operational database, SQL\*Loader ingestion, an initial
ETL load, and two subsequent (incremental) loads that exercise **Slowly Changing Dimensions
Type 2** with real price history.

---

## The star schema

**8 dimensions** — `date_dim`, `branch_dim`, `staff_dim`, `customer_dim`, `product_dim`,
`supplier_dim`, `service_dim`, `branch_utils_dim`

**5 fact tables**

| Fact | Grain | Rows (all 3 loads) |
|---|---|---|
| `order_fact` | one product line on an order | 800,092 |
| `reservation_fact` | one service line booked | 196,515 |
| `purchase_fact` | one restocking line | 20,163 |
| `salary_payment_fact` | one staff member per pay period | 7,113 |
| `branch_expense_fact` | one branch per utility per month | 2,724 |

Six of the eight dimensions are **SCD Type 2** — a changed attribute expires the old row and opens
a new version, so history never gets rewritten. Attributes that drift for non-business reasons
(`cus_age`, `st_age`, `serv_duration`) are **Type 1** inside those same dimensions: overwritten in
place, because a customer having a birthday is not a business event worth versioning.

Facts resolve their dimension keys **by effective date**, not by "whichever version is current":

```sql
JOIN product_dim p ON p.product_ID = ls.product_ID
                  AND ls.order_date BETWEEN p.effective_start_date
                                        AND p.effective_end_date
```

so a 2023 order always reports the price that was actually charged in 2023, regardless of how many
times the price has moved since or what order the scripts were run in.

---

## Repository layout

```
datawarehouseAnalysis\
├── operational_DB\                     THE SOURCE SYSTEM (OLTP)
│   ├── create_operational_db.sql           14 CREATE TABLEs
│   └── sqlloader_control_files\            14 .ctl + load_all.bat / .sh
│
├── sales_data\                         THE RAW CSVs
│   ├── data\      2019-2022   (supplied)
│   ├── data2\     2023-2024   + gen_data2.py + 99_price_increase_2023.sql
│   └── data3\     2025        + gen_data3.py + 99_price_change_2025.sql
│
├── dwh\                                THE WAREHOUSE SCHEMA
│   ├── create_dwh.sql                      13 tables: 8 dims + 5 facts
│   └── clear_dwh.sql                       empty it, keep the tables
│
├── ETL_Process\                        THE ETL
│   ├── initial_loading\                    first build, from data\
│   │   ├── init_data_dim\   date_dim + gen_holidays.py
│   │   ├── init_dimension\  01..07  the 7 source-fed dimensions
│   │   ├── init_fact\       01..05  the 5 fact tables
│   │   └── validate_initial_loading.sql
│   └── subsequent_loading\                 incremental, from data2\ / data3\
│       ├── sub_dimension\   01..08  NEW records only
│       ├── maintain_SCD2\   01..06  CHANGED records -> new versions
│       ├── sub_fact\        01..05  new rows + refresh changed ones
│       ├── execute_sub_procedure.sql   RUNS the data2 load (2023-24)
│       ├── execute_sub2.sql            RUNS the data3 load (2025)
│       └── validate_subsequent_loading.sql
│
├── analysis\                           reporting queries
├── drop_all.sql                        destroy every object in the schema
└── LOADING_GUIDE.md                    step-by-step build instructions
```

Each ETL script follows the same four-section shape:

| Section | Contents |
|---|---|
| 1 | staging **VIEW** — all cleansing and derivation, OLTP only, natural keys out |
| 2 | **SEQUENCE** for the surrogate key (or a note that the fact needs none) |
| 3 | **PROCEDURE** — resolves surrogate keys and loads |
| 4 | the run (initial) or a pointer to the execute/validate files (subsequent) |

The staging views never touch a dimension. That split means a view compiles before anything is
loaded, and the same view serves both the initial and the incremental load.

---

## Three loads, three roles

| Load | Source | What it proves |
|---|---|---|
| **Initial** | `sales_data\data\` (2019–2022) | full build from empty |
| **Subsequent 1** | `sales_data\data2\` (2023–2024) | new branch, staff, products, customers **+ 7 price rises** become SCD2 history |
| **Subsequent 2** | `sales_data\data3\` (2025) | new customers and suppliers **+ 8 more product and 6 service price changes** — two products now carry three versions each |

New records and changed records are handled by deliberately separate scripts:

- `sub_dimension\` — a natural key that does **not exist yet** → insert it
- `maintain_SCD2\` — a natural key that **exists and changed** → expire the old row, insert a new version

Run them in that order; reversed, a brand-new product would be "versioned" before it exists.

After all three loads `product_dim` holds **63 rows: 48 current + 15 expired**. That difference is
the whole point of Type 2 — `total − current` always equals the number of price changes ever made.

---

## Getting started

Full instructions are in **[LOADING_GUIDE.md](LOADING_GUIDE.md)**. The short version:

```
sqlplus dwh/yourpassword@XE
```

```sql
@operational_DB\create_operational_db.sql          -- 1. OLTP tables
```
```
cd operational_DB\sqlloader_control_files
load_all.bat dwh yourpassword XE                   -- 2. load the CSVs
```
```sql
@dwh\create_dwh.sql                                -- 3. warehouse tables
-- 4. date_dim, then gen_holidays.py, then the 7 dimension + 5 fact scripts
@ETL_Process\initial_loading\validate_initial_loading.sql
```

Then Part B of the guide adds `data2\` and `data3\` on top without wiping anything.

**Requirements:** Oracle XE 11.2 (identifiers are kept ≤ 30 characters for it), SQL\*Plus,
SQL\*Loader, and Python 3 for the holiday and data generators.

---

## Validation

Two scripts collect every check in one place, rather than scattering them through the load files:

- [ETL_Process/initial_loading/validate_initial_loading.sql](ETL_Process/initial_loading/validate_initial_loading.sql)
- [ETL_Process/subsequent_loading/validate_subsequent_loading.sql](ETL_Process/subsequent_loading/validate_subsequent_loading.sql)

They check row counts against source, orphaned keys, duplicate natural keys, which dimension lookup
dropped rows, measure arithmetic (`gross − discount + tax = total`), SCD2 integrity (exactly one
current row per key, no expired row still open, no overlapping version ranges), and the business
patterns the dataset was built to contain. Anything labelled **"must be 0"** that is not 0 names
the table to investigate.

Both loads are **idempotent** — run them a second time and every procedure reports 0 inserted,
0 expired, 0 updated.

---

## What is in the data

The dataset is synthetic but deliberately not flat, so there is something to analyse:

- **COVID-19, on the real Malaysian timeline.** April 2020 (MCO 1.0) and June–August 2021 (FMCO)
  contain **zero completed reservations** — salons were legally closed — while product sales
  continued at reduced volume via delivery. 2022 recovers and overshoots on revenge spending.
- **The Malaysian festive calendar** — Chinese New Year, Hari Raya, Deepavali and Christmas drive
  demand spikes; `date_dim` carries the real public-holiday flags generated by `gen_holidays.py`.
- **Payroll and overheads that react** — 20% then 15% pay cuts during lockdown, 13th-month and Raya
  bonuses, landlord rent rebates in 2020, then a steady 3%/year rise.
- **Growth** — a sixth branch (Ipoh) opens March 2023, and the customer base grows from 26,000 to
  35,500 by 2025.

Per-dataset detail: [data](sales_data/data/README_DATASET.md) ·
[data2](sales_data/data2/README_DATA2.md) · [data3](sales_data/data3/README_DATA3.md)
