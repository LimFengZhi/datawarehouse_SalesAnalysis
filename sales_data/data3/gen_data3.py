"""
gen_data3.py
Generates the 2025 dataset for Glow Beauty.

    python gen_data3.py

Writes CSVs into this folder, named EXACTLY like the originals in
data\\ and data2\\ so the existing SQL*Loader control files load them
unchanged:

    load_all.bat dwh <password> XE "c:\\...\\sales_data\\data3"

Every .ctl uses APPEND and every ID continues from where data2\\
stopped, so nothing collides.

WHAT IS NEW IN 2025
    3,500 customers      IDs 32001..35500
    2 suppliers          IDs 7..8
    8 product prices     change on 2025-01-01
    6 service prices     change on 2025-01-01  (first time services move)

WHAT IS REUSED, UNCHANGED
    all 6 branches   - no new outlet this year
    all 114 staff    - no new hires
    all 48 products  - no new lines, only price changes
    all 18 services  - no new treatments, only price changes
    all 32,000 existing customers keep transacting

TWO PRODUCTS RISE FOR THE SECOND TIME
    4  Salicylic Acid Acne Cleanser  42 -> 48 (2023) -> 54 (2025)
    16 Peptide Firming Serum        120 -> 135 (2023) -> 149 (2025)
    Those two end up with THREE versions in product_dim, which is what
    a real Type 2 dimension looks like after a few years.

PATTERNS BAKED IN (see README_DATA3.md for the full list)
    - growth continuing from 2024, no lockdown gaps
    - branch ranking KL > PJ > JB > George Town > Melaka > Ipoh, with
      Ipoh now mature rather than ramping
    - customers shop mostly at the branch in their own city
    - Sat/Sun peak, Monday trough, Q4 strong, Q3 weak
    - CNY 29 Jan, Hari Raya 31 Mar (11 days earlier than 2024 again),
      Deepavali 20 Oct, Christmas
    - 11.11 and 12.12 mega-sale spikes
    - loyalty discounts Bronze 0 / Silver 3 / Gold 7 / Platinum 12 %
    - 6% SST on the discounted amount
    - no transaction before a customer registers
"""
import csv
import os
import random
from datetime import date, timedelta

random.seed(2025)              # deterministic - re-runs give identical files
OUT = os.path.dirname(os.path.abspath(__file__))

# ===================================================================
# CONTINUATION POINTS - the last ID used after data\ + data2\
# ===================================================================
LAST = dict(br=6, st=114, cus=32000, product=48, serv=18, sup=6,
            order=290709, order_det=635340, res=119663, res_det=156888,
            purchase=16937, sal_pay=5781, br_exp=2292)

START, END = date(2025, 1, 1), date(2025, 12, 31)
SST = 0.06

# ===================================================================
# 1. THE 2025 PRICE CHANGES
# Kept in step with 99_price_change_2025.sql. Every 2025 transaction
# uses the NEW price; everything in data\ and data2\ keeps its own.
# ===================================================================
# product_ID: (price during 2023-2024, new price from 2025-01-01)
PRODUCT_RISE_2025 = {
    4:  (48.00,  54.00),   # 2nd rise - was 42 before 2023
    13: (75.00,  84.00),
    16: (135.00, 149.00),  # 2nd rise - was 120 before 2023
    19: (78.00,  88.00),
    24: (62.00,  69.00),
    28: (45.00,  50.00),
    36: (65.00,  72.00),
    45: (95.00, 105.00),   # launched 2023, first rise
}
# serv_ID: (price to end 2024, new price from 2025-01-01)
SERVICE_RISE_2025 = {
    5:  (220.00, 245.00),
    6:  (165.00, 185.00),
    7:  (280.00, 310.00),
    10: (150.00, 168.00),
    12: (130.00, 145.00),
    17: (380.00, 420.00),  # launched 2023, first rise
}

# ===================================================================
# 2. NEW SUPPLIERS (7-8)
# ===================================================================
NEW_SUPPLIERS = [
    (7, "AuraDerm Supply Sdn Bhd", "03-77218844", "sales@auraderm.com.my"),
    (8, "Nordic Skin Trading",     "04-2663311",  "order@nordicskin.com.my"),
]

# ===================================================================
# 3. CATALOGUE AS AT END OF 2024
# Base price, then the 2023 rise, then the 2025 rise on top.
# ===================================================================
BASE_PRICE = {
    1: 32, 2: 38, 3: 29, 4: 42, 5: 35, 6: 27, 7: 32, 8: 38, 9: 30,
    10: 45, 11: 40, 12: 89, 13: 75, 14: 68, 15: 110, 16: 120, 17: 85,
    18: 65, 19: 78, 20: 48, 21: 95, 22: 55, 23: 55, 24: 62, 25: 48,
    26: 58, 27: 38, 28: 45, 29: 34, 30: 72, 31: 48, 32: 68, 33: 58,
    34: 85, 35: 42, 36: 65, 37: 55, 38: 58, 39: 62, 40: 72, 41: 22,
    42: 25, 43: 18,
    44: 68, 45: 95, 46: 82, 47: 52, 48: 88,        # launched 2023
}
PRICE_RISE_2023 = {4: 48.00, 12: 98.00, 15: 125.00, 16: 135.00,
                   21: 108.00, 23: 62.00, 30: 82.00}

SERV_PRICE = {
    1: 75, 2: 60, 3: 110, 4: 95, 5: 220, 6: 165, 7: 280, 8: 320,
    9: 250, 10: 150, 11: 180, 12: 130, 13: 160, 14: 35, 15: 55, 16: 40,
    17: 380, 18: 45,
}
SERV_MINUTES = {
    1: 60, 2: 45, 3: 75, 4: 60, 5: 75, 6: 75, 7: 90, 8: 90, 9: 75,
    10: 60, 11: 75, 12: 60, 13: 75, 14: 15, 15: 30, 16: 30,
    17: 90, 18: 20,
}
ADDON_SERVICES = [14, 15, 16, 18]
MAIN_SERVICES = [s for s in SERV_PRICE if s not in ADDON_SERVICES]


def price_of(pid: int) -> float:
    """Shelf price during 2025 - both rises applied where they apply."""
    if pid in PRODUCT_RISE_2025:
        return PRODUCT_RISE_2025[pid][1]
    if pid in PRICE_RISE_2023:
        return PRICE_RISE_2023[pid]
    return float(BASE_PRICE[pid])


def serv_price_of(sid: int) -> float:
    if sid in SERVICE_RISE_2025:
        return SERVICE_RISE_2025[sid][1]
    return float(SERV_PRICE[sid])


# Cheaper items shift more units
PRODUCT_WEIGHT = {p: (60.0 / BASE_PRICE[p]) ** 0.45 * random.uniform(0.75, 1.3)
                  for p in BASE_PRICE}

# ===================================================================
# 4. BRANCHES - all six, all mature now. Ipoh finished ramping during
# 2024, so it holds a steady share instead of climbing.
# ===================================================================
BRANCH_CITY = {
    1: "Kuala Lumpur", 2: "Petaling Jaya", 3: "Johor Bahru",
    4: "George Town",  5: "Melaka",        6: "Ipoh",
}
BRANCH_WEIGHT = {1: 1.00, 2: 0.81, 3: 0.67, 4: 0.50, 5: 0.37, 6: 0.42}

# ===================================================================
# 5. SEASONALITY
# ===================================================================
WEEKDAY_MULT = {0: 0.80, 1: 0.92, 2: 0.95, 3: 1.00, 4: 1.12,
                5: 1.42, 6: 1.25}          # Mon..Sun
QUARTER_MULT = {1: 1.00, 2: 1.05, 3: 0.90, 4: 1.15}

# (festival date, peak multiplier, run-up window in days)
# Hari Raya keeps drifting ~11 days earlier each year:
#   2023 Apr 22 -> 2024 Apr 10 -> 2025 Mar 31
FESTIVALS = [
    (date(2025, 1, 29), 1.75, 18),   # Chinese New Year
    (date(2025, 3, 31), 1.85, 25),   # Hari Raya Aidilfitri
    (date(2025, 10, 20), 1.45, 14),  # Deepavali
    (date(2025, 12, 25), 1.40, 16),  # Christmas
]
MEGA_SALE = {(11, 11): 2.30, (12, 12): 2.30, (3, 3): 1.50,
             (9, 9): 1.50, (10, 10): 1.50}


def day_weight(d: date) -> float:
    w = WEEKDAY_MULT[d.weekday()] * QUARTER_MULT[(d.month - 1) // 3 + 1]
    for fdate, peak, window in FESTIVALS:
        delta = (fdate - d).days
        if 0 <= delta <= window:                    # run-up, not after
            w *= 1 + (peak - 1) * (1 - delta / window)
    w *= MEGA_SALE.get((d.month, d.day), 1.0)
    return w


# ===================================================================
# 6. NAME POOLS - same flavour as 2019-2024
# ===================================================================
FIRST_F = ["Nurin", "Mei Ling", "Chloe", "Aisyah", "Priya", "Rachel",
           "Siti", "Hui Min", "Zarina", "Lakshmi", "Nadia", "Amelia",
           "Sharmila", "Wan Ying", "Farah", "Kavitha", "Yee Ling",
           "Nur Aina", "Jasmine", "Suhaila", "Xin Yi", "Divya",
           "Alia", "Pei Shan", "Anisa", "Ling Ling", "Rohani"]
FIRST_M = ["Aiman", "Wei Jie", "Rajesh", "Haziq", "Kok Wai", "Arjun",
           "Faizal", "Jun Hao", "Suresh", "Amirul", "Zhi Wei", "Kumar"]
LAST_NAMES = ["Lim", "Tan", "Ong", "Wong", "Cheah", "Goh", "Lee",
              "Chong", "binti Ismail", "bin Abdullah",
              "a/p Subramaniam", "a/l Subramaniam", "Sim", "Yeoh",
              "Teoh", "Rahman", "Hassan"]
TIERS = ["Bronze"] * 55 + ["Silver"] * 27 + ["Gold"] * 13 + ["Platinum"] * 5
TIER_DISCOUNT = {"Bronze": 0.00, "Silver": 0.03,
                 "Gold": 0.07, "Platinum": 0.12}


def w(path):
    return open(os.path.join(OUT, path), "w", newline="", encoding="utf-8")


def rand_date(a: date, b: date) -> date:
    return a + timedelta(days=random.randint(0, (b - a).days))


ALL_DAYS = [START + timedelta(days=i) for i in range((END - START).days + 1)]

# ===================================================================
# HEADER-ONLY FILES - nothing new this year, but load_all.bat expects
# a file for every control file, and SKIP=1 then loads 0 rows.
# ===================================================================
with w("branch.csv") as f:
    csv.writer(f).writerow(["br_ID", "br_name", "br_address_line",
                            "br_city", "br_state", "br_postcode",
                            "br_phone", "br_email", "br_open_date"])
with w("staff.csv") as f:
    csv.writer(f).writerow(["st_ID", "br_ID", "st_first_name",
                            "st_last_name", "st_role", "st_position",
                            "st_address_line", "st_city", "st_state",
                            "st_postcode", "st_DOB", "st_gender",
                            "st_email", "st_phone", "st_hire_date",
                            "st_salary", "st_status"])
with w("product.csv") as f:
    csv.writer(f).writerow(["product_ID", "product_name", "product_brand",
                            "product_category", "product_desc",
                            "product_unit_price"])
with w("service.csv") as f:
    csv.writer(f).writerow(["serv_ID", "serv_name", "serv_category",
                            "serv_description", "serv_price"])
with w("branch_utils_category.csv") as f:
    csv.writer(f).writerow(["br_utils_ID", "util_name"])

# ===================================================================
# NEW SUPPLIERS
# ===================================================================
with w("supplier.csv") as f:
    c = csv.writer(f)
    c.writerow(["sup_ID", "sup_name", "sup_phone", "sup_email"])
    for row in NEW_SUPPLIERS:
        c.writerow(list(row))

# ===================================================================
# NEW CUSTOMERS - registering across 2025
# ===================================================================
N_CUSTOMERS = 3500
customers = []                  # (cus_ID, city, tier, reg_date)
cid = LAST["cus"]
CITY_SHARE = [("Kuala Lumpur", "Wilayah Persekutuan", 25),
              ("Petaling Jaya", "Selangor", 20),
              ("Johor Bahru", "Johor", 17),
              ("George Town", "Pulau Pinang", 13),
              ("Melaka", "Melaka", 10),
              ("Ipoh", "Perak", 15)]
city_pool = []
for cty, st, share in CITY_SHARE:
    city_pool += [(cty, st)] * share

with w("customer.csv") as f:
    c = csv.writer(f)
    c.writerow(["cus_ID", "cus_first_name", "cus_last_name", "cus_age",
                "cus_gender", "cus_phone", "cus_DOB", "cus_email",
                "cus_loyalty_tier", "cus_address_line", "cus_city",
                "cus_state", "cus_postcode", "cus_reg_date"])
    for _ in range(N_CUSTOMERS):
        cid += 1
        cty, st = random.choice(city_pool)
        reg = rand_date(START, END - timedelta(days=15))
        female = random.random() < 0.86
        fn = random.choice(FIRST_F if female else FIRST_M)
        ln = random.choice(LAST_NAMES)
        # at least 18 at registration, matching 2019-2024 (ages 18..61)
        try:
            youngest = date(reg.year - 18, reg.month, reg.day)
        except ValueError:                       # 29 February
            youngest = date(reg.year - 18, 2, 28)
        dob = rand_date(date(1965, 1, 1), youngest)
        age = reg.year - dob.year - ((reg.month, reg.day) < (dob.month, dob.day))
        tier = random.choice(TIERS)
        c.writerow([cid, fn, ln, age, "Female" if female else "Male",
                    f"01{random.randint(0, 9)}-{random.randint(1000000, 9999999)}",
                    dob, f"{fn.split()[0].lower()}{cid}@gmail.com", tier,
                    f"No. {random.randint(1, 300)}, Jalan {random.choice('ABCDEFG')}{random.randint(1, 20)}",
                    cty, st, f"{random.randint(10000, 99999)}", reg])
        customers.append((cid, cty, tier, reg))

# ---- the 32,000 existing customers, all eligible on every 2025 day --
OLD_CITY = [("Kuala Lumpur", 28), ("Petaling Jaya", 22),
            ("Johor Bahru", 19), ("George Town", 14),
            ("Melaka", 10), ("Ipoh", 7)]
old_pool = []
for cty, share in OLD_CITY:
    old_pool += [cty] * share
old_customers = [(oid, old_pool[oid % len(old_pool)],
                  TIERS[oid % len(TIERS)], date(2018, 1, 1))
                 for oid in range(1, LAST["cus"] + 1)]

ALL_CUST = old_customers + [(c[0], c[1], c[2], c[3]) for c in customers]
CUST_BY_CITY = {}
for rec in ALL_CUST:
    CUST_BY_CITY.setdefault(rec[1], []).append(rec)

# ===================================================================
# STAFF - all 114 reused. Branch layout as built in data\ and data2\.
# ===================================================================
EXIST_PER_BRANCH = {1: 26, 2: 22, 3: 18, 4: 16, 5: 14}
staff_by_branch = {b: [] for b in range(1, 7)}
_sid = 0
for br, n in EXIST_PER_BRANCH.items():
    for _ in range(n):
        _sid += 1
        staff_by_branch[br].append(_sid)
RESIGNED = {17, 48, 79}
for br in staff_by_branch:
    staff_by_branch[br] = [s for s in staff_by_branch[br] if s not in RESIGNED]
staff_by_branch[6] = list(range(97, 115))          # the Ipoh team

# ===================================================================
# ORDERS + ORDER_DETAIL
# ===================================================================
TARGET_ORDERS = 74000
total_weight = sum(day_weight(d) for d in ALL_DAYS)

order_id, det_id = LAST["order"], LAST["order_det"]
n_orders = n_lines = 0

fo = w("orders.csv")
fd = w("order_detail.csv")
co, cd = csv.writer(fo), csv.writer(fd)
co.writerow(["order_ID", "cus_ID", "br_ID", "st_ID", "order_date",
             "order_status"])
cd.writerow(["order_det_ID", "order_ID", "product_ID", "order_quantity",
             "order_unit_price", "order_discount", "order_tax"])

BRS = list(range(1, 7))
BW = [BRANCH_WEIGHT[b] for b in BRS]

for d in ALL_DAYS:
    todays = max(0, int(round(TARGET_ORDERS * day_weight(d) / total_weight
                              * random.uniform(0.88, 1.12))))
    mega = (d.month, d.day) in MEGA_SALE

    for _ in range(todays):
        br = random.choices(BRS, weights=BW)[0]
        city = BRANCH_CITY[br]
        # 76% of shoppers use the branch in their own city
        pool = CUST_BY_CITY[city] if (random.random() < 0.76 and
                                      city in CUST_BY_CITY) else ALL_CUST
        for _try in range(8):
            cus = random.choice(pool)
            if cus[3] <= d:
                break
        else:
            continue
        st = random.choice(staff_by_branch[br])
        r = random.random()
        status = "Completed" if r < 0.958 else (
            "Cancelled" if r < 0.991 else "Processing")

        order_id += 1
        co.writerow([order_id, cus[0], br, st, d, status])
        n_orders += 1

        tier_disc = TIER_DISCOUNT[cus[2]]
        promo = 0.15 if mega else (0.05 if random.random() < 0.12 else 0.0)
        for _line in range(random.choices([1, 2, 3, 4, 5],
                                          weights=[33, 31, 21, 10, 5])[0]):
            pid = random.choices(list(BASE_PRICE),
                                 weights=[PRODUCT_WEIGHT[p]
                                          for p in BASE_PRICE])[0]
            qty = random.choices([1, 2, 3], weights=[69, 25, 6])[0]
            unit = price_of(pid)
            gross = qty * unit
            disc = round(gross * (tier_disc + promo), 2)
            tax = round((gross - disc) * SST, 2)
            det_id += 1
            cd.writerow([det_id, order_id, pid, qty, f"{unit:.2f}",
                         f"{disc:.2f}", f"{tax:.2f}"])
            n_lines += 1
fo.close()
fd.close()

# ===================================================================
# RESERVATION + RESERVATION_DETAIL
# Slots 10:00-20:00 on a 15-minute grid, peaking 16:00-18:00.
# ===================================================================
TARGET_RES = 31500
HOUR_WEIGHT = {10: 6, 11: 8, 12: 7, 13: 6, 14: 9, 15: 11,
               16: 15, 17: 15, 18: 10, 19: 7}

res_id, rdet_id = LAST["res"], LAST["res_det"]
n_res = n_rdet = 0

fr = w("reservation.csv")
frd = w("reservation_detail.csv")
cr, crd = csv.writer(fr), csv.writer(frd)
cr.writerow(["res_ID", "cus_ID", "br_ID", "booking_date", "res_status"])
crd.writerow(["res_det_ID", "res_ID", "st_ID", "serv_ID", "start_time",
              "end_time", "serv_discount", "serv_tax"])

for d in ALL_DAYS:
    todays = max(0, int(round(TARGET_RES * day_weight(d) / total_weight
                              * random.uniform(0.85, 1.15))))
    for _ in range(todays):
        br = random.choices(BRS, weights=BW)[0]
        city = BRANCH_CITY[br]
        pool = CUST_BY_CITY[city] if (random.random() < 0.80 and
                                      city in CUST_BY_CITY) else ALL_CUST
        for _try in range(8):
            cus = random.choice(pool)
            if cus[3] <= d:
                break
        else:
            continue
        r = random.random()
        status = "Completed" if r < 0.912 else (
            "Cancelled" if r < 0.960 else
            ("No-Show" if r < 0.989 else "Confirmed"))

        res_id += 1
        cr.writerow([res_id, cus[0], br, d, status])
        n_res += 1

        tier_disc = TIER_DISCOUNT[cus[2]]
        hour = random.choices(list(HOUR_WEIGHT),
                              weights=list(HOUR_WEIGHT.values()))[0]
        cursor = hour * 60 + random.choice([0, 15, 30, 45])

        picks = [random.choice(MAIN_SERVICES)]
        if random.random() < 0.38:
            picks.append(random.choice(ADDON_SERVICES))
        for sv in picks:
            mins = SERV_MINUTES[sv]
            if cursor + mins > 20 * 60:
                break
            stt = f"{d} {cursor // 60:02d}:{cursor % 60:02d}:00"
            endm = cursor + mins
            ent = f"{d} {endm // 60:02d}:{endm % 60:02d}:00"
            # weekday off-peak keeps its extra 5% off
            extra = 0.05 if (d.weekday() < 5 and hour < 15) else 0.0
            price = serv_price_of(sv)
            disc = round(price * (tier_disc + extra), 2)
            tax = round((price - disc) * SST, 2)
            rdet_id += 1
            crd.writerow([rdet_id, res_id,
                          random.choice(staff_by_branch[br]), sv,
                          stt, ent, f"{disc:.2f}", f"{tax:.2f}"])
            n_rdet += 1
            cursor = endm
fr.close()
frd.close()

# ===================================================================
# PURCHASE - restocking from all 8 suppliers now, including the two
# that joined this year.
# ===================================================================
pur_id = LAST["purchase"]
n_pur = 0
with w("purchase.csv") as f:
    c = csv.writer(f)
    c.writerow(["purchase_ID", "product_ID", "br_ID", "sup_ID",
                "purchase_qty", "purchase_date", "purchase_unit_cost"])
    for d in ALL_DAYS:
        if d.weekday() > 4:                     # restock on weekdays
            continue
        for br in BRS:
            if random.random() > 0.85 * BRANCH_WEIGHT[br]:
                continue
            for _ in range(random.randint(2, 6)):
                pid = random.choice(list(BASE_PRICE))
                pur_id += 1
                c.writerow([pur_id, pid, br, random.randint(1, 8),
                            random.randint(40, 220), d,
                            f"{price_of(pid) * random.uniform(0.45, 0.55):.2f}"])
                n_pur += 1

# ===================================================================
# SALARY_PAYMENT - all 114 staff, every month.
# 4% cost-of-living rise on the 2024 levels, 11% EPF deduction,
# 13th-month bonus in December, Raya bonus in March (Raya is 31 Mar).
# ===================================================================
sal_id = LAST["sal_pay"]
n_sal = 0
SALARY = {}
for br, ids in staff_by_branch.items():
    for s in ids:
        SALARY[s] = random.uniform(1900, 6600) * 1.04

with w("salary_payment.csv") as f:
    c = csv.writer(f)
    c.writerow(["sal_pay_ID", "st_ID", "pay_period", "base_amount",
                "bonus_amount", "deduction_amount", "payment_date"])
    for m in range(1, 13):
        pay_day = date(2025, m, 25)
        for br, ids in staff_by_branch.items():
            for s in ids:
                base = round(SALARY[s] * random.uniform(0.99, 1.03), 2)
                bonus = 0.0
                if m == 12:
                    bonus += round(base, 2)             # 13th month
                if m == 3:
                    bonus += round(base * 0.35, 2)      # Raya, 31 Mar
                ded = round(base * 0.11, 2)
                sal_id += 1
                c.writerow([sal_id, s, f"2025-{m:02d}", f"{base:.2f}",
                            f"{bonus:.2f}", f"{ded:.2f}", pay_day])
                n_sal += 1

# ===================================================================
# BRANCH_EXPENSE - all 6 branches, all 12 months.
# 6% on 2023 levels (two more years of 3%), hot months push aircon up.
# ===================================================================
BASE_RENT = {1: 18500, 2: 14200, 3: 11800, 4: 9600, 5: 7400, 6: 8800}
exp_id = LAST["br_exp"]
n_exp = 0
INFL = 1.06
with w("branch_expense.csv") as f:
    c = csv.writer(f)
    c.writerow(["br_exp_ID", "br_ID", "br_utils_ID", "billing_period",
                "payment_amount", "payment_date"])
    for m in range(1, 13):
        pay_day = date(2025, m, 28)
        for br in BRS:
            size = BASE_RENT[br] / BASE_RENT[1]
            hot = 1.12 if m in (3, 4, 5, 6) else 1.0
            vals = {
                1: BASE_RENT[br] * INFL,
                2: 2400 * size * hot * INFL * random.uniform(.92, 1.08),
                3: 330 * size * INFL * random.uniform(.90, 1.10),
                4: 209 * INFL,
                5: 1650 * size * INFL * random.uniform(.75, 1.30),
                6: 410 * size * INFL * random.uniform(.95, 1.05),
            }
            for util, amt in vals.items():
                exp_id += 1
                c.writerow([exp_id, br, util, f"2025-{m:02d}",
                            f"{amt:.2f}", pay_day])
                n_exp += 1

# ===================================================================
print("data3 generated  (2025)")
print(f"  supplier.csv             {len(NEW_SUPPLIERS)}")
print(f"  customer.csv             {N_CUSTOMERS}")
print(f"  orders.csv               {n_orders}")
print(f"  order_detail.csv         {n_lines}")
print(f"  reservation.csv          {n_res}")
print(f"  reservation_detail.csv   {n_rdet}")
print(f"  purchase.csv             {n_pur}")
print(f"  salary_payment.csv       {n_sal}")
print(f"  branch_expense.csv       {n_exp}")
print("  branch / staff / product / service / branch_utils : header only")
print(f"  TOTAL transaction rows   "
      f"{n_orders + n_lines + n_res + n_rdet + n_pur + n_sal + n_exp}")
