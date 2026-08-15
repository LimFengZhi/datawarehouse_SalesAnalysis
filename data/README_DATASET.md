# Glow Beauty — Operational Dataset (2019–2022)

Synthetic transactional data for the skincare & beauty retail + facial-service
business modelled in the ERD. Five Malaysian branches, four full years.

## Files (load in this order — parents before children)

| # | File | Rows | Notes |
|---|------|------|-------|
| 1 | `branch.csv` | 5 | KL, PJ, JB, George Town, Melaka |
| 2 | `supplier.csv` | 6 | |
| 3 | `product.csv` | 43 | 10 categories, RM18–RM120 |
| 4 | `service.csv` | 16 | 7 categories incl. 3 add-ons |
| 5 | `branch_utils_category.csv` | 6 | Rent, Electricity, Water, Internet, Maintenance, Waste |
| 6 | `staff.csv` | 96 | `br_ID` lives here (owner of the branch fact) |
| 7 | `customer.csv` | 26,000 | registered progressively 2018–2022 |
| 8 | `orders.csv` | 161,470 | product sales header |
| 9 | `order_detail.csv` | 349,396 | ~2.2 lines/order, incl. `order_unit_price` |
| 10 | `reservation.csv` | 65,110 | service booking header |
| 11 | `reservation_detail.csv` | 88,790 | ~1.4 services/booking (main + add-ons) |
| 12 | `purchase.csv` | 10,615 | restocking, twice monthly per branch |
| 13 | `salary_payment.csv` | 3,135 | monthly per active staff, no `br_ID` |
| 14 | `branch_expense.csv` | 1,440 | 5 branches × 48 months × 6 categories |

**Transactions per year** (orders + reservations):

| Year | Orders | Reservations | Total |
|------|--------|--------------|-------|
| 2019 | 40,624 | 18,203 | **58,827** |
| 2020 | 33,921 | 12,212 | **46,133** |
| 2021 | 30,921 | 8,732 | **39,653** |
| 2022 | 56,004 | 25,963 | **81,967** |

The ~60k/year target is met for a *normal* trading year (2019); 2020–21 fall
below it because of the lockdowns, and 2022 runs above it on post-pandemic
recovery. This variance is deliberate — a flat 60k every year would leave you
with nothing to analyse.

## Patterns built into the data

### 1. COVID-19 (Malaysia timeline)

| Period | Phase | Product | Service |
|--------|-------|---------|---------|
| 18 Mar – 3 May 2020 | MCO 1.0 | 22% | **0%** (salons closed) |
| 4 May – 9 Jun 2020 | CMCO | 58% | 30% |
| 10 Jun – 13 Oct 2020 | RMCO | 90% | 78% |
| 14 Oct 2020 – 12 Jan 2021 | CMCO 2nd wave | 80% | 58% |
| 13 Jan – 4 Mar 2021 | MCO 2.0 | 48% | 12% |
| 1 Jun – 31 Aug 2021 | FMCO | 34% | **0%** |
| 1 Sep – 31 Oct 2021 | Phased reopening | 72% | 48% |
| 1 Nov 2021 – 31 Mar 2022 | Transition to endemic | 95% | 86% |
| 1 Apr 2022 onward | Endemic / revenge spending | 112% | 118% |

Services are hit much harder than retail — physical treatments were legally
prohibited during MCO, while products still moved via delivery. **April 2020
and June–August 2021 contain zero reservations**, which is correct, not a bug.

### 2. Malaysian festive calendar

Demand ramps up in the ~3–4 weeks *before* each festival (grooming rush), then
collapses on the holiday itself:

- **Chinese New Year** — 2019-02-05, 2020-01-25, 2021-02-12, 2022-02-01 (peak ×1.75)
- **Hari Raya Aidilfitri** — 2019-06-05, 2020-05-24, 2021-05-13, 2022-05-02 (peak ×1.85, strongest)
- **Deepavali** — 2019-10-27, 2020-11-14, 2021-11-04, 2022-10-24 (×1.45)
- **Christmas / year-end** — ×1.40
- **Mega sale days** — 11.11 and 12.12 (×2.3), plus 3.3 / 9.9 / 10.10 (×1.5)
- **Malaysia Mega Sale Carnival** — Jun–Aug uplift

Note Raya moves ~11 days earlier each year, so the spike shifts from June 2019
to May 2022 — a good test of whether your date dimension handles moving feasts.

### 3. Other patterns

- **Q4 is always strongest**; Q3 weakest in normal years
- **Weekend uplift** — Sat ×1.42, Sun ×1.25 vs Mon ×0.80
- **Time of day** — reservations cluster 10:00–20:00, peaking 16:00–18:00
- **Branch size** — KL > PJ > JB > George Town > Melaka (RM10.2m … RM3.8m lifetime)
- **Loyalty tiers** drive discount: Bronze 0%, Silver 3%, Gold 7%, Platinum 12%
- **Weekday off-peak promo** — extra 5% off services Mon–Thu
- **Pay cuts** during MCO 1.0 (−20%) and FMCO (−15%); 13th-month bonus each
  December (small in 2020, large in 2022) and a Raya bonus
- **Rent rebates** and near-zero utilities during lockdown months
- **6% SST** on both products and services

### Revenue summary (RM million)

| Year | Product | Service | Total |
|------|---------|---------|-------|
| 2019 | 6.10 | 2.90 | 9.00 |
| 2020 | 5.07 | 1.94 | 7.01 |
| 2021 | 4.60 | 1.38 | 5.98 |
| 2022 | 8.28 | 4.13 | 12.42 |

## Data quality

All foreign keys validated — zero orphans. Additionally guaranteed:

- No order or reservation dated before the customer's registration date
- Serving staff always belong to the transacting branch
- No transactions by staff before hire date or after resignation date
- No salary payments outside a staff member's employment window

## Loading into Oracle

Dates are `YYYY-MM-DD`; timestamps are `YYYY-MM-DD HH24:MI:SS`. Set the session
format before loading:

```sql
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';
ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';
```

For SQL*Loader, use `TRAILING NULLCOLS` and a control file per table. For SQL
Developer, right-click table → Import Data → CSV.

`order_detail.csv` is the largest file (~15 MB); consider `sqlldr` with
`DIRECT=TRUE` for speed.

## Suggested analyses for the report

1. **COVID impact** — service vs product revenue, 2019 baseline vs 2020/21 (services fell 52%, products only 25%)
2. **Recovery trajectory** — quarterly index; Q4 2021 was the first quarter back at baseline
3. **Festive effect** — daily revenue in the 30 days before Raya vs annual average
4. **Branch profitability** — revenue − COGS (purchase) − salary − branch expense
5. **Product category mix** — did lockdown shift the basket toward cleansers/masks (at-home care) and away from premium serums?
6. **Staff productivity** — service revenue per therapist per branch
7. **Customer cohorts** — do 2019-registered customers spend more than 2022 joiners?
8. **Loyalty tier** — discount cost vs incremental basket size
