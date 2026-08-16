# data3 — the 2025 dataset

Year six. Continues from [data/](../data/) (2019–2022) and [data2/](../data2/) (2023–2024).

Every file is named **exactly like its counterpart in `data/`** so the existing SQL\*Loader control
files load it unchanged, and every ID continues from where `data2/` stopped.

Regenerate at any time with `python gen_data3.py` (seeded, so output is identical each run).

## Loading it

```
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\sqlloader_control_files
load_all.bat dwh <password> XE "c:\Users\laoli\Downloads\datawarehouseAnalysis\data3"
```

## What is NEW in 2025

| | |
|---|---|
| **3,500 customers** | IDs 32001–35500, registering across the year |
| **2 suppliers** | IDs 7–8 — AuraDerm Supply, Nordic Skin Trading |
| **8 product prices** | changed on 2025-01-01 |
| **6 service prices** | changed on 2025-01-01 — **the first time services have moved** |

## What is REUSED, unchanged

No new branch, no new staff, no new products, no new services. Five files are header-only for
exactly that reason — `branch.csv`, `staff.csv`, `product.csv`, `service.csv`,
`branch_utils_category.csv`. They exist so `load_all.bat` finds a file for every control file and
loads 0 rows instead of failing.

- all **6 branches**, Ipoh now mature rather than ramping
- all **114 staff**
- all **48 products** and **18 services** — only their prices move
- all **32,000 existing customers** keep transacting alongside the new ones

## Transactions

| File | Rows |
|---|---:|
| `orders.csv` | 73,858 |
| `order_detail.csv` | 164,752 |
| `reservation.csv` | 31,392 |
| `reservation_detail.csv` | 39,627 |
| `purchase.csv` | 3,226 |
| `salary_payment.csv` | 1,332 |
| `branch_expense.csv` | 432 |
| **total** | **314,619** |

## The 2025 price changes

[99_price_change_2025.sql](99_price_change_2025.sql) applies these to the OLTP. All 23,184 order
lines for the uplifted products in data3 already carry the new prices.

### Products

| Product | 2024 | 2025 | |
|---|---:|---:|---|
| Salicylic Acid Acne Cleanser | 48.00 | **54.00** | **2nd rise** — was 42 before 2023 |
| Hyaluronic Acid Serum | 75.00 | 84.00 | |
| Peptide Firming Serum | 135.00 | **149.00** | **2nd rise** — was 120 before 2023 |
| Ceramide Barrier Cream | 78.00 | 88.00 | |
| Tinted Sunscreen SPF45 | 62.00 | 69.00 | |
| Collagen Sheet Mask (Box of 5) | 45.00 | 50.00 | |
| AHA/BHA Exfoliating Solution | 65.00 | 72.00 | |
| Azelaic Acid Clarifying Serum | 95.00 | 105.00 | launched 2023 |

### Services

| Service | 2024 | 2025 |
|---|---:|---:|
| HydraFacial | 220.00 | 245.00 |
| Hydrating Glow Facial | 165.00 | 185.00 |
| Anti Aging Collagen Facial | 280.00 | 310.00 |
| Vitamin C Brightening Facial | 150.00 | 168.00 |
| Acne Clear Facial | 130.00 | 145.00 |
| Microneedling Rejuvenation | 380.00 | 420.00 |

### Why the two second-rises matter

Products **4** and **16** now carry **three versions** in `product_dim`:

```
42.00 / 120.00   flagged 'N', ending 2022-12-31
48.00 / 135.00   flagged 'N', 2023-01-01 to 2024-12-31
54.00 / 149.00   flagged 'Y', from 2025-01-01
```

Order lines from each era point at their own version and still report the price actually paid. Two
versions proves SCD Type 2 works; three is what a real dimension looks like after a few years.

Services moving for the first time also gives `service_dim` its first version history.

## The patterns

**Growth.** 73,858 orders, up from 67,705 in 2024. No lockdown gaps.

**Location.** All six branches trade the whole year. Ipoh has finished ramping and holds a steady
share instead of climbing — the shape of a matured outlet.

**76% of shoppers use the branch in their own city**, so `cus_city` correlates with `br_city`
without being a copy.

**Day of week** — Saturday peaks, Monday troughs, same ×1.42 / ×0.80 shape as every prior year:

```
Mon 7,924   Tue 9,429   Wed 9,407   Thu 9,695
Fri 11,233  Sat 13,761  Sun 12,409
```

**Festivals keep moving.** Hari Raya drifts ~11 days earlier every year, so it lands in **March** for
the first time in this dataset:

| | 2023 | 2024 | 2025 |
|---|---|---|---|
| Chinese New Year | 22 Jan | 10 Feb | **29 Jan** |
| Hari Raya Aidilfitri | 22 Apr | 10 Apr | **31 Mar** |
| Deepavali | 12 Nov | 31 Oct | **20 Oct** |
| Christmas | 25 Dec | 25 Dec | 25 Dec |

That shows in the monthly totals — the Raya peak has moved out of April into March, and Deepavali
has pulled November's peak back into October:

```
Jan 6,893   Feb 5,209   Mar 7,709   Apr 5,627
May 6,005   Jun 5,654   Jul 5,052   Aug 5,288
Sep 4,944   Oct 7,403   Nov 6,742   Dec 7,332
```

Q3 is still the trough, Q4 still the strongest. Mega-sale days spike on top: 11.11 and 12.12 ×2.3,
3.3 / 9.9 / 10.10 ×1.5.

**Money.** Loyalty discounts Bronze 0 / Silver 3% / Gold 7% / Platinum 12%, 6% SST on the discounted
amount, purchase cost at 45–55% of shelf price, 11% EPF, a 13th-month bonus in December and the Raya
bonus in **March** this year (following the festival). Salaries up 4% on 2024; rent and utilities up
6% on 2023 levels.

## Loading order

```
1.  load_all.bat dwh <pw> XE "...\data3"
2.  @data3\99_price_change_2025.sql
3.  @subsequent_loading\execute_sub2.sql              already set to 2025 throughout
4.  python gen_holidays.py 2019 2025 > holiday_update.sql
    @holiday_update.sql
5.  @subsequent_loading\validate_subsequent_loading.sql
```

Step 2 matters: the maintain procedures compare the dimension against the OLTP, so the 2025 prices
must be in the OLTP *before* execute_sub2.sql runs, or there is nothing for them to detect — and
the 2025 fact rows would attach to the old price versions.

(The 19 procedures must already exist from the data2 run; execute_sub2.sql's STEP 0 checks.)

## Verified before shipping

| Check | Result |
|---|---|
| ID continuity with `data2/` | every file starts at last + 1 |
| Header-only files really empty | 5 of 5 |
| Headers identical to `data/` | 0 differences |
| Orders before customer registration | 0 |
| Staff at the wrong branch | 0 |
| Uplifted products still at the old price | 0 of 23,184 |
| Service prices (derived from the tax on each line) | all 8 checked match |
| New suppliers 7 and 8 actually used | 415 and 380 purchases |
| Appointments outside 10:00–20:00, or `end ≤ start` | 0 |
| Customer ages | 18–60, consistent with `data/` |
| Encoding | plain ASCII, no BOM |
