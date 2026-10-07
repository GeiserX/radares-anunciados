#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the route vectors in Tests/RadaresCoreTests/Fixtures/vectors/*.json.

    python3 -I scripts/make-vectors.py

Each vector is a drive: 1 Hz fixes along synthetic legs around real radars of feed-sample.geojson, plus
the events the engine must produce (design sections 2 and 10) and a few snapshot checks. The expected
distances and sentences are computed here, in Python, from the design rules alone: the Swift engine and
the Kotlin port must agree with this file, not the other way round. docs/SPEC.md describes the format.
"""
import json
import math
import os
from datetime import datetime, timedelta, timezone

R = 6371000.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURE = os.path.join(ROOT, "Tests", "RadaresCoreTests", "Fixtures", "feed-sample.geojson")
OUT = os.path.join(ROOT, "Tests", "RadaresCoreTests", "Fixtures", "vectors")
MADRID = timezone(timedelta(hours=2))  # CEST on the vector dates
T0 = datetime(2026, 10, 7, 10, 0, 0, tzinfo=MADRID)

# Thresholds (design 2.2 to 2.6); the Swift source of truth is Sources/RadaresCore/Thresholds.swift.
LEAD, FLOOR, CAP, BAND, LATE_BAND, NO_VOICE = 25.0, 300.0, 1000.0, 200.0, 100.0, 60.0


def warn(v):
    return max(FLOOR, min(CAP, LEAD * v))


def hav(a, b):
    la1, lo1 = math.radians(a[0]), math.radians(a[1])
    la2, lo2 = math.radians(b[0]), math.radians(b[1])
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def bearing(a, b):
    la1, lo1 = math.radians(a[0]), math.radians(a[1])
    la2, lo2 = math.radians(b[0]), math.radians(b[1])
    y = math.sin(lo2 - lo1) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(lo2 - lo1)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def dest(a, brg, d):
    la1, lo1 = math.radians(a[0]), math.radians(a[1])
    t = math.radians(brg)
    la2 = math.asin(math.sin(la1) * math.cos(d / R) + math.cos(la1) * math.sin(d / R) * math.cos(t))
    lo2 = lo1 + math.atan2(math.sin(t) * math.sin(d / R) * math.cos(la1), math.cos(d / R) - math.sin(la1) * math.sin(la2))
    return (math.degrees(la2), math.degrees(lo2))


def round50(d):
    return int(round(d / 50.0)) * 50


feed = json.load(open(FIXTURE))
RADARS = {}
for f in feed["features"]:
    g = f["geometry"]
    if g["type"] == "Point":
        c = g["coordinates"]
        RADARS[f["id"]] = {"start": (c[1], c[0]), "end": None, "p": f["properties"]}
    else:
        c = g["coordinates"]
        RADARS[f["id"]] = {"start": (c[0][1], c[0][0]), "end": (c[-1][1], c[-1][0]), "p": f["properties"]}


class Route:
    """Fixes appended leg by leg. `pos` is the car, `t` the clock."""

    def __init__(self, start, t0=T0):
        self.pos = start
        self.t = t0
        self.fixes = []

    def leg(self, brg, metres, speed, course="auto", dt=1.0, accuracy=5.0, stationary=False, fix_speed="auto"):
        n = int(round(metres / (speed * dt))) if speed > 0 else int(round(metres))
        for _ in range(n):
            self.pos = dest(self.pos, brg, speed * dt)
            self.t += timedelta(seconds=dt)
            self.fixes.append(self.fix(course if course != "auto" else brg, speed if fix_speed == "auto" else fix_speed, accuracy, stationary))
        return self

    def wait(self, seconds, dt=60.0, speed=0.0, stationary=True):
        for _ in range(int(seconds / dt)):
            self.t += timedelta(seconds=dt)
            self.fixes.append(self.fix(None, speed, 5.0, stationary))
        return self

    def jump(self, seconds):
        self.t += timedelta(seconds=seconds)
        return self

    def fix(self, course, speed, accuracy, stationary):
        return {
            "t": self.t.isoformat(),
            "lat": round(self.pos[0], 7),
            "lon": round(self.pos[1], 7),
            "speed": speed,
            "course": None if course is None else round(course, 2),
            "accuracy": accuracy,
            "stationary": stationary,
        }

    def coords(self):
        return [(f["lat"], f["lon"]) for f in self.fixes]


def predict_fire(fixes, gate, speed, start_index=0):
    """First fix index at which the design's point rule fires on a straight approach: in the band, two
    decreases of at least 1 m, then distance <= warn. Returns (index, distance)."""
    w = warn(speed)
    hist = []
    for i in range(start_index, len(fixes)):
        d = hav((fixes[i]["lat"], fixes[i]["lon"]), gate)
        if d > w + BAND:
            hist = []
            continue
        hist.append(d)
        if len(hist) >= 3 and hist[-2] - hist[-1] >= 1 and hist[-3] - hist[-2] >= 1 and d <= w:
            return i, d
    raise AssertionError("no fire predicted")


def predict_pass(fixes, gate, from_index):
    """First fix after `from_index` with distance under 30 m, or three increases after the minimum."""
    mn, ups, last = None, 0, None
    for i in range(from_index + 1, len(fixes)):
        d = hav((fixes[i]["lat"], fixes[i]["lon"]), gate)
        if d < 30:
            return i, d
        if mn is None or d < mn:
            mn, ups = d, 0
        elif last is not None and d > last:
            ups += 1
            if ups >= 3:
                return i, d
        else:
            ups = 0
        last = d
    raise AssertionError("no pass predicted")


def kind_title(p):
    return {"fixed": "Radar fijo", "section": "Radar de tramo", "mobile_announced": "Radar móvil anunciado", "trailer": "Radar en remolque"}[p["kind"]]


def point_sentence(p, d, also=None):
    s = f"{kind_title(p)} a {round50(d)} metros"
    if also is not None:
        s += f", y otro a {round50(also)}"
    if p.get("direction") and p["direction"] != "both" and not p["direction"].lstrip("-").isdigit():
        s += f", sentido {p['direction'].title()}"
    s += "."
    if p.get("maxspeed"):
        s += f" Límite {p['maxspeed']}."
    return s


def km_text(metres):
    if metres >= 950:
        km = int(round(metres / 1000.0))
        return f"{km} kilómetro" if km == 1 else f"{km} kilómetros"
    return f"{round50(metres)} metros"


def stretch_length(rid):
    r = RADARS[rid]
    p = r["p"]
    if p.get("km_from") is not None and p.get("km_to") is not None:
        return abs(p["km_to"] - p["km_from"]) * 1000.0
    return hav(r["start"], r["end"])


def corridor_sentence(rid):
    p = RADARS[rid]["p"]
    road = f"{p['road']}, " if p.get("road") else ""
    return f"Tramo de radar móvil, {road}{km_text(stretch_length(rid))}."


def section_sentence(rid, d):
    p = RADARS[rid]["p"]
    s = f"Radar de tramo a {round50(d)} metros, {km_text(stretch_length(rid))}"
    if p.get("direction") and p["direction"] != "both" and not p["direction"].lstrip("-").isdigit():
        s += f", sentido {p['direction'].title()}"
    s += "."
    if p.get("maxspeed"):
        s += f" Límite {p['maxspeed']}."
    return s


def warn_event(rid, level, d, tol=40, late=False, spoken=None, opposite=False):
    e = {"kind": "warn", "level": level, "radar": rid, "distance": round(d, 1), "tolerance": tol, "late": late, "opposite": opposite}
    if spoken is not None:
        e["spoken"] = spoken
    return e


def passed_event(rid):
    return {"kind": "passed", "radar": rid}


def entered(rid, d, spoken, tol=40, level="full"):
    return {"kind": "stretchEntered", "radar": rid, "distance": round(d, 1), "tolerance": tol, "spoken": spoken, "level": level}


def exited(rid, reason, spoken=None):
    e = {"kind": "stretchExited", "radar": rid, "exitReason": reason}
    if spoken is not None:
        e["spoken"] = spoken
    return e


VECTORS = []


def vector(name, description, route, expected, **extra):
    v = {"name": name, "description": description, "locale": "es-ES", "fixes": route.fixes, "expected": expected}
    v.update(extra)
    VECTORS.append(v)
    return v


def straight_approach(rid, course, speed, start_m, past_m=300, t0=T0):
    """Drive toward a point radar from start_m away along `course`, through it, past_m beyond."""
    gate = RADARS[rid]["start"]
    begin = dest(gate, (course + 180) % 360, start_m)
    r = Route(begin, t0)
    r.leg(course, start_m + past_m, speed)
    return r


# ---- 1. The A-2 fixed radar, direction text ZARAGOZA, both ways (design 0, 10) ----
A2 = "dgt-CABINACINEMOMETRO_120001"
p = RADARS[A2]["p"]
for tag, course in (("ne", 60.0), ("sw", 240.0)):
    r = straight_approach(A2, course, 120 / 3.6, 3020)
    i, d = predict_fire(r.fixes, RADARS[A2]["start"], 120 / 3.6)
    assert abs(d - 833) <= 40, d
    j, _ = predict_pass(r.fixes, RADARS[A2]["start"], i)
    vector(
        f"a2-120kmh-{tag}",
        f"120 km/h toward the A-2 radar heading {int(course)}: one full warning at 833 +- 40 m with the direction text spoken, then passed. The feed gives a town name, not a bearing, so both ways warn.",
        r,
        [warn_event(A2, "full", d, spoken=point_sentence(p, d)), passed_event(A2)],
    )

# ---- 2. León weekly list: today fires, tomorrow is silent ----
LEON = "leon-2026-10-07-avenida-de-los-antibioticos-2"
lp = RADARS[LEON]["p"]
r = straight_approach(LEON, 10.0, 50 / 3.6, 1200, past_m=150)
i, d = predict_fire(r.fixes, RADARS[LEON]["start"], 50 / 3.6)
assert abs(d - 347) <= 20, d
vector(
    "leon-50kmh-today",
    "50 km/h toward a mobile_announced entry valid today (Europe/Madrid): full warning at 347 +- 20 m with the limit spoken.",
    r,
    [warn_event(LEON, "full", d, tol=20, spoken=point_sentence(lp, d)), passed_event(LEON)],
)
r = straight_approach(LEON, 10.0, 50 / 3.6, 1200, past_m=150, t0=T0 + timedelta(days=1))
vector("leon-50kmh-tomorrow", "The same drive one day later: the announcement has expired, nothing fires.", r, [])

# ---- 3. Parallel road 150 m beside the radar: never fires; twin head-on ----
for tag, offset in (("parallel-150m", 150.0), ("head-on", 0.0)):
    gate = RADARS[A2]["start"]
    course = 60.0
    side = dest(gate, (course + 90) % 360, offset) if offset else gate
    begin = dest(side, (course + 180) % 360, 60 if offset else 2010)
    r = Route(begin).leg(course, 800 if offset else 2300, 90 / 3.6)
    if offset:
        vector("a2-parallel-150m", "A road 150 m beside the A-2 radar, starting abreast: the radar is never inside the 60 degree cone while closing, so it never fires.", r, [])
    else:
        i, d = predict_fire(r.fixes, gate, 90 / 3.6)
        vector("a2-head-on-90kmh", "Twin of a2-parallel-150m: the same speed straight at the radar fires at 625 +- 40 m.", r, [warn_event(A2, "full", d, spoken=point_sentence(p, d)), passed_event(A2)])

# ---- 4. Behind: driving away never fires ----
gate = RADARS[A2]["start"]
r = Route(dest(gate, 60.0, 100)).leg(60.0, 1500, 90 / 3.6)
vector("a2-behind", "Starting 100 m past the A-2 radar and driving away: behind, not closing, never fires.", r, [])

# ---- 5. OSM numeric bearing: same flow full, opposite flow visual ----
OSM = "osm-619772731"  # direction "-40" -> bearing 320
op = RADARS[OSM]["p"]
for tag, course, level, opposite in (("same", 320.0, "full", False), ("opposite", 140.0, "visual", True)):
    r = straight_approach(OSM, course, 90 / 3.6, 2010)
    i, d = predict_fire(r.fixes, RADARS[OSM]["start"], 90 / 3.6)
    vector(
        f"osm-bearing-{tag}",
        f"OSM radar with direction -40 (bearing 320) approached on course {int(course)}: {level}. A mismatch demotes to visual (sentido contrario), it never hides the radar.",
        r,
        [warn_event(OSM, level, d, spoken=point_sentence(op, d) if level == "full" else None, opposite=opposite), passed_event(OSM)],
    )

# ---- 6. direction both: full from any course ----
BOTH = "osm-13375593333"
bp = RADARS[BOTH]["p"]
r = straight_approach(BOTH, 200.0, 90 / 3.6, 2010)
i, d = predict_fire(r.fixes, RADARS[BOTH]["start"], 90 / 3.6)
vector("osm-both", "An OSM radar with direction both: full whatever the course.", r, [warn_event(BOTH, "full", d, spoken=point_sentence(bp, d)), passed_event(BOTH)])

# ---- 7. No course at 2 m/s: nothing; twin with course derived from fixes 20 m apart ----
r = straight_approach(A2, 60.0, 2.0, 400, past_m=0, )
for f in r.fixes:
    f["course"] = None
vector("a2-no-course-2mps", "2 m/s with no platform course and fixes 2 m apart: no course can be derived, nothing fires, the card shows the radar as cerca.", r, [])
r = straight_approach(A2, 60.0, 20.0, 700, past_m=100)
for f in r.fixes:
    f["course"] = None
i, d = predict_fire(r.fixes, RADARS[A2]["start"], 20.0)
vector("a2-no-course-20mps", "Twin: 20 m/s with no platform course; the course comes from the last two fixes (20 m apart) and the warning fires at 500 +- 40 m.", r, [warn_event(A2, "full", d, spoken=point_sentence(p, d)), passed_event(A2)])

# ---- 8. Late wake at 150 m: full, flagged late; first seen at 40 m: card only ----
r = straight_approach(A2, 60.0, 90 / 3.6, 150, past_m=200)
i, d = predict_fire(r.fixes, RADARS[A2]["start"], 90 / 3.6)
assert d >= NO_VOICE
vector("a2-late-150m", "First fix 150 m before the A-2 radar at 90 km/h (late wake-up): fires full at the third fix, flagged late.", r, [warn_event(A2, "full", d, late=True, spoken=point_sentence(p, d)), passed_event(A2)])
r = straight_approach(A2, 60.0, 30 / 3.6, 40, past_m=100)
i, d = predict_fire(r.fixes, RADARS[A2]["start"], 30 / 3.6)
assert d < NO_VOICE
vector("a2-first-seen-40m", "First fix 40 m before the radar at 30 km/h: under 60 m and closing, so the card shows it (visual, late) and nothing is spoken.", r, [warn_event(A2, "visual", d, tol=10, late=True), passed_event(A2)])

# ---- 9. U-turn inside 5 min: one pass; after 11 min and 3 km: a new pass ----
def uturn_route(gap_seconds, away_m):
    gate = RADARS[A2]["start"]
    r = Route(dest(gate, 240.0, 2010))
    r.leg(60.0, 2010 + 300, 90 / 3.6)  # through the radar, 300 m past
    r.leg(240.0, 300 + away_m, 90 / 3.6)  # U-turn, back past it and away_m beyond
    if gap_seconds:
        r.jump(gap_seconds)
    r.leg(60.0, away_m + 300, 90 / 3.6)  # U-turn again, re-approach, through, 300 m past
    return r

r = uturn_route(0, 1000)
i, d = predict_fire(r.fixes, RADARS[A2]["start"], 90 / 3.6)
vector("a2-uturn-5min", "Fire, pass, U-turn and re-approach the same radar within 5 minutes: the second approach is the same pass, no second warning.", r, [warn_event(A2, "full", d, spoken=point_sentence(p, d)), passed_event(A2)])
r = uturn_route(11 * 60, 3000)
i, d = predict_fire(r.fixes, RADARS[A2]["start"], 90 / 3.6)
n_first = len(r.fixes)
i2, d2 = predict_fire(r.fixes, RADARS[A2]["start"], 90 / 3.6, start_index=i + 200)
vector(
    "a2-uturn-11min-3km",
    "Twin: fire, pass, drive 3 km away, 11 minutes later re-approach: both cooldown conditions hold, so it fires again.",
    r,
    [warn_event(A2, "full", d, spoken=point_sentence(p, d)), passed_event(A2), warn_event(A2, "full", d2, spoken=point_sentence(p, d2)), passed_event(A2)],
)

# ---- 10. Two radars 123 m apart: one spoken, one visual (pacing); late start: one combined sentence ----
PA, PB = "dgt-CABINACINEMOMETRO_120452", "dgt-CABINACINEMOMETRO_120647"
pa, pb = RADARS[PA]["p"], RADARS[PB]["p"]
course = bearing(RADARS[PA]["start"], RADARS[PB]["start"])
r = Route(dest(RADARS[PA]["start"], (course + 180) % 360, 2010)).leg(course, 2010 + 123 + 300, 90 / 3.6)
ia, da = predict_fire(r.fixes, RADARS[PA]["start"], 90 / 3.6)
ib, db = predict_fire(r.fixes, RADARS[PB]["start"], 90 / 3.6)
assert 0 < ib - ia < 8, (ia, ib)
vector(
    "pair-123m-pacing",
    "Two fixed radars 123 m apart on the EI-600 at 90 km/h: the first is spoken, the second fires 5 s later inside the 8 s pacing gap and is visual only.",
    r,
    [warn_event(PA, "full", da, spoken=point_sentence(pa, da)), warn_event(PB, "visual", db), passed_event(PA), passed_event(PB)],
)
r = Route(dest(RADARS[PA]["start"], (course + 180) % 360, 540)).leg(course, 540 + 123 + 300, 90 / 3.6)
ia, da = predict_fire(r.fixes, RADARS[PA]["start"], 90 / 3.6)
ib, db = predict_fire(r.fixes, RADARS[PB]["start"], 90 / 3.6)
assert ia == ib, (ia, ib)
vector(
    "pair-123m-same-fix",
    "Twin: a late start 540 m before the pair puts both inside the warn distance on the same fix: one combined sentence, the nearer full and late, the farther visual.",
    r,
    [warn_event(PA, "full", da, late=True, spoken=point_sentence(pa, da, also=db)), warn_event(PB, "visual", db, late=False), passed_event(PA), passed_event(PB)],
)

# ---- 11. The N-232 mobile corridor: entry from either end, remaining, Fin de tramo, silent exits ----
COR = "dgt_invive-Tramo_Invive_344"
W, E = RADARS[COR]["start"], RADARS[COR]["end"]
chord = hav(W, E)
for tag, near, far in (("west", W, E), ("east", E, W)):
    course = bearing(near, far)
    r = Route(dest(near, (course + 180) % 360, 2010)).leg(course, 2010 + chord + 200, 90 / 3.6)
    i, d = predict_fire(r.fixes, near, 90 / 3.6)
    exit_i = next(k for k in range(i, len(r.fixes)) if hav((r.fixes[k]["lat"], r.fixes[k]["lon"]), far) <= 300)
    mid = i + 100
    remaining = chord - hav(near, (r.fixes[mid]["lat"], r.fixes[mid]["lon"]))
    vector(
        f"corridor-n232-from-{tag}",
        f"The 10.1 km dgt_invive corridor entered from its {tag} gate at 90 km/h: entry sentence at 625 +- 40 m, remaining distance inside, Fin de tramo within 300 m of the far gate.",
        r,
        [entered(COR, d, corridor_sentence(COR)), exited(COR, "farGate", "Fin de tramo.")],
        snapshots=[{"fixIndex": mid, "stretch": COR, "remainingMetres": round(remaining), "tolerance": 60, "phase": "insideStretch"}],
    )

course = bearing(W, E)
r = Route(dest(W, (course + 180) % 360, 2010)).leg(course, 2010 + 2000, 90 / 3.6)
i, d = predict_fire(r.fixes, W, 90 / 3.6)
r.leg((course + 270) % 360, 11200, 90 / 3.6)  # turn left, drive away until farther than length + 1000 m from the entry gate
vector(
    "corridor-n232-exit-distance",
    "Enter the corridor, leave the road 2 km in and drive away: a silent exit once the straight-line distance from the entry gate passes the length plus 1,000 m.",
    r,
    [entered(COR, d, corridor_sentence(COR)), exited(COR, "distance")],
)
r = Route(dest(W, (course + 180) % 360, 2010)).leg(course, 2010 + 1000, 90 / 3.6)
i, d = predict_fire(r.fixes, W, 90 / 3.6)
r.wait(2 * 10100 / (90 / 3.6) + 120, dt=60.0)  # stop inside for more than twice the traverse time at entry speed
vector(
    "corridor-n232-exit-time",
    "Enter the corridor and stop 1 km in: a silent exit after twice the traverse time expected at the entry speed.",
    r,
    [entered(COR, d, corridor_sentence(COR)), exited(COR, "time")],
)

# ---- 12. The Z-40 average-speed section with its -from/-to twins merged ----
SEC = "dgt-CVM_161274"
S0, S1 = RADARS[SEC]["start"], RADARS[SEC]["end"]
course = bearing(S0, S1)
r = Route(dest(S0, (course + 180) % 360, 2010)).leg(course, 2010 + hav(S0, S1) + 200, 100 / 3.6)
i, d = predict_fire(r.fixes, S0, 100 / 3.6)
mid = i + 60
remaining = hav(S0, S1) - hav(S0, (r.fixes[mid]["lat"], r.fixes[mid]["lon"]))
vector(
    "section-z40-100kmh",
    "The Z-40 average-speed section at 100 km/h: the section twins are merged so only the stretch speaks; entry sentence with the length and the direction text, average speed from the path, Fin de tramo at the far gate.",
    r,
    [entered(SEC, d, section_sentence(SEC, d)), exited(SEC, "farGate", "Fin de tramo.")],
    snapshots=[{"fixIndex": mid, "stretch": SEC, "remainingMetres": round(remaining), "tolerance": 60, "avgKmh": 100, "avgTolerance": 3, "phase": "insideStretch"}],
)

# ---- 13. Negative control: a2-120kmh-ne with its warning removed. The test asserts the engine disagrees. ----
base = next(v for v in VECTORS if v["name"] == "a2-120kmh-ne")
VECTORS.append(
    {
        "name": "broken-a2-no-warning",
        "description": "Deliberately wrong: the same drive as a2-120kmh-ne with the warning removed from the expectation. The suite asserts that the engine's output differs from this file, which proves a vector test can fail.",
        "locale": "es-ES",
        "negativeControl": True,
        "fixes": base["fixes"],
        "expected": [passed_event(A2)],
    }
)

os.makedirs(OUT, exist_ok=True)
for old in os.listdir(OUT):
    if old.endswith(".json"):
        os.remove(os.path.join(OUT, old))
for v in VECTORS:
    path = os.path.join(OUT, v["name"] + ".json")
    with open(path, "w") as fh:
        json.dump(v, fh, ensure_ascii=False, indent=1)
    print(f"{v['name']:32} {len(v['fixes']):5} fixes  {[e['kind'] + ('/' + e['level'] if 'level' in e else '') for e in v['expected']]}")
