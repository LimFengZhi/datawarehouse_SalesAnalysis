# Glow Beauty — Data Warehouse

**BAIT3003 Data Warehouse Technology** — a full Oracle star-schema warehouse built over a synthetic
Malaysian beauty-retail business: thirteen branches across Selangor, Kuala Lumpur, Johor, Penang,
Melaka and Perak selling skincare products and booking facial services, eight years of trading
(2018–2025), ~1.3 million source rows.

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
| `order_fact` | one product line on an order | 670,282 |
| `reservation_fact` | one service line booked | 159,977 |
| `purchase_fact` | one restocking line | 41,411 |
| `salary_payment_fact` | one staff member per pay period | 19,517 |
| `branch_expense_fact` | one branch per utility per month | 7,074 |

Six of the eight dimensions are **SCD Type 2** — a changed attribute expires the old row and opens
a new version, so history never gets rewritten. The one attribute that drifts for a non-business
reason (`customer_dim.cus_age_band`, derived from the date of birth) is **Type 1**: overwritten in
place, because a customer having a birthday is not a business event worth versioning.

The schema follows the two ERDs of the project: `staff` has a single job-title column
(`st_position`), `order_detail` carries no unit price (the price is the `product_dim` version in
force on the order date — which is exactly what makes the SCD2 history matter), `reservation` has
both `booking_date` (when it was booked) and `reservation_date` (the appointment day, which is what
`reservation_fact.date_key` points at), and every fact's primary key is the composite of its
dimension keys plus the degenerate OLTP IDs.

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
datawarehouse_SalesAnalysis\
├── operational_DB\                     THE SOURCE SYSTEM (OLTP)
│   ├── create_operational_db.sql           14 CREATE TABLEs
│   └── sqlloader_control_files\            14 .ctl + load_all.bat / .sh
│
├── sales_data3\                        THE RAW CSVs  (revision 3: one generator, three load folders)
│   ├── gen_sales_data3.py                  regenerates + self-verifies everything below
│   ├── data18_21\   2018-2021   12 branches                 (initial load)
│   ├── data22_23\   2022-2023   + Ipoh + 99_price_increase_2023.sql
│   └── data24_25\   2024-2025   + 2 suppliers + 99_price_change_2025.sql
│
├── sales_data2\                        REVISION 2 - same rows and IDs as sales_data3, different
│                                       amounts (loss-making cost base); reference only, load ONE of the two
├── sales_data\                         LEGACY CSVs (2019-2025, 5-6 branches) - reference only,
│                                       not loadable alongside sales_data3 (IDs collide)
│
├── dwh\                                THE WAREHOUSE SCHEMA
│   ├── create_dwh.sql                      13 tables: 8 dims + 5 facts
│   └── clear_dwh.sql                       empty it, keep the tables
│
├── ETL_Process\                        THE ETL
│   ├── initial_loading\                    first build, from data18_21\
│   │   ├── init_data_dim\   date_dim + gen_holidays.py
│   │   ├── init_dimension\  01..07  the 7 source-fed dimensions
│   │   ├── init_fact\       01..05  the 5 fact tables
│   │   └── validate_initial_loading.sql
│   └── subsequent_loading\                 incremental, from data22_23\ / data24_25\
│       ├── sub_dimension\   01..08  NEW records only
│       ├── maintain_SCD2\   01..06  CHANGED records -> new versions
│       ├── sub_fact\        01..05  new rows + refresh changed ones
│       ├── execute_sub_procedure.sql   RUNS the data22_23 load (2022-23)
│       ├── execute_sub2.sql            RUNS the data24_25 load (2024-25)
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
| **Initial** | `sales_data3\data18_21\` (2018–2021) | full build from empty: 12 branches, the COVID years included |
| **Subsequent 1** | `sales_data3\data22_23\` (2022–2023) | new branch (Ipoh), 50 staff, 5 products, 2 services, 7k customers **+ 7 price rises** become SCD2 history |
| **Subsequent 2** | `sales_data3\data24_25\` (2024–2025) | new customers, staff and suppliers **+ 8 more product and 6 service price changes** — two products now carry three versions each |

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
load_all.bat dwh yourpassword XE                   -- 2. load the CSVs (defaults to data18_21)
```
```sql
@dwh\create_dwh.sql                                -- 3. warehouse tables
-- 4. date_dim, then gen_holidays.py 2018 2021, then the 7 dimension + 5 fact scripts
@ETL_Process\initial_loading\validate_initial_loading.sql
```

Then Parts B and C of the guide add `data22_23\` and `data24_25\` on top without wiping anything.

**Requirements:** Oracle XE 11.2 (identifiers are kept ≤ 30 characters for it), SQL\*Plus,
SQL\*Loader, and Python 3 for the holiday and data generators.

---

## Validation

Two scripts collect every check in one place, rather than scattering them through the load files:

- [ETL_Process/initial_loading/validate_initial_loading.sql](ETL_Process/initial_loading/validate_initial_loading.sql)
- [ETL_Process/subsequent_loading/validate_subsequent_loading.sql](ETL_Process/subsequent_loading/validate_subsequent_loading.sql)

They check row counts against source, orphaned keys, duplicate natural keys, which dimension lookup
dropped rows, measure arithmetic (`qty × product_dim price − discount + tax = total`), SCD2 integrity (exactly one
current row per key, no expired row still open, no overlapping version ranges), and the business
patterns the dataset was built to contain. Anything labelled **"must be 0"** that is not 0 names
the table to investigate.

Both loads are **idempotent** — run them a second time and every procedure reports 0 inserted,
0 expired, 0 updated.

The CSVs themselves are verified before they leave the generator:
`python sales_data3\gen_sales_data3.py --verify` re-reads all three folders and checks FKs, ID
continuity, registration/hire/opening dates, therapist schedules, closed-salon days, price eras and
tax rules.

---

## What is in the data

The dataset is synthetic but deliberately not flat, so there is something to analyse:

- **COVID-19, on the real Malaysian timeline.** MCO 1.0 (18 Mar–3 May 2020) and FMCO (Jun–Aug 2021)
  contain **zero reservations** — salons were legally closed — while product sales continued at
  reduced volume via delivery. The Klang Valley (Selangor + KL) branches take the extra hit of the
  Oct 2020 CMCO and the July 2021 EMCO. Junior staff were let go in both lockdown waves and rehired
  in 2022; pay cuts, halved bonuses and the EPF 11 → 7 → 9 → 11 % employee rate are all in payroll.
  2022 recovers and overshoots on revenge spending.
- **The Malaysian festive calendar** — Chinese New Year, Hari Raya (which drifts ~11 days earlier
  every year: June 2018 → March 2025), Deepavali and Christmas drive demand run-ups; 11.11 / 12.12
  and 3.3 / 9.9 / 10.10 mega-sale days spike on top; `date_dim` carries the real public-holiday
  flags generated by `gen_holidays.py`. The 2018 GST→SST tax holiday (Jun–Aug 2018) shows as 0 % tax.
- **Geography** — Petaling Jaya is the #1 branch and Selangor (PJ, Shah Alam, Puchong, Klang,
  Selayang) the #1 state, followed by Kuala Lumpur (Bukit Bintang, Setapak, Wangsa Maju,
  Gombak), Johor Bahru, George Town, Melaka and —
  from March 2023 — Ipoh.
- **Linked volumes** — restocking follows the units each branch actually sold, therapists are never
  double-booked, salaries follow headcount and hire/leave dates, and ~70 % of customers shop in
  their own city while regulars keep coming back across all eight years.
- **Payroll and overheads that react** — 20 % then 15 % pay cuts during lockdown, 13th-month and Raya
  bonuses that follow the moving Raya month, landlord rent rebates in the closure months, then a
  steady 3 %/year rise.
- **A P&L that makes sense** (revision 3) — revenue − stock purchases − payroll − rent/utilities is
  close to break-even in 2018–19, negative in the MCO years, positive from 2022 and ~10 % by 2024–25;
  in FY2024 12 of 13 branches are in the black (Ipoh, in its second year, is not). Baskets are bigger
  in the festive run-ups (2.7 units/line vs 2.4) and biggest on mega-sale days (2.9). `sales_data2\`
  is the same data with the earlier cost base (every branch loss-making) — kept for comparison.

Per-dataset detail: [sales_data3/README.md](sales_data3/README.md) ·
[data18_21](sales_data3/data18_21/README_DATA18_21.md) ·
[data22_23](sales_data3/data22_23/README_DATA22_23.md) ·
[data24_25](sales_data3/data24_25/README_DATA24_25.md)
