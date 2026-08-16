"""
gen_data2.py
Generates the 2023-2024 expansion dataset for Glow Beauty.

    python gen_data2.py

Writes CSVs into this folder, named EXACTLY like the originals in
data\\ so the existing SQL*Loader control files load them unchanged:

    load_all.bat dwh <password> XE "c:\\...\\datawarehouseAnalysis\\data2"

Every .ctl uses APPEND and every ID continues from where data\\ stopped,
so nothing collides.

WHAT IT PRODUCES
    reference : 1 new branch, 18 staff for it, 5 products, 2 services,
                6,000 customers
    facts     : orders, order_detail, reservation, reservation_detail,
                purchase, salary_payment, branch_expense for 2023-2024

PATTERNS BAKED IN (see README_DATA2.md for the full list)
    - post-COVID growth continuing from 2022
    - the 6th branch opens 2023-03-01 and ramps up over its first year
    - branch size ranking KL > PJ > JB > George Town > Melaka > Ipoh
    - customers shop mostly at the branch in their own city
    - Sat/Sun peak, Monday trough, Q4 strong, Q3 weak
    - CNY / Hari Raya / Deepavali / Christmas run-ups, dates moving
      correctly between 2023 and 2024
    - 11.11 and 12.12 mega-sale spikes
    - 7 products get a price rise on 2023-01-01 (see
      99_price_increase_2023.sql) and every 2023+ line uses the new price
    - loyalty discounts Bronze 0 / Silver 3 / Gold 7 / Platinum 12 %
    - 6% SST on the discounted amount
    - no transaction before a customer registers or outside a staff
      member's employment window
"""
import csv
import math
import os
import random
from datetime import date, timedelta

random.seed(20232024)          # deterministic - re-runs give identical files
OUT = os.path.dirname(os.path.abspath(__file__))

# ===================================================================
# CONTINUATION POINTS - the last ID used in data\
# ===================================================================
LAST = dict(br=5, st=96, cus=26000, product=43, serv=16, sup=6,
            order=161470, order_det=349396, res=65110, res_det=88790,
            purchase=10615, sal_pay=3135, br_exp=1440)

START, END = date(2023, 1, 1), date(2024, 12, 31)
NEW_BRANCH_OPEN = date(2023, 3, 1)
SST = 0.06

# ===================================================================
# 1. NEW BRANCH  (br_ID 6)
# ===================================================================
NEW_BRANCH = dict(
    br_ID=6, br_name="Glow Beauty Ipoh",
    br_address_line="88, Jalan Sultan Idris Shah", br_city="Ipoh",
    br_state="Perak", br_postcode="30000", br_phone="05-2419900",
    br_email="ipoh@glowbeauty.com.my", br_open_date=NEW_BRANCH_OPEN)

# city -> (state, postcode prefix) for all six branches
BRANCH_CITY = {
    1: ("Kuala Lumpur",  "Wilayah Persekutuan"),
    2: ("Petaling Jaya", "Selangor"),
    3: ("Johor Bahru",   "Johor"),
    4: ("George Town",   "Pulau Pinang"),
    5: ("Melaka",        "Melaka"),
    6: ("Ipoh",          "Perak"),
}

# Relative pull of each branch. Matches the ranking in the 2019-2022
# data; Ipoh starts small and ramps up over its first year.
BRANCH_WEIGHT = {1: 1.00, 2: 0.81, 3: 0.67, 4: 0.50, 5: 0.37, 6: 0.34}

# ===================================================================
# 2. NEW PRODUCTS  (44-48) and SERVICES (17-18)
# ===================================================================
NEW_PRODUCTS = [
    (44, "Snail Mucin Repair Essence", "BotaniQ", "Facial Oil/Essence",
     "Nourishing essence for a healthy glow.", 68.00),
    (45, "Azelaic Acid Clarifying Serum", "DermaVita", "Serum",
     "Concentrated treatment serum for targeted skin concerns.", 95.00),
    (46, "Barrier Repair Cica Cream", "HydraLuxe", "Moisturizer",
     "Hydrating cream that strengthens the skin barrier.", 82.00),
    (47, "Mineral Sunscreen Stick SPF50", "SunGuard", "Sunscreen",
     "Broad spectrum UV protection for daily wear.", 52.00),
    (48, "Overnight Retinal Sleeping Mask", "PureGlow", "Face Mask",
     "Intensive weekly treatment mask.", 88.00),
]
NEW_SERVICES = [
    (17, "Microneedling Rejuvenation", "Anti Aging",
     "Advanced firming and rejuvenation treatment.", 380.00),
    (18, "Scalp Detox Add on", "Add on",
     "Optional enhancement added to a main treatment.", 45.00),
]

# ===================================================================
# 3. THE 2023 PRICE RISE - 7 products.
# Kept in step with 99_price_increase_2023.sql: every transaction from
# 2023-01-01 uses the NEW price, everything in data\ keeps the old one.
# That contrast is what makes SCD Type 2 visible.
# ===================================================================
PRICE_RISE_2023 = {
    4: (42.00, 48.00), 12: (89.00, 98.00), 15: (110.00, 125.00),
    16: (120.00, 135.00), 21: (95.00, 108.00), 23: (55.00, 62.00),
    30: (72.00, 82.00),
}

# ===================================================================
# 4. EXISTING CATALOGUE (price BEFORE the rise) - product_ID: price
# ===================================================================
BASE_PRICE = {
    1: 32, 2: 38, 3: 29, 4: 42, 5: 35, 6: 27, 7: 32, 8: 38, 9: 30,
    10: 45, 11: 40, 12: 89, 13: 75, 14: 68, 15: 110, 16: 120, 17: 85,
    18: 65, 19: 78, 20: 48, 21: 95, 22: 55, 23: 55, 24: 62, 25: 48,
    26: 58, 27: 38, 28: 45, 29: 34, 30: 72, 31: 48, 32: 68, 33: 58,
    34: 85, 35: 42, 36: 65, 37: 55, 38: 58, 39: 62, 40: 72, 41: 22,
    42: 25, 43: 18,
}
for pid, _b, _br, _c, _d, price in NEW_PRODUCTS:
    BASE_PRICE[pid] = price

SERV_PRICE = {
    1: 75, 2: 60, 3: 110, 4: 95, 5: 220, 6: 165, 7: 280, 8: 320,
    9: 250, 10: 150, 11: 180, 12: 130, 13: 160, 14: 35, 15: 55, 16: 40,
    17: 380, 18: 45,
}
# standard slot length in minutes, by service
SERV_MINUTES = {
    1: 60, 2: 45, 3: 75, 4: 60, 5: 75, 6: 75, 7: 90, 8: 90, 9: 75,
    10: 60, 11: 75, 12: 60, 13: 75, 14: 15, 15: 30, 16: 30,
    17: 90, 18: 20,
}
ADDON_SERVICES = [14, 15, 16, 18]
MAIN_SERVICES = [s for s in SERV_PRICE if s not in ADDON_SERVICES]


def price_of(pid: int, d: date) -> float:
    """Unit price on a given date, honouring the 2023 rise."""
    if pid in PRICE_RISE_2023 and d >= date(2023, 1, 1):
        return PRICE_RISE_2023[pid][1]
    return float(BASE_PRICE[pid])


# Products launched in 2023 are not on the shelf before then
def product_available(pid: int, d: date) -> bool:
    return pid < 44 or d >= date(2023, 2, 1)


def service_available(sid: int, d: date) -> bool:
    return sid < 17 or d >= date(2023, 4, 1)


# Cheaper items shift more units; new launches get a small novelty push
PRODUCT_WEIGHT = {}
for pid, price in BASE_PRICE.items():
    PRODUCT_WEIGHT[pid] = (60.0 / price) ** 0.45 * random.uniform(0.75, 1.3)
for pid, *_ in NEW_PRODUCTS:
    PRODUCT_WEIGHT[pid] *= 1.25

# ===================================================================
# 5. SEASONALITY
# ===================================================================
WEEKDAY_MULT = {0: 0.80, 1: 0.92, 2: 0.95, 3: 1.00, 4: 1.12,
                5: 1.42, 6: 1.25}          # Mon..Sun
QUARTER_MULT = {1: 1.00, 2: 1.05, 3: 0.90, 4: 1.15}

# (festival date, peak multiplier, run-up window in days)
FESTIVALS = [
    (date(2023, 1, 22), 1.75, 18),   # Chinese New Year
    (date(2023, 4, 22), 1.85, 25),   # Hari Raya Aidilfitri
    (date(2023, 11, 12), 1.45, 14),  # Deepavali
    (date(2023, 12, 25), 1.40, 16),  # Christmas
    (date(2024, 2, 10), 1.75, 18),   # CNY - 19 days later than 2023
    (date(2024, 4, 10), 1.85, 25),   # Raya - 12 days EARLIER than 2023
    (date(2024, 10, 31), 1.45, 14),  # Deepavali
    (date(2024, 12, 25), 1.40, 16),  # Christmas
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


def branch_weight(br: int, d: date) -> float:
    """Ipoh opens 2023-03-01 and takes ~12 months to reach full pull."""
    if br != 6:
        return BRANCH_WEIGHT[br]
    if d < NEW_BRANCH_OPEN:
        return 0.0
    months = (d.year - 2023) * 12 + d.month - 3
    return BRANCH_WEIGHT[6] * min(1.0, 0.35 + 0.055 * months)


# ===================================================================
# 6. NAME POOLS - same flavour as the 2019-2022 data
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
ROLES = [("Branch Manager", "Manager", 5800, 6600),
         ("Senior Therapist", "Lead", 3600, 4400),
         ("Beauty Therapist", "Senior", 2300, 2900),
         ("Beauty Therapist", "Junior", 1900, 2400),
         ("Sales Assistant", "Junior", 1900, 2400),
         ("Receptionist", "Junior", 2100, 2500),
         ("Cashier", "Junior", 1900, 2300)]
TIERS = ["Bronze"] * 55 + ["Silver"] * 27 + ["Gold"] * 13 + ["Platinum"] * 5
TIER_DISCOUNT = {"Bronze": 0.00, "Silver": 0.03,
                 "Gold": 0.07, "Platinum": 0.12}


def w(path):
    return open(os.path.join(OUT, path), "w", newline="", encoding="utf-8")


def rand_date(a: date, b: date) -> date:
    return a + timedelta(days=random.randint(0, (b - a).days))


ALL_DAYS = [START + timedelta(days=i) for i in range((END - START).days + 1)]

# ===================================================================
# WRITE: branch / product / service / supplier / utils
# ===================================================================
with w("branch.csv") as f:
    c = csv.writer(f)
    c.writerow(["br_ID", "br_name", "br_address_line", "br_city",
                "br_state", "br_postcode", "br_phone", "br_email",
                "br_open_date"])
    b = NEW_BRANCH
    c.writerow([b["br_ID"], b["br_name"], b["br_address_line"],
                b["br_city"], b["br_state"], b["br_postcode"],
                b["br_phone"], b["br_email"], b["br_open_date"]])

with w("product.csv") as f:
    c = csv.writer(f)
    c.writerow(["product_ID", "product_name", "product_brand",
                "product_category", "product_desc", "product_unit_price"])
    for row in NEW_PRODUCTS:
        c.writerow([row[0], row[1], row[2], row[3], row[4],
                    f"{row[5]:.2f}"])

with w("service.csv") as f:
    c = csv.writer(f)
    c.writerow(["serv_ID", "serv_name", "serv_category",
                "serv_description", "serv_price"])
    for row in NEW_SERVICES:
        c.writerow([row[0], row[1], row[2], row[3], f"{row[4]:.2f}"])

# No new suppliers or utility categories - header only, so load_all.bat
# still finds a file and loads 0 rows instead of failing.
with w("supplier.csv") as f:
    csv.writer(f).writerow(["sup_ID", "sup_name", "sup_phone", "sup_email"])
with w("branch_utils_category.csv") as f:
    csv.writer(f).writerow(["br_utils_ID", "util_name"])

# ===================================================================
# WRITE: staff for the new branch (hired 2 weeks before opening)
# ===================================================================
new_staff = []
sid = LAST["st"]
plan = [ROLES[0]] + [ROLES[1]] * 2 + [ROLES[2]] * 4 + [ROLES[3]] * 5 + \
       [ROLES[4]] * 3 + [ROLES[5]] * 2 + [ROLES[6]] * 1
hire = NEW_BRANCH_OPEN - timedelta(days=14)
with w("staff.csv") as f:
    c = csv.writer(f)
    c.writerow(["st_ID", "br_ID", "st_first_name", "st_last_name",
                "st_role", "st_position", "st_address_line", "st_city",
                "st_state", "st_postcode", "st_DOB", "st_gender",
                "st_email", "st_phone", "st_hire_date", "st_salary",
                "st_status"])
    for role, pos, lo, hi in plan:
        sid += 1
        female = random.random() < 0.79
        fn = random.choice(FIRST_F if female else FIRST_M)
        ln = random.choice(LAST_NAMES)
        dob = rand_date(date(1978, 1, 1), date(2002, 12, 31))
        sal = round(random.uniform(lo, hi), 2)
        c.writerow([sid, 6, fn, ln, role, pos,
                    f"No. {random.randint(1, 250)}, Jalan {random.randint(1, 20)}/{random.randint(1, 30)}",
                    "Ipoh", "Perak", "30000", dob,
                    "Female" if female else "Male",
                    f"{fn.split()[0].lower()}.{sid}@glowbeauty.com.my",
                    f"01{random.randint(0, 9)}-{random.randint(1000000, 9999999)}",
                    hire, f"{sal:.2f}", "Active"])
        new_staff.append(dict(st_ID=sid, br_ID=6, hire=hire, salary=sal))

# ===================================================================
# WRITE: new customers
# Registration is spread across 2023-24 and skews toward Ipoh once the
# 6th branch opens - a new outlet brings in local sign-ups.
# ===================================================================
N_CUSTOMERS = 6000
customers = []                  # (cus_ID, city, state, tier, reg_date)
cid = LAST["cus"]
CITY_SHARE = [("Kuala Lumpur", "Wilayah Persekutuan", 26),
              ("Petaling Jaya", "Selangor", 21),
              ("Johor Bahru", "Johor", 17),
              ("George Town", "Pulau Pinang", 13),
              ("Melaka", "Melaka", 9),
              ("Ipoh", "Perak", 14)]
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
        reg = rand_date(START, END - timedelta(days=20))
        # Ipoh sign-ups only start once that branch is open
        if cty == "Ipoh" and reg < NEW_BRANCH_OPEN:
            reg = rand_date(NEW_BRANCH_OPEN, END - timedelta(days=20))
        female = random.random() < 0.86
        fn = random.choice(FIRST_F if female else FIRST_M)
        ln = random.choice(LAST_NAMES)
        # Must be at least 18 at registration, matching the 2019-2022
        # customers (whose ages run 18..61). Anything younger would put
        # an "Under 18" band into customer_dim that the original data
        # never produces.
        try:
            youngest = date(reg.year - 18, reg.month, reg.day)
        except ValueError:                       # 29 February
            youngest = date(reg.year - 18, 2, 28)
        dob = rand_date(date(1963, 1, 1), youngest)
        age = reg.year - dob.year - ((reg.month, reg.day) < (dob.month, dob.day))
        tier = random.choice(TIERS)
        c.writerow([cid, fn, ln, age, "Female" if female else "Male",
                    f"01{random.randint(0, 9)}-{random.randint(1000000, 9999999)}",
                    dob, f"{fn.split()[0].lower()}{cid}@gmail.com", tier,
                    f"No. {random.randint(1, 300)}, Jalan {random.choice('ABCDEFG')}{random.randint(1, 20)}",
                    cty, st, f"{random.randint(10000, 99999)}", reg])
        customers.append((cid, cty, st, tier, reg))

# Existing 26,000 customers are reusable too - they all registered
# 2018-2022, so they are eligible on every day of 2023-24. Their city
# mix matches the original five-state spread.
OLD_CITY = [("Kuala Lumpur", "Wilayah Persekutuan", 30),
            ("Petaling Jaya", "Selangor", 24),
            ("Johor Bahru", "Johor", 20),
            ("George Town", "Pulau Pinang", 15),
            ("Melaka", "Melaka", 11)]
old_pool = []
for cty, st, share in OLD_CITY:
    old_pool += [(cty, st)] * share
old_customers = []
for oid in range(1, LAST["cus"] + 1):
    cty, st = old_pool[oid % len(old_pool)]
    old_customers.append((oid, cty, st, TIERS[oid % len(TIERS)],
                          date(2018, 1, 1)))

ALL_CUST = old_customers + customers
CUST_BY_CITY = {}
for rec in ALL_CUST:
    CUST_BY_CITY.setdefault(rec[1], []).append(rec)

# ===================================================================
# Existing staff: rebuilt from the known 2019-2022 layout so orders can
# be attributed to a real person at the transacting branch.
# ===================================================================
EXIST_PER_BRANCH = {1: 26, 2: 22, 3: 18, 4: 16, 5: 14}
staff_by_branch = {b: [] for b in range(1, 7)}
_sid = 0
for br, n in EXIST_PER_BRANCH.items():
    for _ in range(n):
        _sid += 1
        staff_by_branch[br].append(_sid)
RESIGNED = {17, 48, 79}                      # the 3 Resigned in data\
for br in staff_by_branch:
    staff_by_branch[br] = [s for s in staff_by_branch[br]
                           if s not in RESIGNED]
staff_by_branch[6] = [s["st_ID"] for s in new_staff]

# ===================================================================
# ORDERS + ORDER_DETAIL
# ===================================================================
TARGET_ORDERS = {2023: 62000, 2024: 68000}
weights_by_year = {y: sum(day_weight(d) for d in ALL_DAYS if d.year == y)
                   for y in (2023, 2024)}

order_id, det_id = LAST["order"], LAST["order_det"]
n_orders = n_lines = 0

fo = w("orders.csv")
fd = w("order_detail.csv")
co, cd = csv.writer(fo), csv.writer(fd)
co.writerow(["order_ID", "cus_ID", "br_ID", "st_ID", "order_date",
             "order_status"])
cd.writerow(["order_det_ID", "order_ID", "product_ID", "order_quantity",
             "order_unit_price", "order_discount", "order_tax"])

for d in ALL_DAYS:
    share = day_weight(d) / weights_by_year[d.year]
    todays = max(0, int(round(TARGET_ORDERS[d.year] * share *
                              random.uniform(0.88, 1.12))))
    brs = [b for b in range(1, 7) if branch_weight(b, d) > 0]
    bw = [branch_weight(b, d) for b in brs]
    mega = (d.month, d.day) in MEGA_SALE

    for _ in range(todays):
        br = random.choices(brs, weights=bw)[0]
        city = BRANCH_CITY[br][0]
        # 76% of shoppers use the branch in their own city
        pool = CUST_BY_CITY[city] if (random.random() < 0.76 and
                                      city in CUST_BY_CITY) else ALL_CUST
        for _try in range(8):
            cus = random.choice(pool)
            if cus[4] <= d:
                break
        else:
            continue
        st = random.choice(staff_by_branch[br])
        r = random.random()
        status = "Completed" if r < 0.956 else (
            "Cancelled" if r < 0.990 else "Processing")

        order_id += 1
        co.writerow([order_id, cus[0], br, st, d, status])
        n_orders += 1

        tier_disc = TIER_DISCOUNT[cus[3]]
        promo = 0.15 if mega else (0.05 if random.random() < 0.12 else 0.0)
        for _line in range(random.choices([1, 2, 3, 4, 5],
                                          weights=[34, 31, 20, 10, 5])[0]):
            pid = random.choices(
                [p for p in BASE_PRICE if product_available(p, d)],
                weights=[PRODUCT_WEIGHT[p] for p in BASE_PRICE
                         if product_available(p, d)])[0]
            qty = random.choices([1, 2, 3], weights=[70, 24, 6])[0]
            unit = price_of(pid, d)
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
TARGET_RES = {2023: 26000, 2024: 29000}
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

therapists = {b: [s for s in staff_by_branch[b]] for b in staff_by_branch}

for d in ALL_DAYS:
    share = day_weight(d) / weights_by_year[d.year]
    todays = max(0, int(round(TARGET_RES[d.year] * share *
                              random.uniform(0.85, 1.15))))
    brs = [b for b in range(1, 7) if branch_weight(b, d) > 0]
    bw = [branch_weight(b, d) for b in brs]

    for _ in range(todays):
        br = random.choices(brs, weights=bw)[0]
        city = BRANCH_CITY[br][0]
        pool = CUST_BY_CITY[city] if (random.random() < 0.80 and
                                      city in CUST_BY_CITY) else ALL_CUST
        for _try in range(8):
            cus = random.choice(pool)
            if cus[4] <= d:
                break
        else:
            continue
        r = random.random()
        status = "Completed" if r < 0.907 else (
            "Cancelled" if r < 0.958 else
            ("No-Show" if r < 0.988 else "Confirmed"))

        res_id += 1
        cr.writerow([res_id, cus[0], br, d, status])
        n_res += 1

        tier_disc = TIER_DISCOUNT[cus[3]]
        hour = random.choices(list(HOUR_WEIGHT), weights=list(
            HOUR_WEIGHT.values()))[0]
        minute = random.choice([0, 15, 30, 45])
        cursor = hour * 60 + minute

        picks = [random.choice([s for s in MAIN_SERVICES
                                if service_available(s, d)])]
        if random.random() < 0.36:
            picks.append(random.choice([s for s in ADDON_SERVICES
                                        if service_available(s, d)]))
        for sv in picks:
            mins = SERV_MINUTES[sv]
            if cursor + mins > 20 * 60:
                break
            stt = f"{d} {cursor // 60:02d}:{cursor % 60:02d}:00"
            endm = cursor + mins
            ent = f"{d} {endm // 60:02d}:{endm % 60:02d}:00"
            # weekday off-peak gets an extra 5% off, as in 2019-2022
            extra = 0.05 if (d.weekday() < 5 and hour < 15) else 0.0
            price = SERV_PRICE[sv]
            disc = round(price * (tier_disc + extra), 2)
            tax = round((price - disc) * SST, 2)
            rdet_id += 1
            crd.writerow([rdet_id, res_id, random.choice(therapists[br]),
                          sv, stt, ent, f"{disc:.2f}", f"{tax:.2f}"])
            n_rdet += 1
            cursor = endm
fr.close()
frd.close()

# ===================================================================
# PURCHASE - restocking. Bigger branches restock more often.
# Cost sits at roughly half the shelf price.
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
        for br in range(1, 7):
            bwt = branch_weight(br, d)
            if bwt == 0:
                continue
            if random.random() > 0.85 * bwt:
                continue
            for _ in range(random.randint(2, 6)):
                pid = random.choice([p for p in BASE_PRICE
                                     if product_available(p, d)])
                pur_id += 1
                c.writerow([pur_id, pid, br, random.randint(1, 6),
                            random.randint(40, 220), d,
                            f"{price_of(pid, d) * random.uniform(0.45, 0.55):.2f}"])
                n_pur += 1

# ===================================================================
# SALARY_PAYMENT - one row per active staff member per month.
# Deduction is 11% EPF. December carries a 13th-month bonus and the
# month before Hari Raya carries a festive bonus.
# ===================================================================
sal_id = LAST["sal_pay"]
n_sal = 0
EXIST_SALARY = {}
for br, ids in staff_by_branch.items():
    if br == 6:
        continue
    for s in ids:
        EXIST_SALARY[s] = random.uniform(1900, 6600)
for s in new_staff:
    EXIST_SALARY[s["st_ID"]] = s["salary"]
RAYA_BONUS_MONTH = {2023: 4, 2024: 4}

with w("salary_payment.csv") as f:
    c = csv.writer(f)
    c.writerow(["sal_pay_ID", "st_ID", "pay_period", "base_amount",
                "bonus_amount", "deduction_amount", "payment_date"])
    for y in (2023, 2024):
        for m in range(1, 13):
            pay_day = date(y, m, 25)
            for br, ids in staff_by_branch.items():
                for s in ids:
                    if br == 6 and pay_day < new_staff[0]["hire"]:
                        continue
                    base = round(EXIST_SALARY[s] * random.uniform(0.99, 1.03), 2)
                    bonus = 0.0
                    if m == 12:
                        bonus += round(base, 2)                 # 13th month
                    if m == RAYA_BONUS_MONTH[y]:
                        bonus += round(base * 0.35, 2)          # Raya
                    ded = round(base * 0.11, 2)
                    sal_id += 1
                    c.writerow([sal_id, s, f"{y}-{m:02d}", f"{base:.2f}",
                                f"{bonus:.2f}", f"{ded:.2f}", pay_day])
                    n_sal += 1

# ===================================================================
# BRANCH_EXPENSE - one row per branch per utility per month.
# Rent scales with branch size; electricity and water drift with the
# season; Ipoh only bills from the month it opens.
# ===================================================================
BASE_RENT = {1: 18500, 2: 14200, 3: 11800, 4: 9600, 5: 7400, 6: 8800}
exp_id = LAST["br_exp"]
n_exp = 0
with w("branch_expense.csv") as f:
    c = csv.writer(f)
    c.writerow(["br_exp_ID", "br_ID", "br_utils_ID", "billing_period",
                "payment_amount", "payment_date"])
    for y in (2023, 2024):
        for m in range(1, 13):
            pay_day = date(y, m, 28)
            infl = 1.0 + 0.03 * (y - 2023)              # 3% a year
            for br in range(1, 7):
                if br == 6 and date(y, m, 1) < NEW_BRANCH_OPEN.replace(day=1):
                    continue
                size = BASE_RENT[br] / BASE_RENT[1]
                hot = 1.12 if m in (3, 4, 5, 6) else 1.0   # hotter = more aircon
                vals = {
                    1: BASE_RENT[br] * infl,
                    2: 2400 * size * hot * infl * random.uniform(.92, 1.08),
                    3: 330 * size * infl * random.uniform(.90, 1.10),
                    4: 209 * infl,
                    5: 1650 * size * infl * random.uniform(.75, 1.30),
                    6: 410 * size * infl * random.uniform(.95, 1.05),
                }
                for util, amt in vals.items():
                    exp_id += 1
                    c.writerow([exp_id, br, util, f"{y}-{m:02d}",
                                f"{amt:.2f}", pay_day])
                    n_exp += 1

# ===================================================================
print("data2 generated")
print(f"  branch.csv               1")
print(f"  staff.csv                {len(new_staff)}")
print(f"  product.csv              {len(NEW_PRODUCTS)}")
print(f"  service.csv              {len(NEW_SERVICES)}")
print(f"  customer.csv             {N_CUSTOMERS}")
print(f"  orders.csv               {n_orders}")
print(f"  order_detail.csv         {n_lines}")
print(f"  reservation.csv          {n_res}")
print(f"  reservation_detail.csv   {n_rdet}")
print(f"  purchase.csv             {n_pur}")
print(f"  salary_payment.csv       {n_sal}")
print(f"  branch_expense.csv       {n_exp}")
print(f"  TOTAL transaction rows   "
      f"{n_orders + n_lines + n_res + n_rdet + n_pur + n_sal + n_exp}")
