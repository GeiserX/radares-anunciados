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
import runpy
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


def predict_pass(fixes, gate, from_index, min_step=1.0, min_rise=3.0):
    """First fix after `from_index` with distance under 30 m, or three consecutive increases of at least
    `min_step` after the minimum with the distance at least max(min_rise, accuracy) above it (design 2.3).
    Returns None when no pass is predicted. `min_step=0, min_rise=None` is the rule before the jitter fix,
    used only to prove a control vector would have passed under it."""
    mn, ups, last = None, 0, None
    for i in range(from_index + 1, len(fixes)):
        d = hav((fixes[i]["lat"], fixes[i]["lon"]), gate)
        if d < 30:
            return i, d
        if mn is None or d < mn:
            mn, ups = d, 0
        elif last is not None and d - last >= min_step:
            ups += 1
            if ups >= 3 and (min_rise is None or d - mn >= max(min_rise, fixes[i]["accuracy"])):
                return i, d
        else:
            ups = 0
        last = d
    return None


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


def corridor_joined_sentence(rid, remaining):
    p = RADARS[rid]["p"]
    road = f"{p['road']}, " if p.get("road") else ""
    return f"Tramo de radar móvil, {road}quedan {km_text(remaining)}."


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
    assert predict_pass(r.fixes, RADARS[A2]["start"], i) is not None
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
# 6 m/s with no platform course: fixes 6 m apart, so the course comes from the most recent fix at least 15 m back
# (three fixes, 18 m) inside the 5 s window; at 2 m/s the window holds 10 m and nothing fires (a2-no-course-2mps).
r = straight_approach(A2, 60.0, 6.0, 700, past_m=100)
for f in r.fixes:
    f["course"] = None
i, d = predict_fire(r.fixes, RADARS[A2]["start"], 6.0)
vector("a2-no-course-6mps", "6 m/s with no platform course and fixes 6 m apart: the course comes from the most recent earlier fix at least 15 m back (three fixes, inside the 5 s window), and the warning fires at the 300 m floor.", r, [warn_event(A2, "full", d, spoken=point_sentence(p, d)), passed_event(A2)])
# A valid platform course with the speed marked invalid (negative speed accuracy): the displacement stands in for the speed.
r = straight_approach(A2, 60.0, 10.0, 700, past_m=100)
for f in r.fixes:
    f["speed"] = None
i, d = predict_fire(r.fixes, RADARS[A2]["start"], 0.0)
vector("a2-speed-nil-course-10mps", "10 m/s with the speed marked invalid on every fix and a valid platform course: the car moves 10 m per fix, so the platform course is used and the warning fires at the 300 m floor.", r, [warn_event(A2, "full", d, spoken=point_sentence(p, d)), passed_event(A2)])

# ---- 8. Late wake at 150 m: full, flagged late; first seen at 40 m: card only ----
r = straight_approach(A2, 60.0, 90 / 3.6, 150, past_m=200)
i, d = predict_fire(r.fixes, RADARS[A2]["start"], 90 / 3.6)
assert d >= NO_VOICE
vector("a2-late-150m", "First fix 150 m before the A-2 radar at 90 km/h (late wake-up): fires full at the third fix, flagged late.", r, [warn_event(A2, "full", d, late=True, spoken=point_sentence(p, d)), passed_event(A2)])
r = straight_approach(A2, 60.0, 30 / 3.6, 40, past_m=100)
i, d = predict_fire(r.fixes, RADARS[A2]["start"], 30 / 3.6)
assert d < NO_VOICE
vector("a2-first-seen-40m", "First fix 40 m before the radar at 30 km/h: under 60 m and closing, so the card shows it (visual, late) and nothing is spoken.", r, [warn_event(A2, "visual", d, tol=10, late=True), passed_event(A2)])

# ---- 8b. Stopped before a fired radar: GPS wander is not a pass ----
r = straight_approach(A2, 60.0, 90 / 3.6, 2010, past_m=0)
i, d = predict_fire(r.fixes, RADARS[A2]["start"], 90 / 3.6)
del r.fixes[next(k for k in range(i, len(r.fixes)) if hav((r.fixes[k]["lat"], r.fixes[k]["lon"]), RADARS[A2]["start"]) < 200):]
stop = r.coords()[-1]
# A red light 200 m before the radar: the car reports speed 0 and no course, the position wanders. The first five
# fixes are the wander the old rule took for a pass (three increases of under a metre); then two minutes of
# seeded jitter of up to 2 m with a 10 m accuracy.
rng = __import__("random").Random(7)
offsets = [0.0, -0.5, 0.2, 0.6, 0.9] + [rng.uniform(-2.0, 2.0) for _ in range(120)]
for off in offsets:
    r.pos = dest(stop, 240.0, off)  # positive: away from the radar
    r.t += timedelta(seconds=1)
    r.fixes.append(r.fix(None, 0.0, 10.0, False))
assert predict_pass(r.fixes, RADARS[A2]["start"], i, min_step=0.0, min_rise=None) is not None, "the old rule must see a pass here, or the vector proves nothing"
assert predict_pass(r.fixes, RADARS[A2]["start"], i) is None
vector("a2-stopped-jitter-200m", "90 km/h toward the A-2 radar, fired at 625 m, then stopped at a red light 200 m before it with the position wandering up to 2 m (accuracy 10 m): the warning, and no pass while the car is stopped.", r, [warn_event(A2, "full", d, spoken=point_sentence(p, d))])

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

# Joined between the gates (an on-ramp 5 km in): inside after three fixes on the chord, the length left spoken.
course = bearing(W, E)
r = Route(dest(W, course, 5000)).leg(course, chord - 5000 + 500, 90 / 3.6)
join = 2  # the third fix
remaining_at_join = chord - hav(W, (r.fixes[join]["lat"], r.fixes[join]["lon"]))
mid = join + 100
remaining_mid = chord - hav(W, (r.fixes[mid]["lat"], r.fixes[mid]["lon"]))
vector(
    "corridor-n232-mid-join",
    "The N-232 corridor joined 5 km in from a side road at 90 km/h: no gate is crossed, so the car is inside after three fixes on the chord heading along it, the remaining length is spoken, and Fin de tramo comes at the far gate.",
    r,
    [entered(COR, remaining_at_join, corridor_joined_sentence(COR, remaining_at_join), tol=60), exited(COR, "farGate", "Fin de tramo.")],
    snapshots=[{"fixIndex": mid, "stretch": COR, "remainingMetres": round(remaining_mid), "tolerance": 60, "phase": "insideStretch"}],
)

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

# =====================================================================================================================
# Road geometry (design 2.3, 2.5): the synthetic scenarios of make-roads-fixture.py. The expectations come from a
# Python model of the road rule written from the design, never from the Swift engine: candidate segments pass the
# lateral AND the course test, the smallest lateral wins, the along-road position may not jump further than
# 3 x speed x seconds + 50 m, distance = length - along, closing over two decreases, pass at length - 30.
# =====================================================================================================================

ROADS_FIXTURE = runpy.run_path(os.path.join(ROOT, "scripts", "make-roads-fixture.py"), run_name="roads_fixture")
GEOM = ROADS_FIXTURE["GEOMETRY"]
ROADS_JSON = json.load(open(os.path.join(ROOT, "Tests", "RadaresCoreTests", "Fixtures", "roads-sample.json"), encoding="utf-8"))
for f in json.load(open(os.path.join(ROOT, "Tests", "RadaresCoreTests", "Fixtures", "feed-sample-roads.geojson"), encoding="utf-8"))["features"]:
    g = f["geometry"]
    c = g["coordinates"]
    if g["type"] == "Point":
        RADARS[f["id"]] = {"start": (c[1], c[0]), "end": None, "p": f["properties"]}
    else:
        RADARS[f["id"]] = {"start": (c[0][1], c[0][0]), "end": (c[-1][1], c[-1][0]), "p": f["properties"]}

LAT_M, LAT_FACTOR, COURSE_DEG, JUMP_FACTOR, JUMP_FLOOR = 25.0, 1.5, 45.0, 3.0, 50.0
OFF_M, OFF_ACC, OFF_FIXES = 60.0, 20.0, 3
LOSS_FIXES, LOSS_ACC = 5, 50.0
EXIT_GATE, EXIT_SLACK, EXIT_TIME, MID_FIXES, MID_XT = 300.0, 1000.0, 2.0, 3, 150.0


def angle_diff(a, b):
    d = abs((a % 360) - (b % 360))
    return 360 - d if d > 180 else d


class PL:
    """A decoded polyline in a flat frame around its box middle, as Sources/RadaresCore/Roads/Polyline.swift."""

    def __init__(self, coords):
        v = []
        for c in coords:
            if not v or v[-1] != c:
                v.append(c)
        self.v = v
        lats, lons = [c[0] for c in v], [c[1] for c in v]
        self.lat0, self.lon0 = (min(lats) + max(lats)) / 2, (min(lons) + max(lons)) / 2
        self.ky = R * math.pi / 180
        self.kx = self.ky * math.cos(math.radians(self.lat0))
        self.xs = [(c[1] - self.lon0) * self.kx for c in v]
        self.ys = [(c[0] - self.lat0) * self.ky for c in v]
        self.cum = [0.0]
        self.brg = []
        for i in range(1, len(v)):
            dx, dy = self.xs[i] - self.xs[i - 1], self.ys[i] - self.ys[i - 1]
            self.cum.append(self.cum[-1] + math.hypot(dx, dy))
            self.brg.append((math.degrees(math.atan2(dx, dy)) + 360) % 360)
        self.length = self.cum[-1]

    def projections(self, p):
        px, py = (p[1] - self.lon0) * self.kx, (p[0] - self.lat0) * self.ky
        out = []
        for i in range(len(self.xs) - 1):
            ax, ay = self.xs[i], self.ys[i]
            dx, dy = self.xs[i + 1] - ax, self.ys[i + 1] - ay
            l2 = dx * dx + dy * dy
            t = ((px - ax) * dx + (py - ay) * dy) / l2 if l2 > 0 else 0
            t = min(1, max(0, t))
            lat = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            out.append((lat, self.cum[i] + t * (self.cum[i + 1] - self.cum[i]), i, self.brg[i]))
        return out

    def min_lateral(self, p):
        return min(x[0] for x in self.projections(p))

    def at(self, along):
        """Lat/lon at `along` metres (for building car paths)."""
        along = max(0, min(self.length, along))
        i = 1
        while i < len(self.cum) - 1 and self.cum[i] < along:
            i += 1
        seg = self.cum[i] - self.cum[i - 1]
        f = (along - self.cum[i - 1]) / seg if seg > 0 else 0
        x = self.xs[i - 1] + f * (self.xs[i] - self.xs[i - 1])
        y = self.ys[i - 1] + f * (self.ys[i] - self.ys[i - 1])
        return (self.lat0 + y / self.ky, self.lon0 + x / self.kx)

    def chunk_boxes(self, max_m=2000.0):
        boxes, start = [], 0
        while start < len(self.v) - 1:
            end = start + 1
            while end < len(self.v) - 1 and self.cum[end + 1] - self.cum[start] <= max_m:
                end += 1
            pts = self.v[start:end + 1]
            boxes.append((min(p[0] for p in pts), max(p[0] for p in pts), min(p[1] for p in pts), max(p[1] for p in pts)))
            start = end
        return boxes


def approaches_of(rid):
    e = ROADS_JSON["features"].get(rid)
    return [PL(ROADS_FIXTURE["decode"](a["polyline"])) for a in e["approaches"]] if e and "approaches" in e else None


def line_of(rid):
    e = ROADS_JSON["features"][rid]
    return PL(ROADS_FIXTURE["decode"](e["line"])), [PL(ROADS_FIXTURE["decode"](a["polyline"])) for a in e["gates"]["start"]], [PL(ROADS_FIXTURE["decode"](a["polyline"])) for a in e["gates"]["end"]]


def road_match(pls, pos, course, acc, prev=None, t=None, speed=None, forward=True, backward=False):
    limit = max(LAT_M, LAT_FACTOR * acc)
    jump = None
    if prev is not None:
        jump = JUMP_FACTOR * max(0.0, speed or 0.0) * max(0.0, (t - prev["at"]).total_seconds()) + JUMP_FLOOR
    best = None
    for k, pl in enumerate(pls):
        for lat, along, seg, brg in pl.projections(pos):
            if lat > limit:
                continue
            fwd = True
            if course is not None:
                if forward and angle_diff(course, brg) <= COURSE_DEG:
                    fwd = True
                elif backward and angle_diff(course, brg + 180) <= COURSE_DEG:
                    fwd = False
                else:
                    continue
            if prev is not None and prev["index"] == k and abs(along - prev["along"]) > jump:
                continue
            if best is None or lat < best["lateral"]:
                best = {"index": k, "lateral": lat, "along": along, "forward": fwd, "length": pl.length}
    return best


def road_evaluate(pls, f, t, course, speed, prev, warn_d):
    m = road_match(pls, (f["lat"], f["lon"]), course, f["accuracy"], prev, t, speed)
    if m is None:
        return None
    d = m["length"] - m["along"]
    earlier = prev["dists"] if prev is not None and prev["index"] == m["index"] else []
    closing = len(earlier) >= 2 and earlier[-1] - d >= 1 and earlier[-2] - earlier[-1] >= 1
    first = earlier[0] if earlier else d
    kept = earlier + [d]
    if len(kept) > 8:
        del kept[1]
    level = "full" if (m["along"] < m["length"] and closing and d <= warn_d) else None
    return {**m, "distance": d, "level": level, "late": first < warn_d - LATE_BAND,
            "hist": {"index": m["index"], "along": m["along"], "at": t, "dists": kept}}


def fix_time(f):
    return datetime.fromisoformat(f["t"])


def median3(speeds):
    s = sorted(speeds)
    n = len(s)
    return None if n == 0 else (s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2)


def straight_eval(f, gate, course, prev, warn_d, bearing_deg=None, bidir=False):
    pos = (f["lat"], f["lon"])
    d = hav(pos, gate)
    ahead = angle_diff(course, bearing(pos, gate)) <= 60
    closing = len(prev) >= 2 and prev[-1] - d >= 1 and prev[-2] - prev[-1] >= 1
    match = True if (bearing_deg is None or bidir) else angle_diff(course, bearing_deg) <= 90
    first = prev[0] if prev else d
    level = None
    if ahead and closing and d <= warn_d:
        level = "full" if match else "visual"
    return {"distance": d, "level": level, "late": first < warn_d - LATE_BAND, "ahead": ahead, "match": match}


def sim_point(fixes, rid, use_roads=True):
    """One point radar through the rules of design 2.3 and 2.4 with road geometry: returns the warn and passed
    events with their fix index, and the hidden fires. Single radar, so pacing never applies."""
    r = RADARS[rid]
    p = r["p"]
    gate = r["start"]
    brg_deg, bidir = None, False
    if p.get("bearing") is not None and p.get("direction_semantics") == "travel":
        brg_deg = p["bearing"] % 360
    elif p.get("direction") == "both":
        bidir = True
    elif p.get("direction") and p["direction"].lstrip("-").replace(".", "").isdigit():
        brg_deg = float(p["direction"]) % 360
    high = p.get("direction_confidence") == "high" and brg_deg is not None
    pls = approaches_of(rid) if use_roads else None
    events, hidden = [], []
    speeds, hist, road_hist, off_run = [], [], None, 0
    fired = None  # dict level/held/hidden
    passed = False
    watch = None
    for i, f in enumerate(fixes):
        t = fix_time(f)
        if f["speed"] is not None and f["speed"] >= 0:
            speeds = (speeds + [f["speed"]])[-3:]
        med = median3(speeds)
        w = warn(med or 0)
        pos = (f["lat"], f["lon"])
        d = hav(pos, gate)
        course = f["course"]
        match = None
        cand = d <= w + BAND
        prev = hist[:]
        if cand:
            hist = hist + [d]
            if len(hist) > 8:
                del hist[1]
            if pls is not None:
                off = min(pl.min_lateral(pos) for pl in pls) > OFF_M and f["accuracy"] <= OFF_ACC
                off_run = off_run + 1 if off else 0
                match = road_evaluate(pls, f, t, course, med if med is not None else f["speed"], road_hist, w) if course is not None else None
                road_hist = match["hist"] if match else None
        else:
            hist, road_hist, off_run = [], None, 0
        fired_now = False
        if cand and course is not None:
            if fired is None:
                kind, a = None, None
                if match is not None:
                    if match["level"]:
                        kind, a = "normal", {"distance": match["distance"], "level": match["level"], "late": match["late"], "match": True}
                else:
                    a = straight_eval(f, gate, course, prev, w, brg_deg, bidir)
                    if a["level"] == "full":
                        kind = "held" if (pls is not None and off_run >= OFF_FIXES) else "normal"
                    elif a["level"] == "visual":
                        kind = "hidden" if high else "normal"
                if kind:
                    level = "visual" if kind in ("held", "hidden") else a["level"]
                    if level == "full" and a["distance"] < NO_VOICE:
                        level = "visual"
                    fired = {"level": level, "held": kind == "held", "hidden": kind == "hidden"}
                    fired_now = True
                    watch = [a["distance"], a["distance"], 0]
                    if kind == "hidden":
                        hidden.append((i, rid))
                    else:
                        e = warn_event(rid, level, a["distance"], late=a["late"], opposite=not a["match"],
                                       spoken=point_sentence(p, a["distance"]) if level == "full" else None)
                        if kind == "held":
                            e["held"] = True
                        events.append((i, e))
            elif fired["held"] and not passed and match is not None and match["level"] == "full" and match["distance"] >= NO_VOICE:
                fired = {"level": "full", "held": False, "hidden": False}
                fired_now = True
                watch = [match["distance"], match["distance"], 0]
                events.append((i, warn_event(rid, "full", match["distance"], late=match["late"], spoken=point_sentence(p, match["distance"]))))
        if fired is not None and not passed and not fired_now:
            is_passed = False
            if match is not None:
                is_passed = match["along"] >= match["length"] - 30
                if not is_passed:
                    watch = [d, d, 0]
                    continue
            else:
                is_passed = d < 30
                if not is_passed:
                    if d < watch[0]:
                        watch[0], watch[2] = d, 0
                    elif d - watch[1] >= 1:
                        watch[2] += 1
                        is_passed = watch[2] >= 3 and d - watch[0] >= max(3.0, f["accuracy"])
                    else:
                        watch[2] = 0
            watch[1] = d
            if is_passed:
                passed = True
                if not fired["hidden"]:
                    events.append((i, {"kind": "passed", "radar": rid, "_d": d}))
    return events, hidden


def follow(route, path, speed, offset_m=0.0, bias=None, stop_after=None, accuracy=5.0):
    """Drive a lat/lon path at `speed` m/s, one fix per second, course = the travel direction of the path where the car
    is. `offset_m` moves the reported position that far to the left of the travel direction, `bias` = (heading,
    metres) moves it the same way on every fix (a GPS bias). `stop_after` metres ends the drive early."""
    segs = []
    for k in range(1, len(path)):
        segs.append((path[k - 1], path[k], hav(path[k - 1], path[k]), bearing(path[k - 1], path[k])))
    total = sum(s[2] for s in segs)
    if stop_after is not None:
        total = min(total, stop_after)
    s = 0.0
    k = 0
    acc_along = 0.0
    while True:
        s += speed
        if s > total + 1e-6:
            break
        while k < len(segs) - 1 and acc_along + segs[k][2] < s:
            acc_along += segs[k][2]
            k += 1
        a, b, L, brg = segs[k]
        pos = dest(a, brg, s - acc_along)
        if offset_m:
            pos = dest(pos, (brg - 90) % 360, offset_m)
        if bias:
            pos = dest(pos, bias[0], bias[1])
        route.pos = pos
        route.t += timedelta(seconds=1)
        route.fixes.append(route.fix(brg, speed, accuracy, False))
    return route


def local(name, pts):
    fr = GEOM[name]["frame"]
    return fr.lls(pts)


def sorted_events(*lists):
    """Merge per-radar event lists by fix index, warns before passes on one fix (the engine's order)."""
    merged = []
    for lst in lists:
        merged += lst
    order = {"stretchEntered": 0, "stretchExited": 0, "warn": 1, "passed": 2}
    merged.sort(key=lambda x: (x[0], order[x[1]["kind"]], x[1].get("distance", 0)))
    out = []
    for _, e in merged:
        e = dict(e)
        e.pop("_d", None)
        out.append(e)
    return out


def passed_near(rid, events, within=30.0):
    """The passed event with a distance check: the car is within `within` m of the radar when it is marked passed."""
    for i, e in events:
        if e["kind"] == "passed":
            assert e["_d"] < within, (rid, e["_d"])
            e.update({"distance": round(within / 2, 1), "tolerance": within / 2})


# ---- 14. Straight road with a parallel road 150 m off and an overpass 100 m before the radar ----
SR = "fixed-straight-road"
st = GEOM["straight"]
road_lls = local("straight", st["road"])
radar_ll = RADARS[SR]["start"]
on_road = Route(road_lls[0])
on_road.fixes = []
# From 2 km before the radar along the road (500 m before its approach polyline starts) to 300 m past it.
follow(on_road, road_lls, 90 / 3.6, stop_after=2800.0)
on_road.fixes = on_road.fixes[int(500 / 25):]
ev, hid = sim_point(on_road.fixes, SR)
assert [e["kind"] for _, e in ev] == ["warn", "passed"] and ev[0][1]["level"] == "full", ev
assert abs(ev[0][1]["distance"] - 625) <= 40, ev
passed_near(SR, ev)
vector("road-on-approach-2km", "90 km/h along the road into a radar with an approach polyline, from 2 km before it: one full warning at 625 +- 40 m along the road, passed within 30 m of the radar.", on_road, sorted_events(ev))

par = Route(road_lls[0])
follow(par, road_lls, 90 / 3.6, offset_m=150.0, stop_after=2800.0)
par.fixes = par.fixes[int(500 / 25):]
ev, hid = sim_point(par.fixes, SR)
ev_old, _ = sim_point(par.fixes, SR, use_roads=False)
assert ev_old[0][1]["level"] == "full", "the straight-line rule must speak here, or the vector proves nothing"
assert [e["kind"] for _, e in ev] == ["warn", "passed"] and ev[0][1].get("held") and ev[0][0] == ev_old[0][0], (ev, ev_old)
vector("road-parallel-150m-from-2km", "A road 150 m beside the radar's road, driven from 2 km before it at 90 km/h: the straight-line rule fires where it always did, but the car is more than 60 m from the radar's road on three accurate fixes, so the warning is held: a silent notification, no voice; then passed.", par, sorted_events(ev))

# The overpass: a road crossing the radar's road at 90 degrees, 100 m before the radar, driven across.
cross_pt = dest(radar_ll, (st["heading"] + 180) % 360, 100.0)
over_start = dest(cross_pt, (st["heading"] + 270) % 360, 1500.0)
over = Route(over_start)
follow(over, [over_start, dest(cross_pt, (st["heading"] + 90) % 360, 1000.0)], 90 / 3.6)
ev, hid = sim_point(over.fixes, SR)
ev_old, _ = sim_point(over.fixes, SR, use_roads=False)
assert ev_old and ev_old[0][1]["level"] == "full", "the straight-line rule speaks on the overpass today"
assert all(e["kind"] != "warn" or (e["level"] == "visual" and e.get("held")) for _, e in ev), ev
vector("road-overpass-90deg", "A road crossing over the radar's road at 90 degrees, 100 m before the radar, at 90 km/h: the straight-line rule would speak (the radar is straight ahead of the overpass), but the car is far off the radar's road, so the warning is held silent and never spoken. The held row is the design's: a car clearly off the road still gets a silent notification.", over, sorted_events(ev))

# ---- 15. The 1,000 m arc ----
AR = "fixed-arc-road"
arc_lls = local("arc", GEOM["arc"]["road"])
r = Route(arc_lls[0])
follow(r, arc_lls, 90 / 3.6)
r.fixes = r.fixes[int((2618 - 2000) / 25):]
ev, _ = sim_point(r.fixes, AR)
assert [e["kind"] for _, e in ev] == ["warn", "passed"] and ev[0][1]["level"] == "full", ev
passed_near(AR, ev)
vector("road-arc-1000m", "90 km/h round a 1,000 m radius curve into a radar: the warning comes at 625 m measured along the curve, not as the crow flies, and the pass is at the radar.", r, sorted_events(ev))

# ---- 16. Three switchbacks ----
HR = "fixed-hairpin-road"
hp = GEOM["hairpin"]
to_radar_lls = local("hairpin", hp["to_radar"])
appr = approaches_of(HR)[0]
start_along = appr.length - 1480.0
hairpin_road_lls = local("hairpin", hp["road"])
# Start on the approach, 1,480 m before the radar along the road, 40 km/h, and drive 200 m past it on the top leg.
start_ll = appr.at(start_along)
def hairpin_path():
    pts = local("hairpin", hp["road"])
    # Cut the road at the start point (on leg 1).
    k = min(range(len(pts)), key=lambda j: hav(pts[j], start_ll))
    return [start_ll] + pts[k + 1:]
hpath = hairpin_path()
r = Route(start_ll)
follow(r, hpath, 40 / 3.6, stop_after=1480.0 + 200.0)
ev, _ = sim_point(r.fixes, HR)
assert [e["kind"] for _, e in ev] == ["warn", "passed"] and ev[0][1]["level"] == "full", ev
passed_near(HR, ev)
vector("road-hairpin", "40 km/h up a road with three switchbacks to a radar on the top leg: the straight-line distance falls and rises on every leg, but along the road it only falls, so exactly one full warning at the along-road warn distance and the pass at the radar.", r, sorted_events(ev))
hairpin_fixes = r.fixes

rb = Route(start_ll)
follow(rb, hpath, 40 / 3.6, bias=(0.0, 20.0), stop_after=1480.0 + 200.0)
ev, _ = sim_point(rb.fixes, HR)
assert [e["kind"] for _, e in ev] == ["warn", "passed"] and ev[0][1]["level"] == "full", ev
first_pass = next(i for i, e in ev if e["kind"] == "passed")
assert hav((rb.fixes[first_pass]["lat"], rb.fixes[first_pass]["lon"]), RADARS[HR]["start"]) < 60, "no pass before the radar"
vector("road-hairpin-biased", "The switchback drive with every fix 20 m north of the road, toward the leg above: the nearer leg runs the other way, so the course test keeps the car on its own leg; still exactly one full warning, and no pass before the radar.", rb, sorted_events(ev))

ev, _ = sim_point(hairpin_fixes, HR, use_roads=False)
vector("road-hairpin-fallback", "The switchback drive with no road geometry: today's straight-line rule, which fires on the bottom leg while the radar is 105 m away above it and then marks it passed as the car climbs away from it. This is the status quo the road rule fixes, kept so the fallback stays byte for byte.", Route(start_ll), sorted_events(ev), roadsDisabled=True)
VECTORS[-1]["fixes"] = hairpin_fixes
fallback_events = VECTORS[-1]["expected"]

# ---- 17. Dual carriageway with a high- and a low-confidence travel bearing ----
du = GEOM["dual"]
north_lls, south_lls = local("dual", du["north"]), local("dual", du["south"])
DH, DL = "fixed-dual-high-road", "fixed-dual-low-road"
r = Route(north_lls[0])
follow(r, north_lls, 100 / 3.6, stop_after=7500.0)
r.fixes = r.fixes[int(500 / (100 / 3.6)):]
eh, _ = sim_point(r.fixes, DH)
el, _ = sim_point(r.fixes, DL)
assert [e["level"] for _, e in eh + el if e["kind"] == "warn"] == ["full", "full"], (eh, el)
vector("road-dual-same", "100 km/h on the northbound carriageway past both radars of the dual carriageway (one with a high-confidence travel bearing, one with a low one): both are the car's flow, two full warnings and two passes.", r, sorted_events(eh, el))

r = Route(south_lls[0])
follow(r, south_lls, 100 / 3.6)
r.fixes = [f for f in r.fixes if 1000 <= hav((f["lat"], f["lon"]), south_lls[-1]) <= 5000]
eh, hid = sim_point(r.fixes, DH)
el, _ = sim_point(r.fixes, DL)
assert eh == [] and el == [] and [x[1] for x in hid] == [DH], (eh, el, hid)
vector("road-dual-opposite-high", "100 km/h on the southbound carriageway, 25 m from a radar whose travel bearing is northbound with high confidence: nothing is shown or spoken. The engine still produces the hidden warning (for the log row with suppressedByDirection), which the harness checks apart.", r, [], hidden=[DH])

r = Route(south_lls[0])
follow(r, south_lls, 100 / 3.6)
r.fixes = [f for f in r.fixes if 4800 <= hav((f["lat"], f["lon"]), south_lls[-1]) <= 8500]
el, hid = sim_point(r.fixes, DL)
eh, _ = sim_point(r.fixes, DH)
assert eh == [] and hid == [] and el[0][1]["level"] == "visual" and el[0][1]["opposite"], el
vector("road-dual-opposite-low", "The same southbound drive past the radar whose northbound bearing has low confidence: shown as sentido contrario, silent, as an OSM bearing is today; then passed.", r, sorted_events(el))

# ---- 18. A side road joining 300 m before the radar ----
SJ = "fixed-sidejoin-road"
sj = GEOM["sidejoin"]
path = local("sidejoin", sj["side"]) + local("sidejoin", [(0.0, 0.0), (0.0, 300.0)])
r = Route(path[0])
follow(r, path, 90 / 3.6)
ev, _ = sim_point(r.fixes, SJ)
kinds = [(e["kind"], e.get("level"), e.get("held", False)) for _, e in ev]
assert kinds == [("warn", "visual", True), ("warn", "full", False), ("passed", None, False)], kinds
assert ev[1][1]["late"] and 200 <= ev[1][1]["distance"] <= 340, ev[1]
passed_near(SJ, ev)
vector("road-side-join-late", "90 km/h on a side road that joins the radar's road 300 m before it: while the car is on the side road the straight-line warning is held silent; once it joins the road it is spoken once, late, with the along-road distance; then passed.", r, sorted_events(ev))

# ---- 19. The bowed corridor: gate entry, along, mid-join, polyline loss ----
CR = "dgt_invive-curve-road"
line, gates_start, gates_end = line_of(CR)
co = GEOM["corridor"]
S_ll, E_ll = RADARS[CR]["start"], RADARS[CR]["end"]


def chord_along(p, a, b):
    """Geo.alongChord, spherical."""
    d13 = hav(a, p)
    if d13 <= 0 or hav(a, b) <= 0:
        return 0.0
    crs = bearing(a, b)
    xt = math.asin(math.sin(d13 / R) * math.sin(math.radians(bearing(a, p) - crs)))
    ratio = min(1, max(-1, math.cos(d13 / R) / math.cos(xt)))
    along = math.acos(ratio) * R
    return -along if angle_diff(crs, bearing(a, p)) > 90 else along


def sim_corridor(fixes, rid):
    """One stretch through design 2.5 with a road line: entry along a gate approach (else the cone), the join along
    the line, the remaining along it (the chord after Thresholds.stretchPolylineLossFixes misses), the four exits."""
    r = RADARS[rid]
    p = r["p"]
    S, E = r["start"], r["end"]
    chord_len = hav(S, E)
    road_m = abs(p["km_to"] - p["km_from"]) * 1000
    boxes = line.chunk_boxes()
    events, remaining = [], {}
    speeds, hist, gate_hist, mid_run = [], [], {}, 0
    inside = None
    done = False
    for i, f in enumerate(fixes):
        t = fix_time(f)
        if f["speed"] is not None and f["speed"] >= 0:
            speeds = (speeds + [f["speed"]])[-3:]
        med = median3(speeds)
        w = warn(med or 0)
        pos = (f["lat"], f["lon"])
        course = f["course"]
        # A candidate by its chord (store) or by a box of its road (roads.lineCandidates).
        dlat = (w + BAND) / 111320
        dlon = (w + BAND) / (111320 * max(0.01, math.cos(math.radians(pos[0]))))
        in_box = any(not (b[1] < pos[0] - dlat or b[0] > pos[0] + dlat or b[3] < pos[1] - dlon or b[2] > pos[1] + dlon) for b in boxes)
        along_c = chord_along(pos, S, E)
        chord_d = hav(pos, S) if along_c <= 0 else hav(pos, E) if along_c >= chord_len else abs(math.asin(math.sin(hav(S, pos) / R) * math.sin(math.radians(bearing(S, pos) - bearing(S, E)))) * R)
        cand = (not done and inside is None) and (chord_d <= w + BAND or in_box)
        gd = min(hav(pos, S), hav(pos, E))
        prev = hist[:]
        if cand:
            hist = hist + [gd]
            if len(hist) > 8:
                del hist[1]
        else:
            hist = [] if inside is None else hist
        if inside is not None:
            st = inside
            far = st["far"]
            fwd = st["gate"] == S
            a_chord = min(hav(st["gate"], far), max(0, chord_along(pos, st["gate"], far)))
            prevo = {"index": 0, "along": st["last"][0], "at": st["last"][1]} if st["last"] else None
            m = road_match([line], pos, course, f["accuracy"], prevo, t, med if med is not None else f["speed"], forward=fwd, backward=not fwd)
            if m:
                st["last"] = (m["along"], t)
                st["misses"], st["lost"], st["once"] = 0, False, True
                st["rem"] = max(0, line.length - (m["along"] if fwd else line.length - m["along"]))
            else:
                st["last"] = None
                if f["accuracy"] <= LOSS_ACC:
                    st["misses"] += 1
                if st["misses"] >= LOSS_FIXES:
                    st["lost"] = True
                if st["lost"] or not st["once"]:
                    st["rem"] = max(0, st["chord"] - a_chord)
            remaining[i] = st["rem"]
            length_m = max(road_m, chord_len, st["chord"], line.length)
            elapsed = (t - st["t"]).total_seconds()
            reason = None
            if hav(pos, far) <= EXIT_GATE:
                reason = "farGate"
            elif hav(pos, st["gate"]) > length_m + EXIT_SLACK:
                reason = "distance"
            elif st["v"] and elapsed > EXIT_TIME * (length_m / st["v"]):
                reason = "time"
            if reason:
                events.append((i, exited(rid, reason, "Fin de tramo." if reason == "farGate" else None)))
                inside, done = None, True
            continue
        if not cand or course is None:
            if course is None:
                mid_run = 0
            gate_hist = {} if course is None else gate_hist
            continue
        entered_now = None
        matches, on_gate = {}, False
        kept = {}
        for side, pls, g, fr in (("start", gates_start, S, E), ("end", gates_end, E, S)):
            if not pls:
                continue
            m = road_evaluate(pls, f, t, course, med if med is not None else f["speed"], gate_hist.get(side), w)
            if m is None:
                continue
            kept[side] = m["hist"]
            on_gate = True
            if m["level"] and (side not in matches or m["distance"] < min(x["distance"] for x in matches.values())):
                matches = {side: dict(m, gate=g, far=fr)}
        gate_hist = kept
        if matches:
            m = list(matches.values())[0]
            entered_now = (m["gate"], m["far"], m["distance"], None)
        elif not on_gate:
            near, far = (S, E) if hav(pos, S) <= hav(pos, E) else (E, S)
            a = straight_eval(f, near, course, prev, w, None, True)
            if a["level"] and angle_diff(course, bearing(near, far)) <= 60:
                entered_now = (near, far, a["distance"], None)
        if entered_now is None:
            m = road_match([line], pos, course, f["accuracy"], forward=True, backward=True)
            ok = m is not None and EXIT_GATE < m["along"] < line.length - EXIT_GATE
            mid_run = mid_run + 1 if ok else 0
            if ok and mid_run >= MID_FIXES:
                rem = line.length - m["along"] if m["forward"] else m["along"]
                entered_now = ((S, E) if m["forward"] else (E, S)) + (rem, rem)
                last = (m["along"], t)
            else:
                last = None
        else:
            last = None
        if entered_now:
            g, fr, d, rem = entered_now
            inside = {"gate": g, "far": fr, "chord": hav(g, fr), "t": t, "v": med, "last": last, "misses": 0, "lost": False,
                      "once": last is not None, "rem": rem if rem is not None else line.length}
            remaining[i] = inside["rem"]
            mid_run = 0
            spoken = corridor_joined_sentence(rid, rem) if rem is not None else corridor_sentence(rid)
            events.append((i, entered(rid, d, spoken, tol=60 if rem is not None else 40)))
    return events, remaining


bow_lls = local("corridor", co["bow"])
gate_in_lls = local("corridor", co["gate_in"])
beyond_lls = local("corridor", co["beyond_east"])
full_path = gate_in_lls + bow_lls[1:] + beyond_lls[1:301]
r = Route(full_path[0])
follow(r, full_path, 90 / 3.6, stop_after=1500.0 + 1000.0)
ev, rem = sim_corridor(r.fixes, CR)
assert [e["kind"] for _, e in ev] == ["stretchEntered"] and abs(ev[0][1]["distance"] - 625) <= 40, ev
# What the cone would do on the same fixes: the course is more than 60 degrees off the chord until about 200 m.
cone_i = None
hist = []
for i, f in enumerate(r.fixes):
    pos = (f["lat"], f["lon"])
    d = hav(pos, S_ll)
    a = straight_eval(f, S_ll, f["course"], hist, warn(25), None, True)
    hist = (hist + [d])
    if a["level"] and angle_diff(f["course"], bearing(S_ll, E_ll)) <= 60:
        cone_i = i
        break
cone_d = hav((r.fixes[cone_i]["lat"], r.fixes[cone_i]["lon"]), S_ll)
assert cone_d < 300, cone_d
vector("corridor-curve-gate-entry", f"90 km/h on a road that curves into a bowed mobile corridor and meets it at 40 degrees to its chord: the gate approach enters it at 625 m along the road. The straight-line cone would enter only {int(cone_d)} m before the gate, because the course is more than 60 degrees off the chord until then.", r, sorted_events(ev))

r = Route(full_path[0])
follow(r, full_path, 90 / 3.6)
ev, rem = sim_corridor(r.fixes, CR)
assert [e["kind"] for _, e in ev] == ["stretchEntered", "stretchExited"] and ev[1][1]["exitReason"] == "farGate", ev
enter_i = ev[0][0]
mid = enter_i + 200
along_mid = line.projections((r.fixes[mid]["lat"], r.fixes[mid]["lon"]))
along_mid = min(along_mid)[1]
assert abs(rem[mid] - (line.length - along_mid)) < 5
vector("corridor-curve-along", "The bowed corridor driven end to end: inside, the remaining distance is the road line's length minus the car's position along it (not chord minus projection, 1.4 km short on this bow); Fin de tramo at the far gate.", r, sorted_events(ev),
       snapshots=[{"fixIndex": mid, "stretch": CR, "remainingMetres": round(line.length - along_mid), "tolerance": 60, "phase": "insideStretch"}])

join_along = line.length / 2 - 600
mid_path = [line.at(join_along + k * 100) for k in range(int((line.length - join_along) / 100) + 1)] + [line.at(line.length)] + beyond_lls[1:5]
r = Route(mid_path[0])
follow(r, mid_path, 90 / 3.6)
ev, rem = sim_corridor(r.fixes, CR)
assert [e["kind"] for _, e in ev] == ["stretchEntered", "stretchExited"] and ev[0][0] == 2, ev
chord_off = abs(math.asin(math.sin(hav(S_ll, mid_path[0]) / R) * math.sin(math.radians(bearing(S_ll, mid_path[0]) - bearing(S_ll, E_ll)))) * R)
assert chord_off > 1900, chord_off
mid = 100
along_mid = min(line.projections((r.fixes[mid]["lat"], r.fixes[mid]["lon"])))[1]
vector("corridor-curve-mid-join-on-bow", f"The bowed corridor joined from a side road at its middle, {int(chord_off)} m off the chord: the car is on the road line, so it is inside after three fixes and the remaining road is spoken (the chord rule needs 150 m and would never join here).", r, sorted_events(ev),
       snapshots=[{"fixIndex": mid, "stretch": CR, "remainingMetres": round(line.length - along_mid), "tolerance": 60, "phase": "insideStretch"}])

# Polyline loss: 2.5 km into the bow the car leaves the line for a bypass 400 m inside it, and rejoins 4.5 km later.
inner = offset_lls = None
leave_at, back_at = 2500.0, 7000.0
by = [line.at(leave_at)]
for k in range(0, 36):
    a = 3000.0 + k * 100
    pt = line.at(a)
    nxt = line.at(a + 10)
    h = bearing(pt, nxt)
    by.append(dest(pt, (h + 90) % 360, 400.0))
by.append(line.at(back_at))
loss_path = gate_in_lls + [line.at(x * 100) for x in range(1, int(leave_at / 100))] + by + [line.at(back_at + k * 100) for k in range(1, int((line.length - back_at) / 100) + 1)] + [E_ll] + beyond_lls[1:5]
r = Route(loss_path[0])
follow(r, loss_path, 90 / 3.6)
ev, rem = sim_corridor(r.fixes, CR)
assert [e["kind"] for _, e in ev] == ["stretchEntered", "stretchExited"] and ev[1][1]["exitReason"] == "farGate", ev
leave_i = next(i for i, f in enumerate(r.fixes) if i > ev[0][0] + 30 and line.min_lateral((f["lat"], f["lon"])) > 100)
lost_i = leave_i + 30
f = r.fixes[lost_i]
chord_est = hav(S_ll, E_ll) - min(hav(S_ll, E_ll), max(0, chord_along((f["lat"], f["lon"]), S_ll, E_ll)))
assert abs(rem[lost_i] - chord_est) < 1, (rem[lost_i], chord_est)
vector("corridor-curve-polyline-loss", "The bowed corridor with a 4.5 km detour 400 m off its road line: after five fixes off the line the remaining distance falls back to the chord estimate, nothing ends the corridor, the car comes back to the line and Fin de tramo is spoken at the far gate.", r, sorted_events(ev),
       snapshots=[{"fixIndex": lost_i, "stretch": CR, "remainingMetres": round(chord_est), "tolerance": 60, "phase": "insideStretch"}])

# The other carriageway at the west gate, leaving the corridor: never entered.
out_lls = local("corridor", co["gate_out"])
r = Route(out_lls[0])
follow(r, out_lls, 90 / 3.6)
ev, rem = sim_corridor(r.fixes, CR)
assert ev == [], ev
vector("corridor-curve-gate-opposite-carriageway", "The other carriageway of the road into the corridor's west gate, driven away from the corridor from 25 m beside the gate: the gate approach runs the other way, nothing is entered.", r, [])

assert fallback_events != next(v for v in VECTORS if v["name"] == "road-hairpin")["expected"], "the fallback must differ from the road rule"

# Negative control for the road rule: the switchback drive expected with today's straight-line events.
VECTORS.append(
    {
        "name": "broken-road-hairpin-straight-line",
        "description": "Deliberately wrong: the switchback drive with the sidecar loaded but the status quo's expectation (a warning on the bottom leg and a false pass). The suite asserts that the engine's output differs, which proves the road rule changes what the car hears.",
        "locale": "es-ES",
        "negativeControl": True,
        "fixes": hairpin_fixes,
        "expected": fallback_events,
    }
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
