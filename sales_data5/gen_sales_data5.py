#!/usr/bin/env python3
"""
gen_sales_data5.py - generates the WHOLE Glow Beauty operational history
(2019-01-01 .. 2025-12-31, 17 branches) into three load folders:

    sales_data5\\data19_23   2019-2023   initial load
    sales_data5\\data24      2024        subsequent load 1 (+ 4 branches, 2024-01-01 price rise)
    sales_data5\\data25      2025        subsequent load 2 (+ men's line, supplier 8, 2025-01-01 prices)

REVISION 5 of the dataset - a new world, NOT row-compatible with sales_data3
(IDs start at 1 in both: never load two revisions into the same OLTP).

One world model, one seed, one run:   python gen_sales_data5.py
Verification only (re-reads the CSVs): python gen_sales_data5.py --verify

Every folder carries the same 13 file names and byte-identical headers as
sales_data3, so the SQL*Loader control files (all APPEND) load any folder
unchanged. Folders that add no rows to a reference table get a header-only
file. IDs start at 1 in data19_23 and continue across folders.

Built-in patterns (see README.md in this folder for the full story):
  - Petaling Jaya is the top-revenue branch every year (weight 1.0, and the
    e-commerce fulfilment hub from 2022)
  - Ipoh (Perak) buys everything from an expensive Perak-only supplier and has
    the lowest demand: marginally profitable 2019-2023, loss-making 2024-2025
  - 2022 "we went online": product demand x1.38, cross-city orders 15 % -> 40 %,
    registrations +40 %, PJ hub x1.25; in-salon reservations grow only modestly
  - 2025 "men's market": HIM Essentials 6-SKU men's line + 2 new face masks
    launched 2025-01-01, 35 % of new registrations male, demand x1.85
  - 4 new branches open 2024-01-01 (Seremban, Kuantan, Subang Jaya, Bukit Jalil)
  - price eras 2024-01-01 (8 products) and 2025-01-01 (8 products, 6 services;
    products 4 and 16 rise twice -> three SCD2 versions)
  - quarterly seasonality: CNY / Valentine's (Q1), Raya / Mother's Day / 6.6 (Q2),
    weak Q3 + Merdeka week + 9.9, Deepavali / 10.10 / 11.11 / 12.12 / Christmas (Q4);
    national public holidays = salon half-day
  - Malaysian COVID timeline (MCO 1.0 / CMCO / RMCO / MCO 2.0 / FMCO / reopening /
    endemic), salons closed = ZERO reservations, staff resignations in the two
    lockdown waves, pay cuts, EPF 11 -> 7 -> 9 -> 11 %, rent rebates
  - purchases restock what sold; salaries monthly with Raya / December bonuses;
    six utility categories per branch per month
The --verify pass re-reads every CSV, checks FKs / price eras / tax / double
bookings / folder routing, and prints the row counts, revenue, P&L per branch
per year and the pattern checks (PJ rank, Ipoh sign, men's share, cross-city %).
"""
import csv
import math
import os
import random
import sys
from bisect import bisect_right
from collections import defaultdict
from datetime import date, timedelta

SEED = 20192025
ROOT = os.path.dirname(os.path.abspath(__file__))

FOLDERS = [
    ("data19_23", date(2019, 1, 1), date(2023, 12, 31)),
    ("data24", date(2024, 1, 1), date(2024, 12, 31)),
    ("data25", date(2025, 1, 1), date(2025, 12, 31)),
]
START, END = FOLDERS[0][1], FOLDERS[-1][2]


def folder_of(d):
    """Folder that owns a date. Anything before 2019 (early customer
    registrations, staff hired when a branch opened) belongs to the first."""
    for name, a, b in FOLDERS:
        if d <= b:
            return name
    return FOLDERS[-1][0]


def folder_start(name):
    return next(a for n, a, b in FOLDERS if n == name)


# ===================================================================
# BRANCHES  (id, name, address, city, state, postcode, phone, email,
#            open_date, weight vs PJ, base rent 2019, headcount)
#
# The KL branches sit in the FEDERAL TERRITORY. Gombak does NOT - the
# real Gombak district is Selangor - so it is a Selangor branch here,
# which leaves Selangor with 7 shops and the Federal Territory with 4.
# ===================================================================
FEDERAL_TERRITORY = "Federal Territory of Kuala Lumpur"
BRANCHES = [
    (1, "Glow Beauty Kuala Lumpur", "Lot 3-12, Jalan Bukit Bintang", "Kuala Lumpur",
     FEDERAL_TERRITORY, "55100", "03-21445566", "kl@glowbeauty.com.my", date(2016, 3, 15), 0.90, 12950, 22),
    (2, "Glow Beauty Petaling Jaya", "G-08, Jalan SS2/24", "Petaling Jaya",
     "Selangor", "47300", "03-78765432", "pj@glowbeauty.com.my", date(2016, 9, 1), 1.00, 9950, 24),
    (3, "Glow Beauty Johor Bahru", "No. 22, Jalan Molek 1/29", "Johor Bahru",
     "Johor", "81100", "07-3559988", "jb@glowbeauty.com.my", date(2017, 6, 20), 0.68, 8250, 18),
    (4, "Glow Beauty George Town", "45, Lebuh Campbell", "George Town",
     "Pulau Pinang", "10100", "04-2618899", "penang@glowbeauty.com.my", date(2018, 1, 10), 0.50, 6700, 15),
    (5, "Glow Beauty Melaka", "12, Jalan Merdeka, Bandar Hilir", "Melaka",
     "Melaka", "75000", "06-2823344", "melaka@glowbeauty.com.my", date(2018, 8, 5), 0.37, 5200, 13),
    (6, "Glow Beauty Shah Alam", "No. 12, Jalan Tengku Ampuan Zabedah 9/C, Seksyen 9", "Shah Alam",
     "Selangor", "40100", "03-55108822", "shahalam@glowbeauty.com.my", date(2016, 11, 12), 0.62, 6850, 17),
    (7, "Glow Beauty Klang", "Lot G-21, Jalan Langat, Bandar Bukit Tinggi 2", "Klang",
     "Selangor", "41200", "03-33262277", "klang@glowbeauty.com.my", date(2017, 3, 18), 0.55, 5900, 16),
    (8, "Glow Beauty Puchong", "No. 8, Jalan Puteri 1/2, Bandar Puteri Puchong", "Puchong",
     "Selangor", "47100", "03-80605511", "puchong@glowbeauty.com.my", date(2016, 6, 25), 0.58, 6450, 16),
    (9, "Glow Beauty Selayang", "No. 33, Jalan Selayang Utama, Selayang Baru", "Selayang",
     "Selangor", "68100", "03-61364433", "selayang@glowbeauty.com.my", date(2017, 5, 20), 0.40, 5050, 12),
    (10, "Glow Beauty Setapak", "No. 27, Jalan Genting Klang, Setapak", "Setapak",
     FEDERAL_TERRITORY, "53300", "03-40214477", "setapak@glowbeauty.com.my", date(2016, 8, 14), 0.50, 6250, 15),
    (11, "Glow Beauty Wangsa Maju", "Lot 2-18, Jalan Wangsa Delima 5, Wangsa Maju", "Wangsa Maju",
     FEDERAL_TERRITORY, "53300", "03-41429988", "wangsamaju@glowbeauty.com.my", date(2017, 1, 21), 0.48, 6000, 14),
    (12, "Glow Beauty Gombak", "No. 15, Jalan Gombak, Batu 5", "Gombak",
     "Selangor", "53100", "03-40235566", "gombak@glowbeauty.com.my", date(2017, 7, 8), 0.38, 4850, 12),
    # Ipoh: open from the start of the history, small team, low demand, expensive local supplier
    (13, "Glow Beauty Ipoh", "88, Jalan Sultan Idris Shah", "Ipoh",
     "Perak", "30000", "05-2419900", "ipoh@glowbeauty.com.my", date(2019, 1, 15), 0.38, 3300, 8),
    # the 2024 expansion (shipped in data24)
    (14, "Glow Beauty Seremban", "No. 10, Jalan Dato Bandar Tunggal", "Seremban",
     "Negeri Sembilan", "70000", "06-7623344", "seremban@glowbeauty.com.my", date(2024, 1, 1), 0.45, 5400, 15),
    (15, "Glow Beauty Kuantan", "Lot 12, Jalan Tun Ismail", "Kuantan",
     "Pahang", "25000", "09-5158822", "kuantan@glowbeauty.com.my", date(2024, 1, 1), 0.42, 5100, 14),
    (16, "Glow Beauty Subang Jaya", "No. 5, Jalan SS15/4D", "Subang Jaya",
     "Selangor", "47500", "03-56339911", "subang@glowbeauty.com.my", date(2024, 1, 1), 0.58, 7300, 16),
    (17, "Glow Beauty Bukit Jalil", "L1-08, Jalan Jalil Perkasa 1", "Bukit Jalil",
     FEDERAL_TERRITORY, "57000", "03-89965533", "bukitjalil@glowbeauty.com.my", date(2024, 1, 1), 0.52, 7000, 16),
]
PJ = 2
IPOH = 13
NEW_BRANCHES = (14, 15, 16, 17)
NEW_BR_OPEN = date(2024, 1, 1)
# ramp-up after opening: weight * min(1, start + step * months_open)
RAMP = {13: (0.82, 0.025), 14: (0.35, 0.055), 15: (0.35, 0.055), 16: (0.35, 0.055), 17: (0.35, 0.055)}
BR = {b[0]: dict(id=b[0], name=b[1], addr=b[2], city=b[3], state=b[4], postcode=b[5],
                 phone=b[6], email=b[7], open=b[8], weight=b[9], rent=b[10], headcount=b[11])
      for b in BRANCHES}
BR_IDS = sorted(BR)
KV_STATES = ("Selangor", FEDERAL_TERRITORY)

# realistic postcodes per city for customers (branch postcode + neighbours)
CITY_POSTCODES = {
    "Kuala Lumpur": ["50000", "50450", "50480", "55100", "55200", "56000", "57000", "58000", "59000", "59200"],
    "Petaling Jaya": ["46000", "46050", "46100", "46200", "46300", "47300", "47301", "47400", "47800", "47810"],
    "Johor Bahru": ["80000", "80100", "80200", "80300", "81100", "81200", "81300", "80350"],
    "George Town": ["10000", "10050", "10100", "10150", "10200", "10250", "10300", "10350", "10400", "10450"],
    "Melaka": ["75000", "75050", "75100", "75150", "75200", "75250", "75300", "75350"],
    "Shah Alam": ["40000", "40100", "40150", "40160", "40170", "40200", "40300", "40400", "40450", "40460"],
    "Klang": ["41000", "41050", "41100", "41150", "41200", "41250", "41300", "42100"],
    "Puchong": ["47100", "47110", "47120", "47130", "47140", "47150", "47160", "47170", "47180", "47190"],
    "Selayang": ["68100", "68000", "68000", "68100"],
    "Setapak": ["53000", "53100", "53200", "53300"],
    "Wangsa Maju": ["53300", "53100", "53200"],
    "Gombak": ["53100", "53000", "68100"],
    "Ipoh": ["30000", "30010", "30020", "30100", "30200", "30250", "30300", "30350", "31350", "31400"],
    "Seremban": ["70000", "70100", "70200", "70300", "70400", "70450", "70500"],
    "Kuantan": ["25000", "25050", "25100", "25150", "25200", "25250", "25300", "26060"],
    "Subang Jaya": ["47500", "47600", "47610", "47620", "47630", "47650"],
    "Bukit Jalil": ["57000", "57100", "58200"],
    # satellite towns - no branch of their own
    "Kajang": ["43000", "43100", "43200", "43300"],
    "Bangi": ["43650", "43600"],
    "Cyberjaya": ["63000", "63100"],
    "Rawang": ["48000", "48010", "48020"],
    "Ampang": ["68000", "55100"],
    "Sungai Buloh": ["47000", "47810", "47820"],
    "Kepong": ["52100", "52000", "51200"],
    "Kulai": ["81000", "81030"],
    "Butterworth": ["12000", "12100", "12200", "13700"],
    "Alor Gajah": ["78000", "78100"],
    "Taiping": ["34000", "34600", "34700"],
    "Nilai": ["71800", "71760"],
    "Temerloh": ["28000", "28400"],
}


# ===================================================================
# SATELLITE TOWNS - real places with customers but NO branch of their
# own. A customer here still belongs to (and shops at) the branch listed
# against them, so in the warehouse these towns read as demand nobody
# serves locally - exactly the case an expansion report has to find.
# Weighted towards Selangor; every other state gets one too, so the
# state-level view is not blind to them.
# ===================================================================
SATELLITES = {
    # --- Selangor (the heaviest, by design) ---
    2:  [("Sungai Buloh", "Selangor")],                            # Petaling Jaya
    6:  [("Sungai Buloh", "Selangor")],                            # Shah Alam
    7:  [("Sungai Buloh", "Selangor")],                            # Klang
    8:  [("Kajang", "Selangor"), ("Bangi", "Selangor"),
         ("Cyberjaya", "Selangor")],                               # Puchong
    9:  [("Rawang", "Selangor"), ("Sungai Buloh", "Selangor")],     # Selayang
    12: [("Rawang", "Selangor"), ("Ampang", "Selangor")],          # Gombak
    16: [("Cyberjaya", "Selangor"), ("Kajang", "Selangor")],       # Subang Jaya
    # --- Federal Territory ---
    1:  [("Kepong", FEDERAL_TERRITORY)],                           # Kuala Lumpur
    10: [("Kepong", FEDERAL_TERRITORY)],                           # Setapak
    11: [("Kepong", FEDERAL_TERRITORY)],                           # Wangsa Maju
    17: [("Kajang", "Selangor")],                                  # Bukit Jalil
    # --- one unserved town per remaining state ---
    3:  [("Kulai", "Johor")],                                      # Johor Bahru
    4:  [("Butterworth", "Pulau Pinang")],                         # George Town
    5:  [("Alor Gajah", "Melaka")],                                # Melaka
    13: [("Taiping", "Perak")],                                    # Ipoh
    14: [("Nilai", "Negeri Sembilan")],                            # Seremban
    15: [("Temerloh", "Pahang")],                                  # Kuantan
}


def sat_share(br):
    """Share of a branch's customers who live in one of its satellite
    towns. Selangor is deliberately the heaviest - that is where the
    next-branch question is live."""
    return 0.20 if BR[br]["state"] == "Selangor" else 0.10


def branch_weight(br, d):
    b = BR[br]
    if d < b["open"]:
        return 0.0
    if br in RAMP:
        start, step = RAMP[br]
        months = (d.year - b["open"].year) * 12 + d.month - b["open"].month
        return b["weight"] * min(1.0, start + step * months)
    return b["weight"]


# ===================================================================
# CATALOGUE  (10 categories, the ones that sell: facial cleanser, face cream,
# serum, face mask, sunscreen, eye cream, toner, lip care, eye mask, essential oil)
# ===================================================================
_DESC = {
    "Facial Cleanser": "Daily facial cleanser suitable for all skin types.",
    "Toner": "Balancing toner that refines pores and preps skin.",
    "Serum": "Concentrated treatment serum for targeted skin concerns.",
    "Face Cream": "Hydrating face cream that strengthens the skin barrier.",
    "Sunscreen": "Broad spectrum UV protection for daily wear.",
    "Face Mask": "Intensive weekly treatment mask.",
    "Eye Cream": "Targeted care for the delicate eye area.",
    "Lip Care": "Nourishing lip care for smooth, hydrated lips.",
    "Eye Mask": "Targeted eye patches for puffiness, dark circles and fine lines.",
    "Essential Oil": "Plant-derived oil for acne, inflammation and early signs of aging.",
}
_P = [  # (id, name, brand, category, price)
    (1, "Gentle Foaming Cleanser", "PureGlow", "Facial Cleanser", 32.00),
    (2, "Charcoal Deep Cleanse Gel", "PureGlow", "Facial Cleanser", 38.00),
    (3, "Milk Cleansing Lotion", "PureGlow", "Facial Cleanser", 29.00),
    (4, "Salicylic Acid Acne Cleanser", "ClearMe", "Facial Cleanser", 42.00),
    (5, "Green Tea Purifying Cleanser", "BotaniQ", "Facial Cleanser", 35.00),
    (6, "Hyaluronic Hydrating Cleanser", "HydraLuxe", "Facial Cleanser", 40.00),
    (7, "Rose Water Soothing Toner", "HydraLuxe", "Toner", 32.00),
    (8, "Witch Hazel Pore Toner", "HydraLuxe", "Toner", 38.00),
    (9, "Centella Calming Toner", "BotaniQ", "Toner", 40.00),
    (10, "Niacinamide Pore Toner", "DermaVita", "Toner", 45.00),
    (11, "Glycolic Acid Exfoliating Toner", "RenewLab", "Toner", 48.00),
    (12, "Vitamin C Brightening Serum", "DermaVita", "Serum", 89.00),
    (13, "Hyaluronic Acid Serum", "DermaVita", "Serum", 75.00),
    (14, "Niacinamide Pore Serum", "DermaVita", "Serum", 68.00),
    (15, "Retinol Renewal Serum", "DermaVita", "Serum", 110.00),
    (16, "Peptide Firming Serum", "DermaVita", "Serum", 120.00),
    (17, "Azelaic Acid Clarifying Serum", "RenewLab", "Serum", 95.00),
    (18, "24K Gold Peptide Serum", "HydraLuxe", "Serum", 150.00),
    (19, "Hyaluronic Acid Face Cream", "HydraLuxe", "Face Cream", 65.00),
    (20, "Ceramide Barrier Cream", "HydraLuxe", "Face Cream", 78.00),
    (21, "Oil Free Gel Cream", "HydraLuxe", "Face Cream", 48.00),
    (22, "Collagen Youth Cream", "DermaVita", "Face Cream", 95.00),
    (23, "Shea Butter Nourishing Cream", "BotaniQ", "Face Cream", 55.00),
    (24, "Dark Spot Correcting Cream", "DermaVita", "Face Cream", 88.00),
    (25, "SPF50 Daily Sunscreen Lotion", "SunGuard", "Sunscreen", 55.00),
    (26, "Tinted Sunscreen SPF45", "SunGuard", "Sunscreen", 62.00),
    (27, "Water Based Sunscreen Gel", "SunGuard", "Sunscreen", 48.00),
    (28, "SPF60 Sport Sunscreen", "SunGuard", "Sunscreen", 58.00),
    (29, "Mineral Sunscreen Stick SPF50", "SunGuard", "Sunscreen", 52.00),
    (30, "Charcoal Detox Mask (Jar)", "PureGlow", "Face Mask", 38.00),
    (31, "Collagen Sheet Mask (Box of 5)", "PureGlow", "Face Mask", 45.00),
    (32, "Hydrating Sleeping Mask (Jar)", "PureGlow", "Face Mask", 72.00),
    (33, "Vitamin C Brightening Sheet Mask (Box of 5)", "PureGlow", "Face Mask", 48.00),
    (34, "Mud Purifying Mask (Jar)", "BotaniQ", "Face Mask", 36.00),
    (35, "Enzyme Peel Mask", "RenewLab", "Face Mask", 58.00),
    (36, "Collagen Eye Cream", "DermaVita", "Eye Cream", 68.00),
    (37, "Caffeine De Puff Eye Gel", "DermaVita", "Eye Cream", 58.00),
    (38, "Retinol Eye Repair Cream", "DermaVita", "Eye Cream", 85.00),
    (39, "Peptide Eye Cream", "HydraLuxe", "Eye Cream", 92.00),
    (40, "Shea Butter Lip Balm", "ClearMe", "Lip Care", 18.00),
    (41, "Vitamin E Lip Treatment", "ClearMe", "Lip Care", 25.00),
    (42, "Overnight Lip Mask", "HydraLuxe", "Lip Care", 28.00),
    (43, "Collagen Eye Mask (Box of 10)", "RenewLab", "Eye Mask", 52.00),
    (44, "Gold Hydrogel Eye Mask (Box of 10)", "RenewLab", "Eye Mask", 72.00),
    (45, "Caffeine Eye Patch (Box of 10)", "PureGlow", "Eye Mask", 58.00),
    (46, "Tea Tree Essential Oil", "BotaniQ", "Essential Oil", 38.00),
    (47, "Lavender Essential Oil", "BotaniQ", "Essential Oil", 42.00),
    (48, "Rosehip Facial Oil", "BotaniQ", "Essential Oil", 62.00),
    # launched 2025-01-01 (shipped in data25): the men's line + 2 face masks
    (49, "Men's Charcoal Facial Cleanser", "HIM Essentials", "Facial Cleanser", 36.00),
    (50, "Men's Oil-Control Face Cream", "HIM Essentials", "Face Cream", 58.00),
    (51, "Men's Sunscreen SPF50", "HIM Essentials", "Sunscreen", 55.00),
    (52, "Men's Caffeine Eye Gel", "HIM Essentials", "Eye Cream", 62.00),
    (53, "Men's Charcoal Face Mask (Jar)", "HIM Essentials", "Face Mask", 40.00),
    (54, "Men's Lip Balm SPF15", "HIM Essentials", "Lip Care", 22.00),
    (55, "Overnight Retinal Sleeping Mask", "PureGlow", "Face Mask", 88.00),
    (56, "Pink Clay Purifying Mask (Jar)", "PureGlow", "Face Mask", 44.00),
]
PRODUCTS = [(i, n, b, c, _DESC[c], p) for i, n, b, c, p in _P]
LAUNCH_2025 = date(2025, 1, 1)        # products 49-56, supplier 8, men's push
FIRST_NEW_PID = 49
MENS_PRODUCTS = set(range(49, 55))
SERVICES = [
    (1, "Classic Facial", "Basic Facial", "Cleansing, exfoliation and mask for everyday skin maintenance.", 112.50),
    (2, "Express Facial", "Basic Facial", "Cleansing, exfoliation and mask for everyday skin maintenance.", 90.00),
    (3, "Deep Cleansing Facial", "Deep Cleansing", "Thorough pore cleansing with extraction.", 165.00),
    (4, "Blackhead Extraction Facial", "Deep Cleansing", "Thorough pore cleansing with extraction.", 142.50),
    (5, "HydraFacial", "Hydrating", "Intensive moisture infusion for dehydrated skin.", 330.00),
    (6, "Hydrating Glow Facial", "Hydrating", "Intensive moisture infusion for dehydrated skin.", 247.50),
    (7, "Anti Aging Collagen Facial", "Anti Aging", "Advanced firming and rejuvenation treatment.", 420.00),
    (8, "Gold Radiance Facial", "Anti Aging", "Advanced firming and rejuvenation treatment.", 480.00),
    (9, "Diamond Peel Facial", "Anti Aging", "Advanced firming and rejuvenation treatment.", 375.00),
    (10, "Vitamin C Brightening Facial", "Brightening", "Targets dullness and uneven skin tone.", 225.00),
    (11, "Whitening Facial", "Brightening", "Targets dullness and uneven skin tone.", 270.00),
    (12, "Acne Clear Facial", "Acne Treatment", "Calms active breakouts and controls oil.", 195.00),
    (13, "Oxygen Infusion Facial", "Acne Treatment", "Calms active breakouts and controls oil.", 240.00),
    (14, "Eye Treatment Add on", "Add on", "Optional enhancement added to a main treatment.", 52.50),
    (15, "LED Light Therapy Add on", "Add on", "Optional enhancement added to a main treatment.", 82.50),
    (16, "Shoulder and Neck Massage Add on", "Add on", "Optional enhancement added to a main treatment.", 60.00),
    # bookable from 2021-04-01 (inside the initial folder)
    (17, "Microneedling Rejuvenation", "Anti Aging", "Advanced firming and rejuvenation treatment.", 570.00),
    (18, "Scalp Detox Add on", "Add on", "Optional enhancement added to a main treatment.", 67.50),
]
NEW_SERVICE_LAUNCH = date(2021, 4, 1)     # services 17-18
SERV_MINUTES = {1: 60, 2: 45, 3: 75, 4: 60, 5: 75, 6: 75, 7: 90, 8: 90, 9: 75,
                10: 60, 11: 75, 12: 60, 13: 75, 14: 15, 15: 30, 16: 30, 17: 90, 18: 20}
ADDON_SERVICES = [14, 15, 16, 18]
MAIN_SERVICES = [s[0] for s in SERVICES if s[0] not in ADDON_SERVICES]
SUPPLIERS = [
    (1, "Kosme Distribution Sdn Bhd", "03-56781234", "sales@kosmedist.com.my"),
    (2, "Seoul Skin Import Sdn Bhd", "03-79912345", "order@seoulskin.com.my"),
    (3, "NaturaLab Malaysia Sdn Bhd", "03-61234567", "supply@naturalab.com.my"),
    (4, "DermaSource Trading", "07-3345566", "info@dermasource.com.my"),
    (5, "Pure Essence Supplies Sdn Bhd", "04-2299887", "cs@pureessence.com.my"),
    (6, "BeautyHub Wholesale Sdn Bhd", "03-80881122", "wholesale@beautyhub.com.my"),
    # Ipoh's only supplier (local, expensive) - from day one
    (7, "Perak Beauty Supplies Sdn Bhd", "05-2558877", "sales@perakbeauty.com.my"),
    # onboarded 2025-01-01 for the men's line (shipped in data25)
    (8, "HIM Care Labs Sdn Bhd", "03-78801122", "supply@himcarelabs.com.my"),
]
SUPPLIER_FROM = {7: START, 8: LAUNCH_2025}
IPOH_SUPPLIER = 7
BRAND_SUPPLIERS = {"PureGlow": [1, 6], "HydraLuxe": [2, 6], "DermaVita": [4, 2],
                   "SunGuard": [3, 5], "RenewLab": [3], "BotaniQ": [5, 3], "ClearMe": [4, 6],
                   "HIM Essentials": [8]}
COST_RATIO_NATIONAL = (0.33, 0.43)            # unit cost as a share of the shelf price
COST_RATIO_IPOH = {False: (0.46, 0.54), True: (0.74, 0.84)}   # key: d >= 2024-01-01 (supplier repriced)
IPOH_COST_STEP = date(2024, 1, 1)
UTILS = [(1, "Rent"), (2, "Electricity"), (3, "Water"), (4, "Internet"),
         (5, "Maintenance"), (6, "Waste Management")]
UTIL_NAME = dict(UTILS)          # the CSV carries the name, not the id

# --- price eras (the SCD2 test cases; must match the 99_price_*.sql files) ---
PRICE_RISE_2024 = {4: 48.00, 12: 98.00, 15: 125.00, 16: 135.00, 22: 108.00, 25: 62.00, 32: 82.00, 36: 76.00}
PRICE_RISE_2025 = {4: 54.00, 13: 84.00, 16: 149.00, 20: 88.00, 26: 69.00, 31: 50.00, 43: 58.00, 46: 42.00}
SERVICE_RISE_2025 = {5: 367.50, 6: 277.50, 7: 465.00, 10: 252.00, 12: 217.50, 17: 630.00}
BASE_PRICE = {p[0]: p[5] for p in PRODUCTS}
BASE_SERV_PRICE = {s[0]: s[4] for s in SERVICES}
PROD_CAT = {p[0]: p[3] for p in PRODUCTS}
PROD_BRAND = {p[0]: p[2] for p in PRODUCTS}


def product_price(pid, d):
    if d >= date(2025, 1, 1) and pid in PRICE_RISE_2025:
        return PRICE_RISE_2025[pid]
    if d >= date(2024, 1, 1) and pid in PRICE_RISE_2024:
        return PRICE_RISE_2024[pid]
    return BASE_PRICE[pid]


def service_price(sid, d):
    if d >= date(2025, 1, 1) and sid in SERVICE_RISE_2025:
        return SERVICE_RISE_2025[sid]
    return BASE_SERV_PRICE[sid]


def product_available(pid, d):
    return pid < FIRST_NEW_PID or d >= LAUNCH_2025


def service_available(sid, d):
    return sid < 17 or d >= NEW_SERVICE_LAUNCH


def tax_rate(d):
    """6 % SST throughout 2019-2025."""
    return 0.06


def supplier_for(br, pid):
    if br == IPOH:
        return IPOH_SUPPLIER
    return random.choice(BRAND_SUPPLIERS[PROD_BRAND[pid]])


def cost_ratio(br, d):
    if br == IPOH:
        return COST_RATIO_IPOH[d >= IPOH_COST_STEP]
    return COST_RATIO_NATIONAL


# ===================================================================
# CALENDAR PATTERNS
# ===================================================================
YEAR_GROWTH = {2019: 1.00, 2020: 0.98, 2021: 1.00, 2022: 1.38, 2023: 1.45, 2024: 1.50, 2025: 1.85}
RES_YEAR_GROWTH = {2019: 1.00, 2020: 0.98, 2021: 1.00, 2022: 1.08, 2023: 1.15, 2024: 1.20, 2025: 1.28}
WEEKDAY_MULT = {0: 0.80, 1: 0.92, 2: 0.95, 3: 1.00, 4: 1.12, 5: 1.42, 6: 1.25}
QUARTER_MULT = {1: 1.00, 2: 1.05, 3: 0.90, 4: 1.18}
CNY = {2019: date(2019, 2, 5), 2020: date(2020, 1, 25), 2021: date(2021, 2, 12), 2022: date(2022, 2, 1),
       2023: date(2023, 1, 22), 2024: date(2024, 2, 10), 2025: date(2025, 1, 29)}
RAYA = {2019: date(2019, 6, 5), 2020: date(2020, 5, 24), 2021: date(2021, 5, 13), 2022: date(2022, 5, 2),
        2023: date(2023, 4, 22), 2024: date(2024, 4, 10), 2025: date(2025, 3, 31)}
DEEPAVALI = {2019: date(2019, 10, 27), 2020: date(2020, 11, 14), 2021: date(2021, 11, 4), 2022: date(2022, 10, 24),
             2023: date(2023, 11, 12), 2024: date(2024, 10, 31), 2025: date(2025, 10, 20)}


def mothers_day(y):
    d = date(y, 5, 1)
    return d + timedelta(days=(6 - d.weekday()) % 7 + 7)      # second Sunday of May


FESTIVALS = []            # (date, peak, run-up days, holiday-dip days)
for _y in range(2019, 2026):
    FESTIVALS.append((CNY[_y], 1.75, 18, 2))
    FESTIVALS.append((RAYA[_y], 1.85, 25, 2))
    FESTIVALS.append((DEEPAVALI[_y], 1.45, 14, 1))
    FESTIVALS.append((date(_y, 12, 25), 1.40, 16, 1))
    FESTIVALS.append((date(_y, 2, 14), 1.25, 3, 0))          # Valentine's
    FESTIVALS.append((mothers_day(_y), 1.30, 7, 0))          # Mother's Day
MEGA_SALE = {(11, 11): 2.30, (12, 12): 2.30, (3, 3): 1.50, (6, 6): 1.50, (9, 9): 1.50, (10, 10): 1.50}
RAYA_BONUS_MONTH = {y: RAYA[y].month for y in RAYA}
PH_ORDERS, PH_RES = 0.85, 0.50        # national public holiday: shops quieter, salon half-day


def public_holidays(y):
    s = {date(y, 1, 1), date(y, 5, 1), date(y, 8, 31), date(y, 9, 16), date(y, 12, 25),
         CNY[y], CNY[y] + timedelta(days=1), RAYA[y], RAYA[y] + timedelta(days=1), DEEPAVALI[y]}
    return s


_PH = {y: public_holidays(y) for y in range(2019, 2026)}


def season_weight(d):
    """(orders weight, reservations weight) for the day."""
    w = WEEKDAY_MULT[d.weekday()] * QUARTER_MULT[(d.month - 1) // 3 + 1]
    dip = False
    for fdate, peak, window, dipdays in FESTIVALS:
        delta = (fdate - d).days
        if 0 < delta <= window:
            w *= 1 + (peak - 1) * (1 - delta / window)
        elif dipdays and -dipdays < delta <= 0:
            w *= 0.45                       # the holiday itself: shops quiet
            dip = True
    w *= MEGA_SALE.get((d.month, d.day), 1.0)
    if (d.month == 6 and d.day >= 15) or d.month in (7, 8):
        w *= 1.06                           # Malaysia Mega Sale Carnival
    if d.month == 8 and 25 <= d.day <= 31:
        w *= 1.20                           # Merdeka week promo
    w_o, w_r = w, w
    if d in _PH[d.year]:
        if not dip:
            w_o *= PH_ORDERS
        w_r *= PH_RES
    return w_o, w_r


def festival_runup(d):
    return any(0 < (f[0] - d).days <= f[2] for f in FESTIVALS)


def covid(d, state):
    """(product factor, service factor). Malaysia timeline; the Klang Valley
    (Selangor + WP) had the tighter CMCO in Oct 2020-Jan 2021 and the EMCO
    of 3-16 Jul 2021. Service 0.0 = salons legally closed."""
    kv = state in KV_STATES
    if d < date(2020, 3, 18):
        return 1.0, 1.0
    if d <= date(2020, 5, 3):                     # MCO 1.0
        return 0.22, 0.0
    if d <= date(2020, 6, 9):                     # CMCO
        return 0.58, 0.30
    if d <= date(2020, 10, 13):                   # RMCO
        return 0.90, 0.78
    if d <= date(2021, 1, 12):                    # CMCO 2nd wave (Klang Valley)
        return (0.80, 0.58) if kv else (0.90, 0.78)
    if d <= date(2021, 3, 4):                     # MCO 2.0
        return 0.48, 0.12
    if d <= date(2021, 5, 11):                    # cautious recovery
        return 0.85, 0.70
    if d <= date(2021, 5, 31):                    # MCO 3.0
        return 0.55, 0.25
    if d <= date(2021, 8, 31):                    # FMCO (+ EMCO in KV)
        if kv and date(2021, 7, 3) <= d <= date(2021, 7, 16):
            return 0.20, 0.0
        return 0.34, 0.0
    if d <= date(2021, 10, 31):                   # phased reopening (NRP)
        return 0.72, 0.48
    if d <= date(2022, 3, 31):                    # transition to endemic
        return 0.95, 0.86
    return 1.0, 1.0


CLOSURE_MONTHS = {(2020, 3): 0.7, (2020, 4): 0.25, (2020, 5): 0.4,
                  (2021, 6): 0.25, (2021, 7): 0.25, (2021, 8): 0.3}
RENT_REBATE_MONTHS = {(2020, 4), (2020, 5), (2021, 6), (2021, 7), (2021, 8)}


def pay_cut(y, m):
    if (y, m) in ((2020, 4), (2020, 5)):
        return 0.80
    if (y, m) in ((2021, 6), (2021, 7), (2021, 8)):
        return 0.85
    return 1.0


def epf_rate(y, m):
    if (y, m) >= (2020, 4) and (y, m) <= (2020, 12):
        return 0.07
    if (y, m) >= (2021, 1) and (y, m) <= (2022, 6):
        return 0.09
    return 0.11


INCREMENT = {2019: 1.0}
for _y in range(2020, 2026):
    INCREMENT[_y] = INCREMENT[_y - 1] * {2021: 1.00, 2025: 1.04}.get(_y, 1.03)

# --- the 2022 e-commerce launch and the 2025 men's push ---
ECOM_START = date(2022, 1, 1)
PJ_HUB_MULT = 1.25                 # PJ is the fulfilment hub for online orders
IPOH_DEMAND_MULT = {2024: 0.70, 2025: 0.70}   # online + a new Perak competitor take Ipoh footfall
CROSS_SHARE = 0.15                 # share of a branch's orders from another branch's customers
CROSS_SHARE_ONLINE = 0.40          # ... from 2022 (online orders are fulfilled by any branch)
ONLINE_FAR_SHARE = 0.50            # of those, half come from ANY branch nationwide
PROMO_RATE = {False: 0.12, True: 0.20}   # key: online era
MENS_MALE_TILT = 3.0               # male customers' weight on the men's line
MENS_FEMALE_TILT = 0.25
NEW_SKU_BOOST = 1.50               # first 365 days after a launch


def product_mult(br, y):
    m = 1.0
    if br == PJ and y >= ECOM_START.year:
        m *= PJ_HUB_MULT
    if br == IPOH:
        m *= IPOH_DEMAND_MULT.get(y, 1.0)
    return m


# ===================================================================
# PEOPLE
# ===================================================================
# names are ethnicity- and gender-consistent (binti / a/p for women, bin / a/l for men)
NAMES = {
    "malay": dict(
        f=["Nurin", "Aisyah", "Siti", "Zarina", "Nadia", "Farah", "Nur Aina", "Suhaila", "Alia", "Anisa",
           "Rohani", "Nurul Huda", "Aina", "Fatimah", "Nabila", "Yasmin", "Hannah", "Amelia", "Balqis", "Izzati"],
        m=["Aiman", "Haziq", "Faizal", "Amirul", "Hafiz", "Adam", "Irfan", "Zulkifli", "Syafiq", "Danial", "Firdaus"],
        lf=["binti Ismail", "binti Yusof", "binti Hamid", "binti Abdullah", "binti Rahman", "binti Hassan",
            "binti Razak", "binti Ahmad", "binti Osman", "binti Zainal"],
        lm=["bin Abdullah", "bin Razak", "bin Ahmad", "bin Ismail", "bin Yusof", "bin Hassan", "bin Rahman",
            "bin Hamid", "bin Osman", "bin Zainal"]),
    "chinese": dict(
        f=["Mei Ling", "Chloe", "Hui Min", "Wan Ying", "Yee Ling", "Jasmine", "Xin Yi", "Pei Shan", "Ling Ling",
           "Sze Min", "Grace", "Li Wen", "Emily", "Michelle", "Vanessa", "Kai Xin", "Rachel", "Shu Fen", "Jia Yi"],
        m=["Wei Jie", "Kok Wai", "Jun Hao", "Zhi Wei", "Chong Wei", "Kevin", "Jian Ming", "Yong Sheng",
           "Daniel", "Wei Hong", "Zheng Yang"],
        lf=["Lim", "Tan", "Ong", "Wong", "Cheah", "Goh", "Lee", "Chong", "Sim", "Yeoh", "Teoh", "Ng", "Chin",
            "Loh", "Foo", "Chua", "Khoo", "Yap", "Liew", "Chan"],
        lm=None),
    "indian": dict(
        f=["Priya", "Lakshmi", "Sharmila", "Kavitha", "Divya", "Shalini", "Deepa", "Meena", "Anjali", "Thivya"],
        m=["Rajesh", "Arjun", "Suresh", "Kumar", "Vikram", "Ravi", "Ganesh", "Prakash"],
        lf=["a/p Subramaniam", "a/p Muniandy", "a/p Krishnan", "a/p Rajan", "a/p Maniam", "a/p Ramasamy"],
        lm=["a/l Subramaniam", "a/l Muniandy", "a/l Krishnan", "a/l Rajan", "a/l Maniam", "a/l Ramasamy"]),
}
ETHNIC_MIX = ["malay"] * 55 + ["chinese"] * 30 + ["indian"] * 15


def make_name(female):
    p = NAMES[random.choice(ETHNIC_MIX)]
    fn = random.choice(p["f"] if female else p["m"])
    last = p["lf"] if (female or p["lm"] is None) else p["lm"]
    return fn, random.choice(last)


# 2019 base salary bands (INCREMENT scales them +3 %/yr, 0 % in 2021, +4 % in 2025)
ROLES = [("Branch Manager", "Manager", 4200, 4800),
         ("Senior Therapist", "Lead", 2600, 3100),
         ("Beauty Therapist", "Senior", 1900, 2300),
         ("Beauty Therapist", "Junior", 1450, 1800),
         ("Sales Assistant", "Junior", 1450, 1800),
         ("Receptionist", "Junior", 1550, 1900),
         ("Cashier", "Junior", 1450, 1750)]
THERAPIST_ROLES = ("Senior Therapist", "Beauty Therapist")
JUNIOR_ROLES = (ROLES[3], ROLES[4], ROLES[6])       # the ones let go in the lockdowns
TIERS = ["Bronze"] * 55 + ["Silver"] * 27 + ["Gold"] * 13 + ["Platinum"] * 5
TIER_DISCOUNT = {"Bronze": 0.00, "Silver": 0.03, "Gold": 0.07, "Platinum": 0.12}
TIER_ACTIVITY = {"Bronze": 1.0, "Silver": 1.5, "Gold": 2.2, "Platinum": 3.2}
# customer registrations per unit of branch weight per year (+40 % once online)
REG_RATE = {2016: 325, 2017: 375, 2018: 475, 2019: 500, 2020: 400, 2021: 390,
            2022: 700, 2023: 700, 2024: 700, 2025: 720}
MALE_SHARE = defaultdict(lambda: 0.14, {2025: 0.35})       # of new registrations
BASE_ORDERS_PER_DAY = 13.0        # PJ (weight 1.0) on an average 2019 day
RES_PER_ORDER = 0.42              # 2019 ratio; RES_YEAR_GROWTH scales it per year
# basket-size weights for 1..5 units per order line
QTY_W = (26, 33, 24, 12, 5)       # plain day          mean 2.37
QTY_W_RUNUP = (18, 30, 27, 16, 9)  # festival run-up    mean 2.68
QTY_W_MEGA = (14, 26, 27, 20, 13)  # 11.11 / 12.12 etc  mean 2.92
HOUR_WEIGHT = {10: 6, 11: 8, 12: 7, 13: 6, 14: 9, 15: 11, 16: 15, 17: 15, 18: 10, 19: 7}
CLOSE_MIN = 20 * 60


def rand_date(a, b):
    return a + timedelta(days=random.randint(0, (b - a).days))


def poisson(lam):
    if lam <= 0:
        return 0
    if lam > 50:
        return max(0, int(round(random.gauss(lam, math.sqrt(lam)))))
    L = math.exp(-lam)
    k, p = 0, 1.0
    while True:
        p *= random.random()
        if p < L:
            return k
        k += 1


def role_plan(n):
    """Role mix for a branch of n staff (therapists roughly 60 %)."""
    plan = [ROLES[0]]
    plan += [ROLES[1]] * max(1, round(n * 0.12))
    plan += [ROLES[2]] * max(1, round(n * 0.20))
    plan += [ROLES[4]] * max(1, round(n * 0.16))
    plan += [ROLES[5]] * (2 if n >= 14 else 1)
    plan += [ROLES[6]] * (2 if n >= 20 else 1)
    plan += [ROLES[3]] * max(1, n - len(plan))
    return plan


def money(x):
    return f"{x:.2f}"


# ===================================================================
# STAFF
# ===================================================================
class Staff:
    __slots__ = ("id", "br", "fn", "ln", "role", "pos", "dob", "female", "hire",
                 "salary", "leave", "phone", "addr")


def make_staff(br, role, pos, lo, hi, hire):
    s = Staff()
    s.br, s.role, s.pos, s.hire = br, role, pos, hire
    s.female = random.random() < 0.79
    s.fn, s.ln = make_name(s.female)
    if role == "Branch Manager":
        s.dob = rand_date(hire - timedelta(days=48 * 365), hire - timedelta(days=32 * 365))
    elif pos in ("Lead", "Senior"):
        s.dob = rand_date(hire - timedelta(days=42 * 365), hire - timedelta(days=24 * 365))
    else:
        s.dob = rand_date(hire - timedelta(days=36 * 365), hire - timedelta(days=19 * 365))
    s.salary = round(random.uniform(lo, hi) * INCREMENT.get(hire.year, 1.0), 2)
    s.leave = None
    s.phone = f"01{random.randint(0, 9)}-{random.randint(1000000, 9999999)}"
    s.addr = f"No. {random.randint(1, 250)}, Jalan {random.randint(1, 20)}/{random.randint(1, 30)}"
    return s


def staff_folder(s):
    """A staff row must not precede its branch row (FK): the 2024 teams are
    hired in late Dec 2023 but ship in data24 with their branch."""
    return folder_of(max(s.hire, BR[s.br]["open"]))


def build_staff():
    staff = []
    for br in BR_IDS:
        b = BR[br]
        if br in NEW_BRANCHES:
            continue
        opened = b["open"]
        for role, pos, lo, hi in role_plan(b["headcount"]):
            if role == "Branch Manager":
                hire = opened - timedelta(days=random.randint(20, 40))
            elif pos in ("Lead", "Senior") or random.random() < 0.6:
                hire = rand_date(opened - timedelta(days=14), opened + timedelta(days=120))
            else:
                hire = rand_date(opened + timedelta(days=60),
                                 max(opened + timedelta(days=200), date(2019, 6, 30)))
            staff.append(make_staff(br, role, pos, lo, hi, hire))
        # 2019 growth hire in the larger branches
        if b["weight"] >= 0.5:
            role, pos, lo, hi = random.choice([ROLES[3], ROLES[4]])
            staff.append(make_staff(br, role, pos, lo, hi, rand_date(date(2019, 2, 1), date(2019, 8, 31))))

    # ---- COVID reductions: two waves, junior roles only, managers/seniors stay ----
    def cut(candidates, share, a, b):
        n = round(len(candidates) * share)
        for s in random.sample(candidates, n):
            s.leave = rand_date(a, b)
    juniors = [s for s in staff if (s.role, s.pos) in [(r[0], r[1]) for r in JUNIOR_ROLES]]
    cut(juniors, 0.12, date(2020, 4, 1), date(2020, 6, 30))
    juniors = [s for s in juniors if s.leave is None]
    cut(juniors, 0.10, date(2021, 7, 1), date(2021, 9, 30))
    # normal attrition 2019-2021 (small)
    others = [s for s in staff if s.leave is None and s.role != "Branch Manager" and s.pos != "Lead"]
    cut(others, 0.04, date(2019, 9, 1), date(2021, 12, 15))
    lost = defaultdict(int)
    for s in staff:
        if s.leave:
            lost[s.br] += 1

    # ---- 2022 rehiring wave (recovery), then growth hires ----
    for br in BR_IDS:
        if br in NEW_BRANCHES:
            continue
        b = BR[br]
        n = round(lost[br] * 0.9) + (1 if b["weight"] >= 0.6 else 0)
        for _ in range(n):
            role, pos, lo, hi = random.choice([ROLES[3], ROLES[3], ROLES[4], ROLES[6]])
            staff.append(make_staff(br, role, pos, lo, hi, rand_date(date(2022, 1, 15), date(2022, 6, 30))))
        if b["weight"] >= 0.9:
            role, pos, lo, hi = ROLES[2]
            staff.append(make_staff(br, role, pos, lo, hi, rand_date(date(2023, 3, 1), date(2023, 9, 30))))
        if b["weight"] >= 0.5:
            role, pos, lo, hi = random.choice([ROLES[3], ROLES[4]])
            staff.append(make_staff(br, role, pos, lo, hi, rand_date(date(2024, 2, 1), date(2024, 9, 30))))
        if b["weight"] >= 0.6:
            role, pos, lo, hi = random.choice([ROLES[3], ROLES[2]])
            staff.append(make_staff(br, role, pos, lo, hi, rand_date(date(2025, 2, 1), date(2025, 8, 31))))

    # ---- the four 2024 teams: hired in the last week of Dec 2023, ship in data24 ----
    for br in NEW_BRANCHES:
        for role, pos, lo, hi in role_plan(BR[br]["headcount"]):
            staff.append(make_staff(br, role, pos, lo, hi, rand_date(date(2023, 12, 26), date(2023, 12, 31))))
        # first-year growth hire in the bigger new branches
        if BR[br]["weight"] >= 0.5:
            role, pos, lo, hi = random.choice([ROLES[3], ROLES[2]])
            staff.append(make_staff(br, role, pos, lo, hi, rand_date(date(2025, 2, 1), date(2025, 8, 31))))

    # ---- IDs: folder of the staff row first, then branch, then hire date ----
    fidx = {f[0]: i for i, f in enumerate(FOLDERS)}
    staff.sort(key=lambda s: (fidx[staff_folder(s)], s.br, s.hire, s.fn))
    for i, s in enumerate(staff, 1):
        s.id = i
    return staff


def employed(s, d):
    return s.hire <= d and (s.leave is None or d <= s.leave)


# ===================================================================
# CUSTOMERS
# ===================================================================
class Customer:
    __slots__ = ("id", "fn", "ln", "female", "dob", "tier", "city", "state",
                 "postcode", "reg", "home", "act", "end", "phone", "addr")


def build_customers():
    cust = []
    d = date(2016, 1, 1)
    while d <= END - timedelta(days=15):
        y = d.year
        for br in BR_IDS:
            b = BR[br]
            if d < b["open"] - timedelta(days=14):
                continue
            w = branch_weight(br, max(d, b["open"]))
            lam = REG_RATE[y] / 365.0 * w * WEEKDAY_MULT[d.weekday()]
            pf, _ = covid(d, b["state"])
            lam *= (0.35 + 0.65 * pf) if pf < 1 else 1.0
            for _ in range(poisson(lam)):
                c = Customer()
                c.home = br
                r = random.random()
                if r < 0.80:
                    c.city, c.state = b["city"], b["state"]
                else:
                    same = [x for x in BR_IDS if BR[x]["state"] == b["state"] and x != br]
                    if r < 0.95 and same:
                        o = BR[random.choice(same)]
                    else:
                        o = BR[random.choice([x for x in BR_IDS if x != br])]
                    c.city, c.state = o["city"], o["state"]
                c.postcode = random.choice(CITY_POSTCODES[c.city])
                c.reg = d
                c.female = random.random() < 1.0 - MALE_SHARE[y]
                c.fn, c.ln = make_name(c.female)
                try:
                    youngest = date(d.year - 18, d.month, d.day)
                except ValueError:
                    youngest = date(d.year - 18, 2, 28)
                c.dob = rand_date(date(d.year - 61, 1, 1), youngest)
                c.tier = random.choice(TIERS)
                c.act = TIER_ACTIVITY[c.tier] * random.lognormvariate(0.0, 0.5)
                if random.random() < 0.55:
                    c.end = date(2035, 1, 1)                     # loyal for life
                else:
                    c.end = d + timedelta(days=90 + int(random.expovariate(1 / 720.0)))
                c.phone = f"01{random.randint(0, 9)}-{random.randint(1000000, 9999999)}"
                c.addr = f"No. {random.randint(1, 300)}, Jalan {random.choice('ABCDEFG')}{random.randint(1, 20)}"
                cust.append(c)
        d += timedelta(days=1)
    cust.sort(key=lambda c: (c.reg, c.home))
    for i, c in enumerate(cust, 1):
        c.id = i
    place_satellite_customers(cust)
    return cust


def place_satellite_customers(cust):
    """Move a share of each branch's customers out to a nearby town that
    has no branch of its own (see SATELLITES).

    This runs as a SEPARATE PASS on its OWN Random instance, deliberately.
    Drawing from the module-wide seeded stream inside build_customers
    would shift every later draw and move every row count in the repo;
    doing it here leaves that stream byte-identical, so orders, revenue,
    the per-branch P&L and all the documented counts are untouched. Only
    the customer's city / state / postcode label changes - which is the
    whole point: the same people, now living somewhere we have no shop."""
    rng = random.Random(SEED + 7)
    for c in cust:
        sat = SATELLITES.get(c.home)
        if sat and rng.random() < sat_share(c.home):
            c.city, c.state = rng.choice(sat)
            c.postcode = rng.choice(CITY_POSTCODES[c.city])


class Pool:
    """Customers of one branch, added on their registration day; O(log n)
    weighted pick via cumulative weights; churned customers are skipped."""

    def __init__(self):
        self.items = []
        self.cum = []
        self.total = 0.0

    def add(self, c):
        self.items.append(c)
        self.total += c.act
        self.cum.append(self.total)

    def pick(self, d):
        if not self.items:
            return None
        c = None
        for _ in range(6):
            r = random.random() * self.total
            c = self.items[bisect_right(self.cum, r)]
            if c.end >= d:
                return c
        return c


# ===================================================================
# WRITERS
# ===================================================================
HEADERS = {
    "branch": ["br_ID", "br_name", "br_address_line", "br_city", "br_state", "br_postcode",
               "br_phone", "br_email", "br_open_date"],
    "supplier": ["sup_ID", "sup_name", "sup_phone", "sup_email"],
    "product": ["product_ID", "product_name", "product_brand", "product_category", "product_desc",
                "product_unit_price"],
    "service": ["serv_ID", "serv_name", "serv_category", "serv_description", "serv_price"],
    "staff": ["st_ID", "br_ID", "st_first_name", "st_last_name", "st_position",
              "st_address_line", "st_city", "st_state", "st_postcode", "st_DOB", "st_gender",
              "st_email", "st_phone", "st_hire_date", "st_status"],
    "customer": ["cus_ID", "cus_first_name", "cus_last_name", "cus_gender", "cus_phone",
                 "cus_DOB", "cus_email", "cus_loyalty_tier", "cus_address_line", "cus_city",
                 "cus_state", "cus_postcode", "cus_reg_date"],
    "orders": ["order_ID", "cus_ID", "br_ID", "st_ID", "order_date", "order_status"],
    "order_detail": ["order_det_ID", "order_ID", "product_ID", "order_quantity",
                     "order_discount", "order_tax"],
    "reservation": ["res_ID", "cus_ID", "br_ID", "booking_date", "reservation_date", "res_status"],
    "reservation_detail": ["res_det_ID", "res_ID", "st_ID", "serv_ID", "start_time", "end_time",
                           "serv_discount", "serv_tax"],
    "purchase": ["purchase_ID", "product_ID", "br_ID", "sup_ID", "purchase_qty", "purchase_date",
                 "purchase_unit_cost"],
    "salary_payment": ["sal_pay_ID", "st_ID", "pay_period", "base_amount", "bonus_amount",
                       "deduction_amount", "payment_date"],
    # util_name is stored on the row itself (no separate category table)
    "branch_utils": ["br_exp_ID", "br_ID", "util_name", "billing_period", "payment_amount",
                     "payment_date"],
}


class Out:
    """One csv.writer per (folder, table); header written on open."""

    def __init__(self):
        self.files, self.writers, self.rows = {}, {}, defaultdict(int)
        for name, _, _ in FOLDERS:
            os.makedirs(os.path.join(ROOT, name), exist_ok=True)
            for table, hdr in HEADERS.items():
                f = open(os.path.join(ROOT, name, table + ".csv"), "w", newline="", encoding="utf-8")
                w = csv.writer(f)
                w.writerow(hdr)
                self.files[(name, table)] = f
                self.writers[(name, table)] = w

    def row(self, folder, table, values):
        self.writers[(folder, table)].writerow(values)
        self.rows[(folder, table)] += 1

    def close(self):
        for f in self.files.values():
            f.close()


# ===================================================================
# GENERATE
# ===================================================================
def generate():
    random.seed(SEED)
    out = Out()
    print("building people ...")
    staff = build_staff()
    customers = build_customers()
    print(f"  staff {len(staff)}, customers {len(customers)}")

    # ---------- reference tables ----------
    for b in BRANCHES:
        out.row(folder_of(b[8]), "branch", [b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8]])
    for p in PRODUCTS:
        out.row(folder_of(LAUNCH_2025) if p[0] >= FIRST_NEW_PID else FOLDERS[0][0], "product",
                [p[0], p[1], p[2], p[3], p[4], money(p[5])])
    for s in SERVICES:
        out.row(folder_of(NEW_SERVICE_LAUNCH) if s[0] >= 17 else FOLDERS[0][0], "service",
                [s[0], s[1], s[2], s[3], money(s[4])])
    for s in SUPPLIERS:
        out.row(folder_of(SUPPLIER_FROM.get(s[0], START)), "supplier", list(s))
    for s in staff:
        b = BR[s.br]
        # st_position is the single job-title column (the ERD has no separate role):
        # Branch Manager / Senior Therapist / Beauty Therapist / Sales Assistant /
        # Receptionist / Cashier. Seniority and salary stay internal to the generator
        # (salary drives salary_payment; the OLTP staff table has no salary column).
        out.row(staff_folder(s), "staff",
                [s.id, s.br, s.fn, s.ln, s.role, s.addr, b["city"], b["state"], b["postcode"],
                 s.dob, "Female" if s.female else "Male",
                 f"{s.fn.split()[0].lower()}.{s.id}@glowbeauty.com.my", s.phone, s.hire,
                 "Resigned" if s.leave else "Active"])
    for c in customers:
        out.row(folder_of(c.reg), "customer",
                [c.id, c.fn, c.ln, "Female" if c.female else "Male", c.phone, c.dob,
                 f"{c.fn.split()[0].lower()}{c.id}@gmail.com", c.tier, c.addr, c.city, c.state,
                 c.postcode, c.reg])

    # ---------- indexes ----------
    staff_by_br = defaultdict(list)
    for s in staff:
        staff_by_br[s.br].append(s)
    cust_by_day = defaultdict(list)
    for c in customers:
        cust_by_day[c.reg].append(c)
    pools = {br: Pool() for br in BR_IDS}
    # customers registered before 2019 go straight in
    for c in customers:
        if c.reg < START:
            pools[c.home].add(c)
    nearby, others = {}, {}
    for br in BR_IDS:
        same = [x for x in BR_IDS if x != br and BR[x]["state"] == BR[br]["state"]]
        nearby[br] = same if same else [x for x in BR_IDS if x != br]
        others[br] = [x for x in BR_IDS if x != br]

    prod_ids = [p[0] for p in PRODUCTS]
    base_pw = {pid: (60.0 / BASE_PRICE[pid]) ** 0.45 * random.uniform(0.75, 1.3) for pid in prod_ids}
    main_sw = {sid: (150.0 / BASE_SERV_PRICE[sid]) ** 0.5 for sid in MAIN_SERVICES}

    # purchase bookkeeping
    sold_since = defaultdict(int)          # (br, pid) -> units since last restock
    stocked = set()                        # (br, pid) restocked at least once
    last_restock_month = {}                # (br, pid) -> (y, m)

    ids = dict(order=0, det=0, res=0, rdet=0, pur=0, sal=0, exp=0)
    stats = dict(res_dropped=0, orders_skipped=0)

    def restock_day(y, m, half):
        d = date(y, m, 3 if half == 0 else 17)
        while d.weekday() > 4:
            d += timedelta(days=1)
        return d

    def opening_stock_day(br):
        """One week before opening, but never before the folder that ships the branch."""
        o = BR[br]["open"]
        return max(o - timedelta(days=7), folder_start(folder_of(o)))

    def do_purchase(folder, br, pid, d, qty):
        lo, hi = cost_ratio(br, d)
        ids["pur"] += 1
        out.row(folder, "purchase", [ids["pur"], pid, br, supplier_for(br, pid), qty, d,
                                     money(product_price(pid, d) * random.uniform(lo, hi))])

    def cumulate(ws):
        cum, t = [], 0.0
        for w in ws:
            t += w
            cum.append(t)
        return cum, t

    print("generating transactions ...")
    d = START
    day_no = 0
    while d <= END:
        folder = folder_of(d)
        y, m = d.year, d.month
        season_o, season_r = season_weight(d)
        runup = festival_runup(d)
        hot = m in (3, 4, 5, 6)
        haze = m in (9, 10)
        mega = (m, d.day) in MEGA_SALE
        online = d >= ECOM_START
        rate = tax_rate(d)
        # customers registering today join their branch pool
        for c in cust_by_day.get(d, ()):
            pools[c.home].add(c)
        avail = [pid for pid in prod_ids if product_available(pid, d)]
        mens_live = d >= LAUNCH_2025
        open_now = [x for x in BR_IDS if BR[x]["open"] <= d]
        nearby_now = {br: [x for x in nearby[br] if x in open_now] or [x for x in open_now if x != br]
                      for br in open_now}
        others_now = {br: [x for x in open_now if x != br] for br in open_now}
        sched = defaultdict(list)          # therapist id -> [(start, end)] today

        for br in BR_IDS:
            b = BR[br]
            # opening stock for a ramping branch (Ipoh 2019-01-08, the 2024 four on 2024-01-01)
            if br in RAMP and d == opening_stock_day(br):
                for pid in avail:
                    do_purchase(folder, br, pid, d, random.randint(25, 60))
                    stocked.add((br, pid))
                    last_restock_month[(br, pid)] = (y, m)
            bw = branch_weight(br, d)
            if bw <= 0:
                continue
            pf, sf = covid(d, b["state"])
            lockdown = pf < 0.6
            # -------- product weights for this branch-day --------
            wts = []
            for pid in avail:
                w = base_pw[pid]
                cat = PROD_CAT[pid]
                if lockdown:
                    w *= {"Facial Cleanser": 1.30, "Face Mask": 1.40, "Toner": 1.10, "Serum": 0.70,
                          "Sunscreen": 0.45, "Eye Cream": 0.80, "Lip Care": 0.85,
                          "Essential Oil": 1.15, "Eye Mask": 1.10}.get(cat, 1.0)
                if hot and cat == "Sunscreen":
                    w *= 1.25
                if haze and cat in ("Face Mask", "Facial Cleanser"):
                    w *= 1.15
                if runup and cat in ("Serum", "Eye Cream", "Face Mask", "Eye Mask", "Essential Oil"):
                    w *= 1.15
                if pid >= FIRST_NEW_PID and d < LAUNCH_2025 + timedelta(days=365):
                    w *= NEW_SKU_BOOST
                wts.append(w)
            if mens_live:
                cum_f, t_f = cumulate([w * (MENS_FEMALE_TILT if pid in MENS_PRODUCTS else 1.0)
                                       for w, pid in zip(wts, avail)])
                cum_m, t_m = cumulate([w * (MENS_MALE_TILT if pid in MENS_PRODUCTS else 1.0)
                                       for w, pid in zip(wts, avail)])
            else:
                cum_f, t_f = cumulate(wts)
                cum_m, t_m = cum_f, t_f

            takers = [s for s in staff_by_br[br] if s.role not in THERAPIST_ROLES and employed(s, d)]
            therapists = [s for s in staff_by_br[br] if s.role in THERAPIST_ROLES and employed(s, d)]

            # ================= ORDERS =================
            lam = BASE_ORDERS_PER_DAY * bw * product_mult(br, y) * YEAR_GROWTH[y] * season_o * pf
            n_orders = poisson(lam)
            cross = CROSS_SHARE_ONLINE if online else CROSS_SHARE
            for _ in range(n_orders):
                if random.random() < cross:
                    if online and random.random() < ONLINE_FAR_SHARE:
                        src = random.choice(others_now[br])   # e-commerce: anywhere in the country
                    else:
                        src = random.choice(nearby_now[br])
                    cus = pools[src].pick(d)
                else:
                    cus = pools[br].pick(d)
                if cus is None or not takers:
                    stats["orders_skipped"] += 1
                    continue
                r = random.random()
                status = ("Completed" if r < 0.955 else "Cancelled" if r < 0.988
                          else "Processing" if r < 0.996 else "Pending")
                ids["order"] += 1
                oid = ids["order"]
                out.row(folder, "orders", [oid, cus.id, br, random.choice(takers).id, d, status])
                tier_disc = TIER_DISCOUNT[cus.tier]
                promo = 0.15 if mega else (0.05 if random.random() < PROMO_RATE[online] else 0.0)
                n_lines = random.choices((1, 2, 3, 4, 5), weights=(34, 31, 20, 10, 5))[0]
                cum, t = (cum_f, t_f) if cus.female else (cum_m, t_m)
                for _ln in range(n_lines):
                    pid = avail[bisect_right(cum, random.random() * t)]
                    # basket size: 1-5 units per line, bigger in a festival run-up
                    # (gifting) and biggest on mega-sale days
                    qty = random.choices((1, 2, 3, 4, 5),
                                         weights=QTY_W_MEGA if mega else QTY_W_RUNUP if runup else QTY_W)[0]
                    unit = product_price(pid, d)
                    gross = qty * unit
                    disc = round(gross * (tier_disc + promo), 2)
                    tax = round((gross - disc) * rate, 2)
                    ids["det"] += 1
                    # no unit price on the line: the price is the product's price in force on
                    # order_date (product / product_dim version), which is how the fact derives it
                    out.row(folder, "order_detail", [ids["det"], oid, pid, qty, money(disc), money(tax)])
                    if status != "Cancelled":
                        sold_since[(br, pid)] += qty

            # ================= RESERVATIONS (in-salon, local customers) =================
            if sf > 0 and therapists:
                lam_r = BASE_ORDERS_PER_DAY * RES_PER_ORDER * bw * RES_YEAR_GROWTH[y] * season_r * sf
                for _ in range(poisson(lam_r)):
                    if random.random() < CROSS_SHARE:
                        cus = pools[random.choice(nearby_now[br])].pick(d)
                    else:
                        cus = pools[br].pick(d)
                    if cus is None:
                        continue
                    hour = random.choices(list(HOUR_WEIGHT), weights=list(HOUR_WEIGHT.values()))[0]
                    start = hour * 60 + random.choice((0, 15, 30, 45))
                    mains = [s for s in MAIN_SERVICES if service_available(s, d)]
                    picks = [random.choices(mains, weights=[main_sw[s] for s in mains])[0]]
                    if random.random() < 0.36:
                        picks.append(random.choice([s for s in ADDON_SERVICES if service_available(s, d)]))
                    total_min = sum(SERV_MINUTES[s] for s in picks)
                    if start + total_min > CLOSE_MIN:
                        picks = picks[:1]
                        total_min = SERV_MINUTES[picks[0]]
                        start = min(start, CLOSE_MIN - total_min)
                        start -= start % 15
                    # find a free therapist (try 4 start slots)
                    chosen = None
                    for shift in range(4):
                        st_min = start + 15 * shift
                        if st_min + total_min > CLOSE_MIN:
                            break
                        cand = therapists[:]
                        random.shuffle(cand)
                        for tp in cand[:6]:
                            busy = sched[tp.id]
                            if all(e <= st_min or s >= st_min + total_min for s, e in busy):
                                chosen, start = tp, st_min
                                break
                        if chosen:
                            break
                    if chosen is None:
                        stats["res_dropped"] += 1
                        continue
                    r = random.random()
                    status = ("Completed" if r < 0.907 else "Cancelled" if r < 0.958
                              else "No-Show" if r < 0.988 else "Confirmed")
                    ids["res"] += 1
                    rid = ids["res"]
                    # booking_date = when the customer booked; reservation_date (= d) = the
                    # appointment day. Most bookings are made 0-7 days ahead.
                    lead = random.choices((0, 1, 2, 3, 5, 7, 10, 14), weights=(25, 20, 12, 10, 12, 10, 6, 5))[0]
                    booked = max(d - timedelta(days=lead), cus.reg)
                    out.row(folder, "reservation", [rid, cus.id, br, booked, d, status])
                    tier_disc = TIER_DISCOUNT[cus.tier]
                    extra = 0.05 if (d.weekday() < 5 and start < 15 * 60) else 0.0
                    cursor = start
                    for sv in picks:
                        mins = SERV_MINUTES[sv]
                        stt = f"{d} {cursor // 60:02d}:{cursor % 60:02d}:00"
                        endm = cursor + mins
                        ent = f"{d} {endm // 60:02d}:{endm % 60:02d}:00"
                        price = service_price(sv, d)
                        disc = round(price * (tier_disc + extra), 2)
                        tax = round((price - disc) * rate, 2)
                        ids["rdet"] += 1
                        out.row(folder, "reservation_detail",
                                [ids["rdet"], rid, chosen.id, sv, stt, ent, money(disc), money(tax)])
                        cursor = endm
                    sched[chosen.id].append((start, cursor))

            # ================= PURCHASES (restocking runs) =================
            for half in (0, 1):
                if d != restock_day(y, m, half):
                    continue
                first_run = not any((br, pid) in stocked for pid in avail)
                for pid in avail:
                    key = (br, pid)
                    if key not in stocked:                       # opening / launch stock
                        qty = random.randint(25, 60) if not first_run else \
                            max(15, int(random.uniform(30, 90) * (0.5 + bw)))
                    else:
                        if pid % 2 != half:
                            continue
                        sold = sold_since[key]
                        months_ago = (y - last_restock_month[key][0]) * 12 + m - last_restock_month[key][1]
                        if sold < 12 and months_ago < 2:
                            continue                                # slow mover: every other month
                        if sold == 0:
                            continue
                        qty = int(math.ceil(sold * 1.08)) + random.randint(0, 2)   # 8 % over + safety
                    do_purchase(folder, br, pid, d, qty)
                    stocked.add(key)
                    sold_since[key] = 0
                    last_restock_month[key] = (y, m)

        # ================= MONTH-END: salaries + branch utilities =================
        if d.day == 25:
            per = f"{y}-{m:02d}"
            for s in staff:
                if not (s.hire <= d and (s.leave is None or s.leave >= d)):
                    continue
                base = round(s.salary * INCREMENT[y] / INCREMENT.get(s.hire.year, 1.0)
                             * pay_cut(y, m) * random.uniform(0.995, 1.005), 2)
                bonus = 0.0
                if m == 12:
                    bonus += round(base * (0.5 if y in (2020, 2021) else 1.0), 2)
                if m == RAYA_BONUS_MONTH[y]:
                    bonus += round(base * (0.15 if y in (2020, 2021) else 0.35), 2)
                ded = round(base * epf_rate(y, m), 2)
                ids["sal"] += 1
                out.row(folder, "salary_payment", [ids["sal"], s.id, per, money(base), money(bonus), money(ded), d])
        if d.day == 28:
            per = f"{y}-{m:02d}"
            infl = 1.03 ** (y - 2019)
            for br in BR_IDS:
                b = BR[br]
                if date(y, m, 1) < b["open"].replace(day=1):
                    continue
                size = b["rent"] / 18500.0
                closure = CLOSURE_MONTHS.get((y, m), 1.0)
                rent = b["rent"] * infl * (0.70 if (y, m) in RENT_REBATE_MONTHS else 1.0)
                vals = {
                    1: rent,
                    2: 2400 * size * (1.12 if hot else 1.0) * infl * random.uniform(.92, 1.08) * closure,
                    3: 330 * size * infl * random.uniform(.90, 1.10) * (0.5 + 0.5 * closure),
                    4: 209 * infl,
                    5: 1650 * size * infl * random.uniform(.75, 1.30) * (0.6 + 0.4 * closure),
                    6: 410 * size * infl * random.uniform(.95, 1.05) * (0.6 + 0.4 * closure),
                }
                for util, amt in vals.items():
                    ids["exp"] += 1
                    out.row(folder, "branch_utils", [ids["exp"], br, UTIL_NAME[util], per, money(amt), d])

        day_no += 1
        if day_no % 365 == 0:
            print(f"  ... {d}  orders so far {ids['order']:,}")
        d += timedelta(days=1)

    out.close()
    print(f"done. orders {ids['order']:,}  lines {ids['det']:,}  reservations {ids['res']:,} "
          f"res lines {ids['rdet']:,}  purchases {ids['pur']:,}  salary {ids['sal']:,}  utils {ids['exp']:,}")
    print(f"  reservations dropped for lack of a free therapist: {stats['res_dropped']:,}; "
          f"orders skipped (no customer yet): {stats['orders_skipped']:,}")
    print("\nrows per folder:")
    for name, _, _ in FOLDERS:
        print(f"  {name}: " + ", ".join(f"{t} {out.rows[(name, t)]:,}" for t in HEADERS))


# ===================================================================
# VERIFY  (re-reads the CSVs from disk, independent of the generator state)
# ===================================================================
def verify():
    problems = []

    def rd(folder, table):
        with open(os.path.join(ROOT, folder, table + ".csv"), newline="", encoding="utf-8") as f:
            r = csv.reader(f)
            hdr = next(r)
            if hdr != HEADERS[table]:
                problems.append(f"{folder}/{table}: header differs")
            return list(r)

    branch, staff, cust, prod, prod_brand, serv, sup = {}, {}, {}, {}, {}, {}, {}
    branch_folder, sup_from = {}, {}
    orders, res = {}, {}
    per_folder_ids = defaultdict(list)
    counts = defaultdict(int)
    D = lambda s: date.fromisoformat(s)
    fidx = {f[0]: i for i, f in enumerate(FOLDERS)}

    def check_ids(folder, table, rows, col=0):
        if not rows:
            return
        first, last = int(rows[0][col]), int(rows[-1][col])
        if last - first + 1 != len(rows):
            problems.append(f"{folder}/{table}: ids not contiguous")
        per_folder_ids[table].append((folder, first, last))

    stat = dict(orders_by_year=defaultdict(int), orders_by_branch=defaultdict(int),
                orders_by_state=defaultdict(int), res_by_year=defaultdict(int),
                orders_by_month=defaultdict(int), res_by_month=defaultdict(int),
                orders_by_wd=defaultdict(int), rev_prod=defaultdict(float), rev_serv=defaultdict(float),
                rev_q=defaultdict(float), cus_same_city=0, cus_same_state=0, cus_total=0,
                cross_city_by_year=defaultdict(int), cross_state_by_year=defaultdict(int),
                res_by_branch=defaultdict(int), staff_status=defaultdict(int), tier=defaultdict(int),
                pur_by_year=defaultdict(int), sal_by_year=defaultdict(int), reg_by_year=defaultdict(int),
                male_reg_by_year=defaultdict(int), st_by_folder=defaultdict(int),
                orders_by_status=defaultdict(int), res_by_status=defaultdict(int),
                era_lines=defaultdict(int), epf=defaultdict(set),
                rev=defaultdict(float), cogs=defaultdict(float), payroll=defaultdict(float),
                utils=defaultdict(float), mens_rev=defaultdict(float), mens_lines=0, mens_lines_male=0,
                mens_before_launch=0, pairs=defaultdict(int), rev_branch=defaultdict(float))
    zero_res_windows = [(date(2020, 3, 18), date(2020, 5, 3)), (date(2021, 6, 1), date(2021, 8, 31))]
    order_cust = {}

    for folder, a, b in FOLDERS:
        rows = rd(folder, "branch")
        for r in rows:
            branch[int(r[0])] = dict(state=r[4], city=r[3], open=D(r[8]))
            branch_folder[int(r[0])] = folder
        counts[(folder, "branch")] = len(rows)
        for r in rd(folder, "supplier"):
            sup[int(r[0])] = r
            sup_from[int(r[0])] = a
            counts[(folder, "supplier")] += 1
        for r in rd(folder, "product"):
            prod[int(r[0])] = float(r[5])
            prod_brand[int(r[0])] = r[2]
            counts[(folder, "product")] += 1
        for r in rd(folder, "service"):
            serv[int(r[0])] = float(r[4])
            counts[(folder, "service")] += 1
        rows = rd(folder, "staff")
        check_ids(folder, "staff", rows)
        for r in rows:
            sid, br = int(r[0]), int(r[1])
            if br not in branch:
                problems.append(f"staff {sid}: branch {br} unknown")
            elif r[6] != branch[br]["city"] or r[7] != branch[br]["state"]:
                problems.append(f"staff {sid}: city/state differs from branch")
            elif fidx[folder] < fidx[branch_folder[br]]:
                problems.append(f"staff {sid}: shipped in {folder} before its branch ({branch_folder[br]})")
            if r[14] not in ("Active", "Resigned", "Inactive") or r[10] not in ("Male", "Female"):
                problems.append(f"staff {sid}: bad status/gender")
            if r[4] not in ("Branch Manager", "Senior Therapist", "Beauty Therapist",
                            "Sales Assistant", "Receptionist", "Cashier"):
                problems.append(f"staff {sid}: position {r[4]}")
            staff[sid] = dict(br=br, hire=D(r[13]), role=r[4], status=r[14])
            stat["staff_status"][r[14]] += 1
            stat["st_by_folder"][folder] += 1
        counts[(folder, "staff")] = len(rows)
        rows = rd(folder, "customer")
        check_ids(folder, "customer", rows)
        for r in rows:
            cid = int(r[0])
            reg, dob = D(r[12]), D(r[5])
            # no cus_age column - age is derived from cus_DOB
            age_at_reg = reg.year - dob.year - ((reg.month, reg.day) < (dob.month, dob.day))
            if not (18 <= age_at_reg <= 62):
                problems.append(f"customer {cid}: age at registration {age_at_reg}")
            if r[3] not in ("Male", "Female"):
                problems.append(f"customer {cid}: gender")
            cust[cid] = dict(reg=reg, city=r[9], state=r[10], tier=r[7], male=(r[3] == "Male"))
            stat["tier"][r[7]] += 1
            stat["reg_by_year"][reg.year] += 1
            if r[3] == "Male":
                stat["male_reg_by_year"][reg.year] += 1
        counts[(folder, "customer")] = len(rows)

        rows = rd(folder, "orders")
        check_ids(folder, "orders", rows)
        counts[(folder, "orders")] = len(rows)
        for r in rows:
            oid, cid, br, sid, od, stt = int(r[0]), int(r[1]), int(r[2]), int(r[3]), D(r[4]), r[5]
            if not (a <= od <= b):
                problems.append(f"order {oid}: date {od} outside {folder}")
            if cid not in cust:
                problems.append(f"order {oid}: customer {cid} unknown")
            elif cust[cid]["reg"] > od:
                problems.append(f"order {oid}: before customer registration")
            if br not in branch or branch[br]["open"] > od:
                problems.append(f"order {oid}: branch {br} not open")
            if sid not in staff or staff[sid]["br"] != br:
                problems.append(f"order {oid}: staff {sid} not at branch {br}")
            elif staff[sid]["hire"] > od:
                problems.append(f"order {oid}: staff {sid} not yet hired")
            if stt not in ("Pending", "Processing", "Completed", "Cancelled"):
                problems.append(f"order {oid}: status {stt}")
            orders[oid] = (od, stt, br)
            order_cust[oid] = cid
            stat["orders_by_year"][od.year] += 1
            stat["orders_by_branch"][br] += 1
            stat["orders_by_state"][branch[br]["state"]] += 1
            stat["orders_by_month"][(od.year, od.month)] += 1
            stat["orders_by_wd"][od.weekday()] += 1
            stat["orders_by_status"][stt] += 1
            stat["cus_total"] += 1
            if cid in cust:
                if cust[cid]["city"] == branch[br]["city"]:
                    stat["cus_same_city"] += 1
                else:
                    stat["cross_city_by_year"][od.year] += 1
                if cust[cid]["state"] == branch[br]["state"]:
                    stat["cus_same_state"] += 1
                else:
                    stat["cross_state_by_year"][od.year] += 1
        rows = rd(folder, "order_detail")
        check_ids(folder, "order_detail", rows)
        counts[(folder, "order_detail")] = len(rows)
        pairs = set()
        for r in rows:
            did, oid, pid, qty, disc, tax = int(r[0]), int(r[1]), int(r[2]), int(r[3]), float(r[4]), float(r[5])
            if oid not in orders:
                problems.append(f"order_detail {did}: order {oid} unknown")
                continue
            od, stt, br = orders[oid]
            pairs.add((oid, pid))
            if pid not in prod:
                problems.append(f"order_detail {did}: product {pid} unknown")
            if pid >= FIRST_NEW_PID and od < LAUNCH_2025:
                problems.append(f"order_detail {did}: product {pid} sold before launch")
                stat["mens_before_launch"] += 1
            unit = product_price(pid, od)          # price of the era, as the fact derives it
            if qty <= 0:
                problems.append(f"order_detail {did}: qty")
            gross = qty * unit
            exp_tax = round((gross - disc) * tax_rate(od), 2)
            if abs(tax - exp_tax) > 0.011:
                problems.append(f"order_detail {did}: tax {tax} expected {exp_tax} (price era / discount)")
            era = "2025" if od >= date(2025, 1, 1) else "2024" if od >= date(2024, 1, 1) else "base"
            if pid in PRICE_RISE_2024 or pid in PRICE_RISE_2025:
                stat["era_lines"][era] += 1
            if stt == "Completed":
                stat["rev_prod"][od.year] += gross - disc
                stat["rev_q"][(od.year, (od.month - 1) // 3 + 1, "p")] += gross - disc
                stat["rev"][(br, od.year)] += gross - disc
                stat["rev_branch"][br] += gross - disc
                if pid in MENS_PRODUCTS:
                    stat["mens_rev"][od.year] += gross - disc
                    stat["mens_lines"] += 1
                    if cust.get(order_cust[oid], {}).get("male"):
                        stat["mens_lines_male"] += 1
        stat["pairs"][folder] = len(pairs)

        rows = rd(folder, "reservation")
        check_ids(folder, "reservation", rows)
        counts[(folder, "reservation")] = len(rows)
        for r in rows:
            rid, cid, br, bkd, bd, stt = int(r[0]), int(r[1]), int(r[2]), D(r[3]), D(r[4]), r[5]
            if not (a <= bd <= b):
                problems.append(f"reservation {rid}: reservation date outside {folder}")
            if not (bkd <= bd <= bkd + timedelta(days=14)):
                problems.append(f"reservation {rid}: booking_date {bkd} vs reservation_date {bd}")
            if cid not in cust or cust[cid]["reg"] > bkd:
                problems.append(f"reservation {rid}: customer {cid} bad/unregistered at booking")
            if br not in branch or branch[br]["open"] > bd:
                problems.append(f"reservation {rid}: branch {br} not open")
            for za, zb in zero_res_windows:
                if za <= bd <= zb:
                    problems.append(f"reservation {rid}: booked while salons closed ({bd})")
            if stt not in ("Booked", "Confirmed", "Completed", "Cancelled", "No-Show"):
                problems.append(f"reservation {rid}: status {stt}")
            res[rid] = (bd, stt, br)
            stat["res_by_year"][bd.year] += 1
            stat["res_by_month"][(bd.year, bd.month)] += 1
            stat["res_by_branch"][br] += 1
            stat["res_by_status"][stt] += 1
        rows = rd(folder, "reservation_detail")
        check_ids(folder, "reservation_detail", rows)
        counts[(folder, "reservation_detail")] = len(rows)
        busy = defaultdict(list)
        for r in rows:
            did, rid, sid, sv, st_s, en_s, disc, tax = int(r[0]), int(r[1]), int(r[2]), int(r[3]), r[4], r[5], float(r[6]), float(r[7])
            if rid not in res:
                problems.append(f"reservation_detail {did}: reservation {rid} unknown")
                continue
            bd, stt, br = res[rid]
            if sid not in staff or staff[sid]["br"] != br or staff[sid]["hire"] > bd:
                problems.append(f"reservation_detail {did}: staff {sid} wrong branch / not hired")
            elif "Therapist" not in staff[sid]["role"]:
                problems.append(f"reservation_detail {did}: staff {sid} is not a therapist")
            if sv not in serv:
                problems.append(f"reservation_detail {did}: service {sv} unknown")
            if sv >= 17 and bd < NEW_SERVICE_LAUNCH:
                problems.append(f"reservation_detail {did}: service {sv} before launch")
            sd, stime = st_s.split(" ")
            ed, etime = en_s.split(" ")
            if sd != str(bd) or ed != str(bd):
                problems.append(f"reservation_detail {did}: timestamp date differs from booking date")
            smin = int(stime[:2]) * 60 + int(stime[3:5])
            emin = int(etime[:2]) * 60 + int(etime[3:5])
            if not (10 * 60 <= smin < emin <= 20 * 60):
                problems.append(f"reservation_detail {did}: time window {st_s}-{en_s}")
            if emin - smin != SERV_MINUTES[sv]:
                problems.append(f"reservation_detail {did}: duration")
            price = service_price(sv, bd)
            if abs(tax - round((price - disc) * tax_rate(bd), 2)) > 0.011:
                problems.append(f"reservation_detail {did}: tax does not match era price")
            busy[(sid, bd)].append((smin, emin, did))
            if stt == "Completed":
                stat["rev_serv"][bd.year] += price - disc
                stat["rev_q"][(bd.year, (bd.month - 1) // 3 + 1, "s")] += price - disc
                stat["rev"][(br, bd.year)] += price - disc
                stat["rev_branch"][br] += price - disc
        for (sid, bd), lst in busy.items():
            lst.sort()
            for i in range(1, len(lst)):
                if lst[i][0] < lst[i - 1][1]:
                    problems.append(f"therapist {sid} double-booked on {bd} ({lst[i - 1][2]}, {lst[i][2]})")

        rows = rd(folder, "purchase")
        check_ids(folder, "purchase", rows)
        counts[(folder, "purchase")] = len(rows)
        for r in rows:
            pid_, prd, br, sp, qty, pd, cost = int(r[0]), int(r[1]), int(r[2]), int(r[3]), int(r[4]), D(r[5]), float(r[6])
            if prd not in prod or br not in branch or sp not in sup:
                problems.append(f"purchase {pid_}: FK")
                continue
            if pd < sup_from[sp] or pd < SUPPLIER_FROM.get(sp, START):
                problems.append(f"purchase {pid_}: supplier {sp} before onboarding")
            if prd >= FIRST_NEW_PID and pd < LAUNCH_2025:
                problems.append(f"purchase {pid_}: product before launch")
            if pd < branch[br]["open"] - timedelta(days=7):
                problems.append(f"purchase {pid_}: branch {br} not open")
            if (br == IPOH) != (sp == IPOH_SUPPLIER):
                problems.append(f"purchase {pid_}: Ipoh must buy only from supplier {IPOH_SUPPLIER} (br {br}, sup {sp})")
            if sp == 8 and prod_brand[prd] != "HIM Essentials":
                problems.append(f"purchase {pid_}: supplier 8 only supplies HIM Essentials")
            shelf = product_price(prd, pd)
            lo, hi = cost_ratio(br, pd)
            if not ((lo - 0.01) * shelf <= cost <= (hi + 0.01) * shelf):
                problems.append(f"purchase {pid_}: cost {cost} vs shelf {shelf} (br {br})")
            if qty <= 0:
                problems.append(f"purchase {pid_}: qty")
            stat["pur_by_year"][pd.year] += 1
            stat["cogs"][(br, pd.year)] += qty * cost
        rows = rd(folder, "salary_payment")
        check_ids(folder, "salary_payment", rows)
        counts[(folder, "salary_payment")] = len(rows)
        for r in rows:
            sp_id, sid, per, base, bonus, ded, pd = int(r[0]), int(r[1]), r[2], float(r[3]), float(r[4]), float(r[5]), D(r[6])
            if sid not in staff or staff[sid]["hire"] > pd:
                problems.append(f"salary {sp_id}: staff {sid} unknown / before hire")
                continue
            if per != f"{pd.year}-{pd.month:02d}":
                problems.append(f"salary {sp_id}: period")
            if pd < branch[staff[sid]["br"]]["open"] - timedelta(days=45):
                problems.append(f"salary {sp_id}: paid long before branch {staff[sid]['br']} opened")
            stat["sal_by_year"][pd.year] += 1
            stat["epf"][(pd.year, pd.month)].add(round(ded / base, 2))
            stat["payroll"][(staff[sid]["br"], pd.year)] += base + bonus
        rows = rd(folder, "branch_utils")
        check_ids(folder, "branch_utils", rows)
        counts[(folder, "branch_utils")] = len(rows)
        for r in rows:
            eid, br, ut, per, amt, pd = int(r[0]), int(r[1]), r[2], r[3], float(r[4]), D(r[5])
            if br not in branch or ut not in UTIL_NAME.values():
                problems.append(f"branch_utils {eid}: FK / unknown util_name")
                continue
            if date(int(per[:4]), int(per[5:]), 1) < branch[br]["open"].replace(day=1):
                problems.append(f"branch_utils {eid}: before branch opened")
            stat["utils"][(br, pd.year)] += amt

    # id continuity across folders
    for table, lst in per_folder_ids.items():
        for i in range(1, len(lst)):
            if lst[i][1] != lst[i - 1][2] + 1:
                problems.append(f"{table}: {lst[i][0]} starts at {lst[i][1]}, previous ended {lst[i-1][2]}")
        if lst and lst[0][1] != 1:
            problems.append(f"{table}: first id is {lst[0][1]}")

    # ---- report ----
    years = list(range(2019, 2026))
    print("\n==================== VERIFICATION ====================")
    print(f"problems found: {len(problems)}")
    for p in problems[:40]:
        print("  ", p)
    print("\nrow counts per folder / table")
    for name, _, _ in FOLDERS:
        print(f"  {name}")
        for t in HEADERS:
            print(f"     {t:24s} {counts[(name, t)]:>10,}")
    print("distinct (order, product) pairs per folder (= order_fact rows):", dict(stat["pairs"]))
    print("\norders by year          :", dict(sorted(stat["orders_by_year"].items())))
    print("reservations by year    :", dict(sorted(stat["res_by_year"].items())))
    print("purchases by year       :", dict(sorted(stat["pur_by_year"].items())))
    print("salary rows by year     :", dict(sorted(stat["sal_by_year"].items())))
    print("registrations by year   :", dict(sorted(stat["reg_by_year"].items())))
    print("male share of regs      :", {y: f"{stat['male_reg_by_year'][y] / max(1, stat['reg_by_year'][y]):.0%}"
                                        for y in sorted(stat["reg_by_year"]) if y >= 2019})
    print("orders by weekday       :", [stat["orders_by_wd"][i] for i in range(7)])
    print("orders by status        :", dict(stat["orders_by_status"]))
    print("reservations by status  :", dict(stat["res_by_status"]))
    print("staff status            :", dict(stat["staff_status"]), " per folder", dict(stat["st_by_folder"]))
    print("customer tiers          :", dict(stat["tier"]))
    print(f"orders in customer's own city: {stat['cus_same_city'] / max(1, stat['cus_total']):.1%}   "
          f"own state: {stat['cus_same_state'] / max(1, stat['cus_total']):.1%}")
    print("cross-city order share  :", {y: f"{stat['cross_city_by_year'][y] / max(1, stat['orders_by_year'][y]):.0%}"
                                        for y in years})
    print("cross-state order share :", {y: f"{stat['cross_state_by_year'][y] / max(1, stat['orders_by_year'][y]):.0%}"
                                        for y in years})
    print("price-era lines (uplifted products):", dict(stat["era_lines"]))
    print("EPF rates seen          :", {k: sorted(v) for k, v in sorted(stat["epf"].items()) if k[1] in (1, 4, 7)})
    print(f"men's line: 2025 product revenue share {stat['mens_rev'][2025] / max(1, stat['rev_prod'][2025]):.1%}, "
          f"lines bought by men {stat['mens_lines_male'] / max(1, stat['mens_lines']):.0%}, "
          f"lines before launch {stat['mens_before_launch']}")
    print("\norders by branch (all years):")
    for br, n in sorted(stat["orders_by_branch"].items(), key=lambda kv: -kv[1]):
        print(f"   {br:2d} {branch[br]['city']:14s} {branch[br]['state']:33s} {n:>8,}   res {stat['res_by_branch'][br]:>7,}"
              f"   revenue {stat['rev_branch'][br] / 1e6:6.2f}m")
    print("orders by state:", dict(sorted(stat["orders_by_state"].items(), key=lambda kv: -kv[1])))
    print("\nrevenue (RM, completed, gross - discount, excl. tax):")
    for yy in years:
        print(f"   {yy}: product {stat['rev_prod'][yy]/1e6:6.2f}m  service {stat['rev_serv'][yy]/1e6:6.2f}m  "
              f"total {(stat['rev_prod'][yy]+stat['rev_serv'][yy])/1e6:6.2f}m")
    print("\nrevenue by quarter (total, RM m) and quarter share:")
    for yy in years:
        qs = [stat["rev_q"][(yy, q, "p")] + stat["rev_q"][(yy, q, "s")] for q in (1, 2, 3, 4)]
        tot = sum(qs) or 1
        print(f"   {yy}: " + "  ".join(f"Q{q} {v/1e6:5.2f}m ({v/tot:4.0%})" for q, v in zip((1, 2, 3, 4), qs)))

    # ---- P&L per branch per year ----
    print("\nP&L per branch per year (RM '000; profit = revenue - purchases - payroll(base+bonus) - utilities):")
    pj_ok, ipoh_ok = True, True
    for yy in years:
        rows_ = []
        for br in sorted(branch):
            rv = stat["rev"][(br, yy)]
            if rv <= 0 and stat["payroll"][(br, yy)] <= 0:
                continue
            cg, pr, ut = stat["cogs"][(br, yy)], stat["payroll"][(br, yy)], stat["utils"][(br, yy)]
            rows_.append((br, rv, cg, pr, ut, rv - cg - pr - ut))
        rows_.sort(key=lambda x: -x[1])
        print(f"  {yy}   branch            revenue   purchases   payroll   utilities    profit  margin")
        for br, rv, cg, pr, ut, pf in rows_:
            print(f"        {br:2d} {branch[br]['city']:13s} {rv/1e3:9,.0f} {cg/1e3:11,.0f} {pr/1e3:9,.0f} "
                  f"{ut/1e3:11,.0f} {pf/1e3:9,.0f} {pf / rv if rv else 0:7.1%}")
        T = [sum(x[i] for x in rows_) for i in range(1, 6)]
        print(f"        == company       {T[0]/1e3:9,.0f} {T[1]/1e3:11,.0f} {T[2]/1e3:9,.0f} "
              f"{T[3]/1e3:11,.0f} {T[4]/1e3:9,.0f} {T[4] / T[0] if T[0] else 0:7.1%}")
        if rows_ and rows_[0][0] != PJ:
            pj_ok = False
            print(f"        WARN: top branch in {yy} is {branch[rows_[0][0]]['city']}, not Petaling Jaya")
        ip = next((x for x in rows_ if x[0] == IPOH), None)
        if ip:
            want_neg = yy >= 2024
            if (ip[5] < 0) != want_neg and yy not in (2020, 2021):
                ipoh_ok = False
                print(f"        WARN: Ipoh margin {ip[5] / ip[1]:.1%} in {yy} (target {'< 0' if want_neg else '>= 0'})")
    print("\nprofit matrix (RM '000), branch x year:")
    print("        " + "".join(f"{yy:>9d}" for yy in years))
    for br in sorted(branch):
        vals = [stat["rev"][(br, yy)] - stat["cogs"][(br, yy)] - stat["payroll"][(br, yy)] - stat["utils"][(br, yy)]
                for yy in years]
        print(f"   {br:2d} {branch[br]['city'][:12]:12s}" + "".join(f"{v/1e3:9,.0f}" if stat["rev"][(br, yy)] else f"{'-':>9s}"
                                                                    for v, yy in zip(vals, years)))
    print(f"pattern checks: PJ #1 every year: {'OK' if pj_ok else 'NO'}; "
          f"Ipoh sign 2019-23 >= 0 / 2024-25 < 0 (COVID years excused): {'OK' if ipoh_ok else 'NO'}")
    print("\norders / reservations by month:")
    for yy in years:
        print(f"   {yy} orders : " + " ".join(f"{stat['orders_by_month'][(yy, mm)]:>6,}" for mm in range(1, 13)))
        print(f"   {yy} res    : " + " ".join(f"{stat['res_by_month'][(yy, mm)]:>6,}" for mm in range(1, 13)))
    return len(problems)


if __name__ == "__main__":
    if "--verify" not in sys.argv:
        generate()
    n = verify()
    sys.exit(1 if n else 0)
