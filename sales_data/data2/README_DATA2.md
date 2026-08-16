# data2 — the 2023–2024 expansion dataset

Continues the Glow Beauty story two more years. Every file is named
**exactly like its counterpart in [data/](../data/)** so the existing SQL\*Loader control
files load it unchanged, and every ID continues from where `data/` stopped — nothing collides.

Regenerate at any time with `python gen_data2.py` (seeded, so output is identical each run).

## Loading it

```
cd c:\Users\laoli\Downloads\datawarehouseAnalysis\operational_DB\sqlloader_control_files
load_all.bat dwh <password> XE "c:\Users\laoli\Downloads\datawarehouseAnalysis\sales_data\data2"
```

The 4th argument points the same control files at this folder. All 14 `.ctl` files use `APPEND`,
so the rows are added to the existing tables.

`supplier.csv` and `branch_utils_category.csv` are **header-only** — no new suppliers or utility
categories. They exist so `load_all.bat` finds a file and loads 0 rows instead of failing.

## What is in it

### Reference data

| File | Rows | IDs | Notes |
|---|---:|---|---|
| `branch.csv` | 1 | 6 | **Glow Beauty Ipoh**, Perak — opens 2023-03-01 |
| `staff.csv` | 18 | 97–114 | Ipoh team, all hired 2023-02-15, two weeks before opening |
| `product.csv` | 5 | 44–48 | on the shelf from 2023-02-01 |
| `service.csv` | 2 | 17–18 | bookable from 2023-04-01 |
| `customer.csv` | 6,000 | 26001–32000 | registering across 2023–2024 |

New products: Snail Mucin Repair Essence, Azelaic Acid Clarifying Serum, Barrier Repair Cica Cream,
Mineral Sunscreen Stick SPF50, Overnight Retinal Sleeping Mask.
New services: Microneedling Rejuvenation (RM 380), Scalp Detox Add on (RM 45).

### Transactions

| File | Rows |
|---|---:|
| `orders.csv` | 129,239 |
| `order_detail.csv` | 285,944 |
| `reservation.csv` | 54,553 |
| `reservation_detail.csv` | 68,098 |
| `purchase.csv` | 6,322 |
| `salary_payment.csv` | 2,646 |
| `branch_expense.csv` | 852 |
| **total** | **547,654** |

Orders alone: **61,534 in 2023** and **67,705 in 2024**.
Customer ages run 18–61, the same range as `data/`.

## The patterns

Everything below is generated deliberately, so the warehouse has something real to find.

**Growth.** 2023 and 2024 continue the endemic-phase recovery that began in 2022 — no lockdown
gaps, unlike 2020–2021.

**Location.** Branch pull keeps the established ranking, with Ipoh joining at the bottom and ramping
up over its first year:

| Branch | Orders |
|---|---:|
| Kuala Lumpur | 36,122 |
| Petaling Jaya | 28,983 |
| Johor Bahru | 24,232 |
| George Town | 17,945 |
| Melaka | 13,220 |
| **Ipoh** (from Mar 2023) | 8,737 |

**76% of shoppers use the branch in their own city**, so `cus_city` and `br_city` correlate without
being identical. New Ipoh/Perak customers only start registering once that branch opens.

**Day of week.** Saturday peaks, Monday troughs — matching the ×1.42 / ×0.80 shape of 2019–2022:

```
Mon 13,959  Tue 16,140  Wed 16,218  Thu 17,152
Fri 19,297  Sat 24,630  Sun 21,520
```

**Season and festivals.** Q4 strong, Q3 weak, with run-ups before each festival — and the festivals
move correctly between years. Hari Raya falls **12 days earlier** in 2024 than 2023, Chinese New
Year 19 days later:

| | 2023 | 2024 |
|---|---|---|
| Chinese New Year | 22 Jan | 10 Feb |
| Hari Raya Aidilfitri | 22 Apr | 10 Apr |
| Deepavali | 12 Nov | 31 Oct |
| Christmas | 25 Dec | 25 Dec |

2023 orders by month — note the April Raya peak and the July–September trough:

```
Jan 5,806   Feb 4,171   Mar 4,647   Apr 6,453
May 4,839   Jun 4,711   Jul 4,168   Aug 4,134
Sep 4,131   Oct 5,521   Nov 6,149   Dec 6,195
```

Mega-sale days spike on top: 11.11 and 12.12 ×2.3, and 3.3 / 9.9 / 10.10 ×1.5.

**Appointments.** Slots run 10:00–20:00 on a 15-minute grid, peaking 16:00–18:00, with each service
taking its own realistic duration (add-ons 15–30 min, anti-aging 90 min). Weekday morning bookings
get an extra 5% off, as in the original data.

**Money.** Loyalty discounts Bronze 0 / Silver 3% / Gold 7% / Platinum 12%, 6% SST on the discounted
amount, purchase cost at 45–55% of shelf price, 11% EPF deduction on salaries, a 13th-month bonus
every December and a Raya bonus in April. Rent rises 3% a year; electricity climbs 12% in the hot
months.

## The 2023 price rise — why it is here

Seven of the best-selling products get a price increase on **2023-01-01**:

| Product | 2022 | 2023 |
|---|---:|---:|
| Salicylic Acid Acne Cleanser | 42.00 | 48.00 |
| Vitamin C Brightening Serum | 89.00 | 98.00 |
| Retinol Renewal Serum | 110.00 | 125.00 |
| Peptide Firming Serum | 120.00 | 135.00 |
| Collagen Youth Cream | 95.00 | 108.00 |
| SPF50 Daily Sunscreen Lotion | 55.00 | 62.00 |
| Hydrating Sleeping Mask (Jar) | 72.00 | 82.00 |

Every one of the **32,796** order lines for these products in `data2` already carries the new price,
while the 2019–2022 lines in `data/` keep the old one. [99_price_increase_2023.sql](99_price_increase_2023.sql)
applies the same change to the OLTP `product` table.

That is what makes SCD Type 2 demonstrable rather than theoretical: run the maintenance and
`product_dim` ends up with two rows per product, and the same product reports two different prices
against the orders that actually paid each one.

## Full load order

```
1.  load_all.bat dwh <pw> XE "...\sales_data\data2"  append the new source rows
2.  @sales_data\data2\99_price_increase_2023.sql                 raise the 7 prices in the OLTP
3.  run the 19 numbered ETL_Process\subsequent_loading scripts    create the procedures (once)
4.  @ETL_Process\subsequent_loading\execute_sub_procedure.sql     calendar to 2024, new dimension
                                                      records, SCD2 versions, facts
5.  python gen_holidays.py 2019 2024 > holiday_update.sql
    @holiday_update.sql                               holidays for the new years
6.  @ETL_Process\subsequent_loading\validate_subsequent_loading.sql
```

See LOADING_GUIDE.md Part B for the full walk-through.

## Verified before shipping

| Check | Result |
|---|---|
| ID continuity with `data/` | every file starts at last + 1 |
| Orders before customer registration | 0 |
| Reservations before customer registration | 0 |
| Serving staff at the wrong branch | 0 |
| Ipoh trading before it opened | 0 (first order 2023-03-02) |
| New products sold before launch | 0 (first sale 2023-02-01) |
| Uplifted products still at the old price in 2023+ | 0 |
| Appointments outside 10:00–20:00 | 0 |
| `end_time` ≤ `start_time` | 0 |
