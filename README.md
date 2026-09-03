# Glow Beauty — Data Warehouse

**BAIT3003 Data Warehouse Technology** — a full Oracle star-schema warehouse built over a synthetic
Malaysian beauty-retail business: seventeen branches across Selangor, the Federal Territory of Kuala Lumpur, Johor, Penang,
Melaka, Perak, Negeri Sembilan and Pahang selling skincare products and booking facial services,
seven years of trading (2019–2025), ~1.7 million source rows.

The project covers the whole pipeline: an operational database, SQL\*Loader ingestion, an initial
ETL load, and two subsequent (incremental) loads that exercise **Slowly Changing Dimensions
Type 2** with real price history.

---

## The star schema

**7 dimensions** — `date_dim`, `branch_dim`, `staff_dim`, `customer_dim`, `product_dim`,
`supplier_dim`, `service_dim`

**5 fact tables**

| Fact | Grain | Rows (all 3 loads) |
|---|---|---|
| `order_fact` | one product per order (duplicate product lines of an order are summed) | 857,664 |
| `reservation_fact` | one service per therapist per reservation | 166,658 |
| `purchase_fact` | one restocking line | 53,933 |
| `salary_payment_fact` | one staff member per pay period | 18,934 |
| `branch_utils_fact` | one branch per utility per month (`util_name` carried on the row) | 7,128 |

**Four** of the seven dimensions are **SCD Type 2** — `product_dim`, `service_dim`, `staff_dim` and
`customer_dim`. A change to a *tracked* attribute expires the old row and opens a new version, so
history never gets rewritten:

| Dimension | Tracked (Type 2 — versioned) | Type 1 — overwritten in place |
|---|---|---|
| `product_dim` | `product_unit_price` | name, category |
| `service_dim` | `serv_price` | name, category |
| `staff_dim` | `st_position`, `st_status` | name, email |
| `customer_dim` | `cus_loyalty_tier`, `cus_city`, `cus_state` | name, email, gender, `cus_age_group` |

Only what genuinely rewrites history is versioned: a price change revalues past orders, a promotion
changes who was senior in 2021, a house move changes which city a past purchase belongs to. A
corrected spelling does not — so it is overwritten on **every version** of the key, and the natural
key still rolls up as one line. `cus_age_group` (derived from the date of birth — the OLTP keeps
no age column) is Type 1 for the same reason, refreshed on the current row only: having a birthday
is not a business event worth versioning.

`branch_dim`, `supplier_dim` and `date_dim` keep **no history at all** — one row per key, no
effective dates, no current flag. A branch or a supplier is a static reference: the facts join it
on the natural key alone.

The schema follows the two ERDs of the project: `staff` has a single job-title column
(`st_position`), `order_detail` carries no unit price (the price is the `product_dim` version in
force on the order date — which is exactly what makes the SCD2 history matter), `reservation` has
both `booking_date` (when it was booked) and `reservation_date` (the appointment day, which is what
`reservation_fact.date_key` points at), utilities have no dimension of their own (`branch_utils_fact`
carries `util_name` on the row), and every fact's primary key is the composite of its dimension keys
plus the degenerate OLTP ID. `order_fact` / `reservation_fact` carry no order-line ID: their grain is
one row per (order, product) / (reservation, service, therapist), so the staging views sum the OLTP
lines that share a product inside one order (about 2 % of lines) and the incremental guards key on
`(order_ID, product_key)` / `(res_ID, service_key, staff_key)`. Every warehouse column outside `date_dim`
is `NOT NULL`; there are no UNIQUE constraints (the composite PKs cover the grain).

Facts resolve their **SCD2** dimension keys **by effective date**, not by "whichever version is
current":

```sql
JOIN product_dim p ON p.product_ID = ls.product_ID
                  AND ls.order_date BETWEEN p.effective_start_date
                                        AND p.effective_end_date
```

so a 2024 order always reports the price that was actually charged in 2024, regardless of how many
times the price has moved since or what order the scripts were run in. `branch_dim` and
`supplier_dim` carry no dates, so the facts join them on the natural key alone.

---

## Repository layout

```
datawarehouse_SalesAnalysis\
├── operational_DB\                     THE SOURCE SYSTEM (OLTP)
│   ├── create_operational_db.sql           13 CREATE TABLEs
│   └── sqlloader_control_files\            13 .ctl + load_all.bat / .sh
│
├── sales_data5\                        THE RAW CSVs  (revision 5: one generator, three load folders)
│   ├── gen_sales_data5.py                  regenerates + self-verifies everything below
│   ├── data19_23\   2019-2023   13 branches                 (initial load)
│   ├── data24\      2024        + 4 branches + 99_price_increase_2024.sql
│   └── data25\      2025        + men's line + supplier 8 + 99_price_change_2025.sql
│
│
├── dwh\                                THE WAREHOUSE SCHEMA
│   ├── create_dwh.sql                      12 tables: 7 dims + 5 facts
│   └── clear_dwh.sql                       empty it, keep the tables
│
├── ETL_Process\                        THE ETL
│   ├── initial_loading\                    first build, from data19_23\
│   │   ├── init_data_dim\   date_dim + gen_holidays.py
│   │   ├── init_dimension\  01..06  the 6 source-fed dimensions
│   │   ├── init_fact\       01..05  the 5 fact tables
│   │   └── validate_initial_loading.sql
│   └── subsequent_loading\                 incremental, from data24\ / data25\
│       ├── sub_dimension\   01..07  NEW records + Type 1 corrections
│       ├── maintain_SCD2\   01..04  CHANGED tracked attrs -> new versions
│       ├── sub_fact\        01..05  new rows + refresh changed ones
│       ├── exec_sub_proc24.sql       RUNS the data24 load (2024)
│       ├── exec_sub_proc25.sql       RUNS the data25 load (2025)
│       └── validate_subsequent_loading.sql
│
├── analysis\                           reporting queries
├── drop_all.sql                        destroy every object in the schema
└── DWH_Setup.md                        step-by-step build instructions
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
| **Initial** | `sales_data5\data19_23\` (2019–2023) | full build from empty: 13 branches, the COVID years and the 2022 e-commerce jump included |
| **Subsequent 1** | `sales_data5\data24\` (2024) | 4 new branches with their teams, 6k customers **+ 8 price rises** become SCD2 history |
| **Subsequent 2** | `sales_data5\data25\` (2025) | the HIM Essentials men's line (8 products) and its supplier, new customers and staff **+ 8 more product and 6 service price changes** — two products now carry three versions each |

New records and changed records are handled by deliberately separate scripts:

- `sub_dimension\` — a natural key that does **not exist yet** → insert it; plus **Type 1**
  overwrites of the untracked attributes on keys that already exist
- `maintain_SCD2\` — a **tracked** attribute changed → expire the old row, insert a new version
  (the four versioned dimensions only)

Run them in that order; reversed, a brand-new product would be "versioned" before it exists.

After all three loads `product_dim` holds **72 rows: 56 current + 16 expired**. That difference is
the whole point of Type 2 — `total − current` always equals the number of price changes ever made.

---

## Setup — building it from an empty schema

The full walk-through, with the expected row count after every step and a troubleshooting table, is
in **[DWH_Setup.md](DWH_Setup.md)**. The same fourteen steps in short:

**Requirements:** Oracle XE 11.2 (identifiers are kept ≤ 30 characters for it), SQL\*Plus,
SQL\*Loader, and Python 3 for the holiday and data generators. Give the schema room first —
`ALTER USER dwh DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;` as SYSDBA — then connect with
`sqlplus dwh/yourpassword@XE`.

### Part A — first build (2019–2023)

```sql
@drop_all.sql                                      -- 0. rebuilds only: wipe everything
@operational_DB\create_operational_db.sql          -- 1. OLTP tables            (13 tables)
```
```
cd operational_DB\sqlloader_control_files          -- 2. load the CSVs
.\load_all.bat dwh yourpassword XE "<repo>\sales_data5\data19_23"
```
```sql
@dwh\create_dwh.sql                                -- 3. warehouse tables       (12 tables)

-- 4. the calendar, the six dimensions, the five facts - in this order
@ETL_Process\initial_loading\init_data_dim\initial_load_date_dim.sql          -- 1,827 rows
@ETL_Process\initial_loading\init_dimension\01..06_init_*.sql                 -- 13/7/18/48/244/25,866
@ETL_Process\initial_loading\init_fact\01..05_init_*.sql                      -- 481,611/97,596/33,430/12,103/4,680

@ETL_Process\initial_loading\validate_initial_loading.sql                     -- 5. every "must be 0" = 0
```

### Part B — adding data24 (2024)

```sql
-- 6. create the 16 subsequent procedures (first time only - these run nothing)
@ETL_Process\subsequent_loading\sub_dimension\01..07_sub_*.sql
@ETL_Process\subsequent_loading\maintain_SCD2\01..04_maintain_*.sql
@ETL_Process\subsequent_loading\sub_fact\01..05_sub_*.sql
-- 7. validate: SELECT object_name, status FROM user_objects
--              WHERE object_type='PROCEDURE' AND status <> 'VALID';   -> no rows
```
```
cd operational_DB\sqlloader_control_files          -- 8. load the 2024 CSVs
.\load_all.bat dwh yourpassword XE "<repo>\sales_data5\data24"
```
```sql
@sales_data5\data24\99_price_increase_2024.sql     -- 9.  the 2024-01-01 price rise
@ETL_Process\subsequent_loading\exec_sub_proc24.sql -- 10. run the data24 load
```

### Part C — adding data25 (2025)

```
cd operational_DB\sqlloader_control_files          -- 11. load the 2025 CSVs
.\load_all.bat dwh yourpassword XE "<repo>\sales_data5\data25"
```
```sql
@sales_data5\data25\99_price_change_2025.sql       -- 12. products AND services change
@ETL_Process\subsequent_loading\exec_sub_proc25.sql -- 13. run the data25 load
@ETL_Process\subsequent_loading\validate_subsequent_loading.sql
```

### Step 14 — holidays (Python)

`date_dim` loads every day with `holiday_ind = 'N'`; one run covering 2019–2026 flags them all.

```
python -m venv .venv
.venv\Scripts\activate
pip install holidays
cd ETL_Process\initial_loading\init_data_dim
python gen_holidays.py 2019 2026 > holiday_update.sql
```
```sql
@ETL_Process\initial_loading\init_data_dim\holiday_update.sql   -- 108 dates, 14 holidays
```

**End state:** `branch_dim` 17 · `supplier_dim` 8 · `product_dim` 72 (56 current) · `service_dim` 24
(18 current) · `staff_dim` 319 · `customer_dim` 39,175 · `date_dim` 2,558 · `order_fact` 857,664 ·
`reservation_fact` 166,658 · `purchase_fact` 53,933 · `salary_payment_fact` 18,934 ·
`branch_utils_fact` 7,128.

---

## Validation

Two scripts collect every check in one place, rather than scattering them through the load files:

- [ETL_Process/initial_loading/validate_initial_loading.sql](ETL_Process/initial_loading/validate_initial_loading.sql)
- [ETL_Process/subsequent_loading/validate_subsequent_loading.sql](ETL_Process/subsequent_loading/validate_subsequent_loading.sql)

They check row counts against source, orphaned keys, duplicate natural keys, which dimension lookup
dropped rows, measure arithmetic (`qty × product_dim price − discount + tax = total`), SCD2 integrity
for the four versioned dimensions (exactly one current row per key, no expired row still open, no
overlapping version ranges) plus exactly-one-row-per-key for `branch_dim` / `supplier_dim`, and the business
patterns the dataset was built to contain. Anything labelled **"must be 0"** that is not 0 names
the table to investigate.

Both loads are **idempotent** — run them a second time and every procedure reports 0 inserted,
0 expired, 0 updated.

The CSVs themselves are verified before they leave the generator:
`python sales_data5\gen_sales_data5.py --verify` re-reads all three folders and checks FKs, ID
continuity, folder routing, registration/hire/opening dates, therapist schedules, closed-salon days,
price eras, tax rules and the Ipoh supplier rule, and prints a per-branch P&L with the pattern checks.

---

## What is in the data

The dataset is synthetic but deliberately not flat, so there is something to analyse:

- **COVID-19, on the real Malaysian timeline.** MCO 1.0 (18 Mar–3 May 2020) and FMCO (Jun–Aug 2021)
  contain **zero reservations** — salons were legally closed — while product sales continued at
  reduced volume via delivery. The Klang Valley (Selangor + KL) branches take the extra hit of the
  Oct 2020 CMCO and the July 2021 EMCO. Junior staff were let go in both lockdown waves and rehired
  in 2022; pay cuts, halved bonuses and the EPF 11 → 7 → 9 → 11 % employee rate are all in payroll.
- **2022: the shop went online** — product demand steps up ×1.38, half of all orders are now placed
  by customers from another city (31 % → 50 %), Petaling Jaya becomes the fulfilment hub, while
  in-salon reservations grow only modestly.
- **2025: the men's market** — the HIM Essentials men's line (6 SKUs) and two new face masks launch
  on 2025-01-01, 35 % of new registrations are male, product demand runs ×1.85.
- **The Malaysian festive calendar** — Chinese New Year, Hari Raya (which drifts ~11 days earlier
  every year: June 2019 → March 2025), Deepavali and Christmas drive demand run-ups; Valentine's,
  Mother's Day and Merdeka week add smaller ones; 11.11 / 12.12 and 3.3 / 6.6 / 9.9 / 10.10 mega-sale
  days spike on top; national public holidays are a salon half-day; `date_dim` carries the real
  public-holiday flags generated by `gen_holidays.py`. Quarterly shape: Q4 strongest, Q3 weakest.
- **Geography** — Petaling Jaya is the #1 branch every year and Selangor (PJ, Shah Alam, Puchong,
  Klang, Selayang, Gombak, Subang Jaya — seven shops) the #1 state, followed by the **Federal
  Territory of Kuala Lumpur** (Bukit Bintang, Setapak, Wangsa Maju, Bukit Jalil), Johor Bahru,
  George Town, Melaka, Ipoh and — from 2024 — Seremban and Kuantan. A further **13 satellite towns**
  (Kajang, Bangi, Cyberjaya, Rawang, Ampang, Sungai Buloh, Kepong, Kulai, Butterworth, Alor Gajah,
  Taiping, Nilai, Temerloh) hold paying customers but **no branch at all**, so the customer base
  covers 30 cities against 17 branch cities — the raw material for a branch-expansion analysis. **Ipoh is the loss-making branch**: it buys everything from an expensive
  Perak-only supplier, scrapes a small profit until 2023 and goes negative in 2024–25.
- **Linked volumes** — restocking follows the units each branch actually sold, therapists are never
  double-booked, salaries follow headcount and hire/leave dates, and ~54 % of orders are placed in
  the customer's own city while regulars keep coming back across all seven years.
- **Payroll and overheads that react** — 20 % then 15 % pay cuts during lockdown, 13th-month and Raya
  bonuses that follow the moving Raya month, landlord rent rebates in the closure months, then a
  steady 3 %/year rise.
- **A P&L that makes sense** — revenue − stock purchases − payroll − rent/utilities is +14 % in
  2019, thin to negative in the MCO years, +26 % from 2022, +22 % in 2024 (four ramping branches)
  and +29 % in 2025; PJ is #1 by profit every year, Ipoh is negative in 2024–25. Baskets are bigger in the
  festive run-ups (2.7 units/line vs 2.4) and biggest on mega-sale days (2.9).

Per-dataset detail: [sales_data5/README.md](sales_data5/README.md) (row counts, branch table,
year-by-year P&L, every pattern). Earlier revisions (`sales_data`, `sales_data2`, `sales_data3`) were
moved to the gitignored `trash\` folder; their IDs also start at 1, so they can never be loaded
alongside `sales_data5`.
