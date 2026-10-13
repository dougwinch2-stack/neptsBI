"""
Generates sql/02_demo_data.sql – the neptsBI demo "starting story".

Every date is written as  current_date + N  so the data is correct for
whatever day it is loaded; the rolling clock keeps it current after that.
Random choices use a fixed seed, so re-running gives the same story.

Run:  python3 tools/make_demo_data.py
"""
import random
from datetime import date, timedelta
from pathlib import Path

rng = random.Random(20261013)
T = date(2026, 10, 13)          # reference "today" used only to work out offsets
OUT = Path(__file__).resolve().parent.parent / "sql" / "02_demo_data.sql"


def off(d):                      # date -> "current_date + N" expression
    n = (d - T).days
    return f"current_date {'+' if n >= 0 else '-'} {abs(n)}"


def q(s):
    return "null" if s is None else "'" + str(s).replace("'", "''") + "'"


def add_years(d, n):
    try:
        return d.replace(year=d.year + n)
    except ValueError:           # 29 Feb
        return d.replace(year=d.year + n, day=28)


# ---------------------------------------------------------------- organisation
REGIONS = ["Essex", "Region X", "Region Y"]
# (base, region, vans) – Essex numbers are real (Doug); X/Y are made up
BASES = [
    ("Canvey", "Essex", 100), ("Chelmsford", "Essex", 66), ("Southend", "Essex", 34),
    ("Base X1", "Region X", 42), ("Base X2", "Region X", 28),
    ("Base Y1", "Region Y", 30), ("Base Y2", "Region Y", 20),
]

CLASSES = [  # name, short, share of fleet
    ("Patient Transport Ambulance", "PTS", 0.74),
    ("Wheelchair Accessible Vehicle", "WAV", 0.17),
    ("High Dependency Ambulance", "HDU", 0.05),
    ("Bariatric Ambulance", "BAR", 0.04),
]
MODELS = {   # (make, model, weight) per class
    "PTS": [("Mercedes-Benz", "Sprinter", 45), ("Renault", "Master", 30),
            ("Fiat", "Ducato", 15), ("Ford", "Transit", 10)],
    "WAV": [("Peugeot", "Boxer", 40), ("Ford", "Transit", 35), ("Renault", "Master", 25)],
    "HDU": [("Mercedes-Benz", "Sprinter", 80), ("Volkswagen", "Crafter", 20)],
    "BAR": [("Mercedes-Benz", "Sprinter", 70), ("Renault", "Master", 30)],
}
LESSORS = ["Arrow Vehicle Leasing (demo)", "Meridian Fleet Finance (demo)"]

CENTRES = [  # name, location
    ("Canvey Commercial Testing", "Canvey Island, Essex"),
    ("Chelmsford Fleet Services", "Chelmsford, Essex"),
    ("Southend Vehicle Test Centre", "Southend-on-Sea, Essex"),
    ("Essex Commercial MOT Centre", "Basildon, Essex"),
    ("Region X Test Centre", "Region X (demo)"),
    ("Region Y Commercial MOT", "Region Y (demo)"),
]
HOME_CENTRE = {"Canvey": 0, "Chelmsford": 1, "Southend": 2,
               "Base X1": 4, "Base X2": 4, "Base Y1": 5, "Base Y2": 5}

ADVISORIES = [
    "Nearside front tyre worn close to legal limit",
    "Offside front tyre worn close to legal limit",
    "Front brake disc worn, pitted or scored, but not seriously weakened",
    "Rear brake pads wearing thin",
    "Brake pipe slightly corroded",
    "Oil leak, but not excessive",
    "Exhaust has a minor leak of exhaust gases",
    "Suspension arm pin or bush worn but not resulting in excessive movement",
    "Registration plate deteriorated but not likely to be misread",
    "Windscreen damaged but not adversely affecting driver's view",
    "Wheel bearing has slight play",
    "Side step slightly damaged",
]
FAILURES = [
    "Headlamp aim too high",
    "Brake pad(s) less than 1.5 mm thick",
    "Tyre tread depth below requirements of 1.6 mm",
    "Wiper blade defective",
    "Stop lamp not working",
    "Brake disc significantly worn",
    "Seat belt anchorage insecure",
    "Registration plate lamp inoperative",
]

# ---------------------------------------------------------------- vehicles
vehicles = []
num = 0
for base, region, count in BASES:
    for i in range(count):
        num += 1
        r = rng.random()
        cls = "PTS" if r < 0.74 else "WAV" if r < 0.91 else "HDU" if r < 0.96 else "BAR"
        options = MODELS[cls]
        make, model, _ = rng.choices(options, weights=[o[2] for o in options])[0]
        # Age: mostly 2–6 years old, a few new and a few old timers
        age_days = int(rng.triangular(120, 3300, 1500))
        first_reg = T - timedelta(days=age_days)
        fuel = "Diesel"
        if cls in ("PTS", "WAV") and age_days < 1100 and rng.random() < 0.12:
            fuel = "Electric"
            if make in ("Fiat", "Peugeot", "Renault"):
                model = "e-" + model if make != "Renault" else "Master E-Tech"
            elif make == "Ford":
                model = "E-Transit"
            elif make == "Mercedes-Benz":
                model = "eSprinter"
        leased = age_days < 1600 and rng.random() < 0.8 or rng.random() < 0.1
        lease_end = add_years(first_reg, rng.choice([4, 5])) if leased else None
        annual = rng.randint(22000, 38000) * (0.85 if fuel == "Electric" else 1)
        vehicles.append(dict(
            reg=f"AMB{num:03d}", fleet=f"FLT{num:03d}", make=make, model=model, cls=cls,
            base=base, region=region, first_reg=first_reg, fuel=fuel,
            ownership="Leased" if leased else "Owned",
            lessor=rng.choice(LESSORS) if leased else None, lease_end=lease_end,
            annual=annual,
        ))

# ---------------------------------------------------------------- MOT history
# Planted story (see SETUP.md "demo story"):
PLANTED_OVERDUE = {   # reg: (days overdue, booking in N days or None, note)
    "AMB017": (6, 1, "Off road until MOT – priority slot"),
    "AMB058": (2, None, None),
    "AMB183": (11, 3, "Off road – awaiting parts before test"),
    "AMB224": (4, 2, "Off road until MOT"),
}

tests = []      # dicts
bookings = []

for v in vehicles:
    base_centre = HOME_CENTRE[v["base"]]
    planted = PLANTED_OVERDUE.get(v["reg"])
    target = None
    if planted:
        # Line the registration anniversary up so the certificate ran out N days ago
        target = T - timedelta(days=planted[0])
        years = max(3, round((T - v["first_reg"]).days / 365))
        v["first_reg"] = add_years(target, -years)
    due = add_years(v["first_reg"], 3)          # first MOT due

    def mileage_on(d):
        days = (d - v["first_reg"]).days
        return int(v["annual"] * days / 365 * rng.uniform(0.97, 1.03))

    while True:
        if target and due >= target:
            break                                   # planted: not re-tested yet
        # Usually tested in the month before expiry; sometimes early (resets the anniversary)
        early = not target and rng.random() < 0.08
        test_day = due - timedelta(days=rng.randint(35, 70) if early else rng.randint(0, 26))
        if test_day > T:
            break
        centre = base_centre if rng.random() < 0.85 else rng.randrange(len(CENTRES))
        failed = not target and rng.random() < 0.11
        if failed:
            tests.append(dict(v=v, date=test_day, result="Fail", expiry=None,
                              mileage=mileage_on(test_day), centre=centre,
                              fails="|".join(rng.sample(FAILURES, rng.choice([1, 1, 2]))),
                              adv=None))
            test_day = test_day + timedelta(days=rng.randint(1, 6))
            if test_day > T:
                break
        if early or test_day > due:
            expiry = add_years(test_day, 1) - timedelta(days=1)
        else:
            expiry = add_years(due, 1)
        adv = None
        if rng.random() < 0.38:
            adv = "|".join(rng.sample(ADVISORIES, rng.choice([1, 1, 2, 3])))
        tests.append(dict(v=v, date=test_day, result="Pass", expiry=expiry,
                          mileage=mileage_on(test_day), centre=centre, fails=None, adv=adv))
        due = expiry

    if planted and planted[1] is not None:
        bookings.append(dict(v=v, date=T + timedelta(days=planted[1]), centre=base_centre,
                             notes=planted[2]))

# Vehicles whose MOT is due within 30 days: book about 60% of them
for v in vehicles:
    if v["reg"] in PLANTED_OVERDUE:
        continue
    vt = [t for t in tests if t["v"] is v and t["result"] == "Pass"]
    due = vt[-1]["expiry"] if vt else add_years(v["first_reg"], 3)
    days = (due - T).days
    if 0 <= days <= 30 and rng.random() < 0.6:
        bdays = rng.randint(1, max(1, days - 1)) if days > 1 else 0
        bookings.append(dict(v=v, date=T + timedelta(days=bdays),
                             centre=HOME_CENTRE[v["base"]], notes=None))

# ---------------------------------------------------------------- people
people = [  # code, name, role, region, base, featured
    ("ceo", "Chief Executive", "ceo", None, None, True),
    ("delivery", "Head of Delivery", "delivery", None, None, True),
    ("region-essex", "Regional Manager – Essex", "region", "Essex", None, True),
    ("region-x", "Regional Manager – Region X", "region", "Region X", None, False),
    ("region-y", "Regional Manager – Region Y", "region", "Region Y", None, False),
]
for base, region, _ in BASES:
    slug = base.lower().replace(" ", "-")
    people.append((f"base-{slug}", f"{base} Base Manager", "base", region, base, base == "Canvey"))
people.append(("admin", "Fleet Administrator", "admin", None, None, True))
d = 0
for base, region, count in BASES:
    for i in range(3 if region == "Essex" else 2):
        d += 1
        people.append((f"driver-{d:03d}", f"Driver {d:03d}", "driver", region, base, d == 1))
people.append(("training", "Training Manager", "training", None, None, True))

# ---------------------------------------------------------------- write SQL
L = []
w = L.append
w("-- =====================================================================")
w("-- neptsBI · 02_demo_data.sql   (run after 01_schema.sql)")
w("-- GENERATED by tools/make_demo_data.py – don't edit by hand, re-run the script.")
w("-- All dummy data. Dates are relative to the day it is loaded.")
w("-- =====================================================================")
w("set search_path = neptsbi, public;")
w("begin;")
w("")
w("insert into demo_clock (data_date) values (current_date);")
w("")
w("insert into regions (name, sort) values")
w(",\n".join(f"  ({q(n)}, {i})" for i, n in enumerate(REGIONS)) + ";")
w("")
w("insert into bases (region_id, name, sort)\nselect r.id, v.name, v.sort from (values")
w(",\n".join(f"  ({q(b)}, {q(r)}, {i})" for i, (b, r, _) in enumerate(BASES)))
w(") as v(name, region, sort) join regions r on r.name = v.region;")
w("")
w("insert into vehicle_classes (name, short, sort) values")
w(",\n".join(f"  ({q(n)}, {q(s)}, {i})" for i, (n, s, _) in enumerate(CLASSES)) + ";")
w("")
w("insert into rules (key, value, unit, label, description) values")
w(",\n".join([
    "  ('mot_warning_days', 30, 'days', 'MOT warning', 'Show an MOT as Due soon this many days before it runs out')",
    "  ('service_months', 6, 'months', 'Service interval (time)', 'Service due after this many months – whichever comes first')",
    "  ('service_miles', 12000, 'miles', 'Service interval (miles)', 'Service due after this many miles – whichever comes first')",
]) + ";")
w("")
w("insert into roles (key, label, scope, can_record, available, description, sort) values")
w(",\n".join([
    "  ('ceo', 'Chief Executive', 'company', false, true, 'The whole company at a glance', 0)",
    "  ('delivery', 'Head of Delivery', 'company', true, true, 'Every region and base, with detail', 1)",
    "  ('region', 'Regional Manager', 'region', true, true, 'Their bases: where the risk is', 2)",
    "  ('base', 'Base Manager', 'base', true, true, 'Their base today: overdue and due soon', 3)",
    "  ('admin', 'Fleet Administrator', 'company', true, true, 'Keeps the records up to date', 4)",
    "  ('driver', 'Driver / Crew', 'self', false, true, 'Today''s checks and how-tos', 5)",
    "  ('training', 'Training Manager', 'company', false, false, 'Training due and course results', 6)",
]) + ";")
w("")
w("insert into people (code, name, role_key, region_id, base_id, featured, sort)")
w("select v.code, v.name, v.role_key, r.id, b.id, v.featured, v.sort from (values")
w(",\n".join(f"  ({q(c)}, {q(n)}, {q(role)}, {q(rg)}, {q(bs)}, {'true' if f else 'false'}, {i})"
             for i, (c, n, role, rg, bs, f) in enumerate(people)))
w(") as v(code, name, role_key, region, base, featured, sort)")
w("left join regions r on r.name = v.region left join bases b on b.name = v.base;")
w("")
w("insert into mot_centres (name, location) values")
w(",\n".join(f"  ({q(n)}, {q(l)})" for n, l in CENTRES) + ";")
w("")
w("insert into vehicles (registration, fleet_number, make, model, class_id, base_id, first_registered,")
w("                      fuel, ownership, lessor, lease_end, demo_seed)")
w("select v.reg, v.fleet, v.make, v.model, c.id, b.id, v.first_reg, v.fuel, v.ownership, v.lessor, v.lease_end, true")
w("from (values")
w(",\n".join(
    f"  ({q(v['reg'])}, {q(v['fleet'])}, {q(v['make'])}, {q(v['model'])}, {q(v['cls'])}, {q(v['base'])}, "
    f"{off(v['first_reg'])}, {q(v['fuel'])}, {q(v['ownership'])}, {q(v['lessor'])}, "
    f"{off(v['lease_end']) if v['lease_end'] else 'null::date'})"
    for v in vehicles))
w(") as v(reg, fleet, make, model, cls, base, first_reg, fuel, ownership, lessor, lease_end)")
w("join vehicle_classes c on c.short = v.cls join bases b on b.name = v.base;")
w("")
tests.sort(key=lambda t: (t["date"], t["v"]["reg"]))
w("insert into mot_tests (vehicle_id, test_date, result, expiry_date, mileage, advisories, failure_reasons,")
w("                       centre_id, recorded_at, recorded_by, demo_seed)")
w("select ve.id, t.test_date, t.result, t.expiry, t.mileage, t.adv, t.fails, mc.id,")
w("       t.test_date + t.rec_after, p.id, true")
w("from (values")
rows = []
for t in tests:
    rec_after = f"interval '{rng.randint(0, 2)} days {rng.randint(8, 17)} hours {rng.randint(0, 59)} minutes'"
    rows.append(
        f"  ({q(t['v']['reg'])}, {off(t['date'])}, {q(t['result'])}, "
        f"{off(t['expiry']) if t['expiry'] else 'null::date'}, {t['mileage']}, {q(t['adv'])}, "
        f"{q(t['fails'])}, {q(CENTRES[t['centre']][0])}, {rec_after})")
w(",\n".join(rows))
w(") as t(reg, test_date, result, expiry, mileage, adv, fails, centre, rec_after)")
w("join vehicles ve on ve.registration = t.reg")
w("join mot_centres mc on mc.name = t.centre")
w("join people p on p.code = 'admin';")
w("")
if bookings:
    w("insert into mot_bookings (vehicle_id, appointment_date, centre_id, notes, recorded_at, recorded_by, demo_seed)")
    w("select ve.id, b.appt, mc.id, b.notes, now() - b.ago, p.id, true from (values")
    w(",\n".join(
        f"  ({q(b['v']['reg'])}, {off(b['date'])}, {q(CENTRES[b['centre']][0])}, {q(b['notes'])}, "
        f"interval '{rng.randint(1, 14)} days')" for b in bookings))
    w(") as b(reg, appt, centre, notes, ago)")
    w("join vehicles ve on ve.registration = b.reg")
    w("join mot_centres mc on mc.name = b.centre")
    w("join people p on p.code = 'admin';")
w("")
w("commit;")
OUT.write_text("\n".join(L) + "\n")
print(f"vehicles {len(vehicles)}, tests {len(tests)}, bookings {len(bookings)}, people {len(people)}")
