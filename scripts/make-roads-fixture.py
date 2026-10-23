#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Write the synthetic road fixture: Tests/RadaresCoreTests/Fixtures/feed-sample-roads.geojson and roads-sample.json.

    python3 -I scripts/make-roads-fixture.py

Each scenario is a small road layout in its own place, at least 10 km from every feature of feed-sample.geojson
and from each other, so the 28 straight-line vectors never see it. Ids end in -road. The polylines are encoded here
with Google's polyline algorithm at precision 5, the format of roads.json (docs/SPEC.md, "Road geometry sidecar").
make-vectors.py loads this file with runpy for the same geometry (GEOMETRY) and the car paths beside the roads.
"""
import json
import math
import os

R = 6371000.0
KY = R * math.pi / 180
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, "Tests", "RadaresCoreTests", "Fixtures")


def encode(coords, precision=5):
    """Google's encoded polyline algorithm: latitude then longitude per vertex, deltas, zigzag, 5-bit chunks + 63."""
    factor = 10 ** precision
    out = []
    plat = plon = 0
    for lat, lon in coords:
        ilat, ilon = int(round(lat * factor)), int(round(lon * factor))
        for v in (ilat - plat, ilon - plon):
            v = ~(v << 1) if v < 0 else (v << 1)
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        plat, plon = ilat, ilon
    return "".join(out)


def decode(s, precision=5):
    factor = 10 ** precision
    coords, lat, lon, i = [], 0, 0, 0
    while i < len(s):
        vals = []
        for _ in range(2):
            result = shift = 0
            while True:
                b = ord(s[i]) - 63
                i += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            vals.append(~(result >> 1) if result & 1 else result >> 1)
        lat += vals[0]
        lon += vals[1]
        coords.append((lat / factor, lon / factor))
    return coords


assert encode([(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]) == "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
assert decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@") == [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]


class Frame:
    """Local metres (x east, y north) around an origin, flat: exact enough over a few kilometres."""

    def __init__(self, lat0, lon0):
        self.lat0, self.lon0 = lat0, lon0
        self.kx = KY * math.cos(math.radians(lat0))

    def ll(self, x, y):
        return (self.lat0 + y / KY, self.lon0 + x / self.kx)

    def lls(self, pts):
        return [self.ll(x, y) for x, y in pts]


def heading_vec(h):
    return (math.sin(math.radians(h)), math.cos(math.radians(h)))


def straight(p, h, length, step=50.0):
    """Points from p along heading h for `length` metres, every `step`."""
    dx, dy = heading_vec(h)
    n = max(1, int(math.ceil(length / step)))
    return [(p[0] + dx * length * k / n, p[1] + dy * length * k / n) for k in range(n + 1)]


def arc(center, radius, a0, a1, step=20.0):
    """Points on a circle, angles in degrees measured like headings (0 = north, clockwise), from a0 to a1."""
    sweep = math.radians(abs(a1 - a0)) * radius
    n = max(2, int(math.ceil(sweep / step)))
    out = []
    for k in range(n + 1):
        a = math.radians(a0 + (a1 - a0) * k / n)
        out.append((center[0] + radius * math.sin(a), center[1] + radius * math.cos(a)))
    return out


def cat(*parts):
    out = []
    for part in parts:
        for p in part:
            if not out or math.hypot(p[0] - out[-1][0], p[1] - out[-1][1]) > 1e-6:
                out.append(p)
    return out


def length(pts):
    return sum(math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]) for i in range(1, len(pts)))


def cut_last(pts, metres):
    """The last `metres` of a polyline (local points), as a polyline ending at its last point."""
    out = [pts[-1]]
    left = metres
    for i in range(len(pts) - 1, 0, -1):
        a, b = pts[i], pts[i - 1]
        seg = math.hypot(b[0] - a[0], b[1] - a[1])
        if seg >= left:
            f = left / seg
            out.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
            break
        out.append(b)
        left -= seg
    return out[::-1]


def offset(pts, metres):
    """The polyline moved `metres` to the left of its direction (negative: right)."""
    out = []
    for i, p in enumerate(pts):
        a = pts[max(0, i - 1)]
        b = pts[min(len(pts) - 1, i + 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        n = math.hypot(dx, dy)
        out.append((p[0] - dy / n * metres, p[1] + dx / n * metres))
    return out


APPROACH_M = 1500.0
GEOMETRY = {}
FEATURES = []
ROADS = {}


def point_feature(fid, ll, name, road=None, maxspeed=None, direction=None, extra=None):
    props = {"name": name, "source": "dgt", "kind": "fixed", "active": True, "valid_from": None, "valid_to": None,
             "maxspeed": maxspeed, "direction": direction, "province": "13", "url": None,
             "attribution": "Synthetic road fixture"}
    if road:
        props["road_ref"] = road
    if extra:
        props.update(extra)
    FEATURES.append({"type": "Feature", "id": fid, "geometry": {"type": "Point", "coordinates": [round(ll[1], 7), round(ll[0], 7)]}, "properties": props})


def approach_entry(frame, pts):
    lls = frame.lls(pts)
    return {"polyline": encode(lls), "bearing": None}


# ---- 1. A straight road heading 60 degrees, a parallel road 150 m beside it, a road crossing over it at 90
# degrees 100 m before the radar. ----
F1 = Frame(39.20, -4.20)
road1 = straight((0.0, 0.0), 60.0, 3000.0, step=100.0)  # the radar at 2,500 m
radar1 = (road1[0][0] + heading_vec(60)[0] * 2500, road1[0][1] + heading_vec(60)[1] * 2500)
road1_to_radar = [p for p in road1 if math.hypot(p[0] - road1[0][0], p[1] - road1[0][1]) < 2500 - 1e-6] + [radar1]
GEOMETRY["straight"] = {"frame": F1, "road": road1, "radar": radar1, "heading": 60.0}
point_feature("fixed-straight-road", F1.ll(*radar1), "Radar fijo carretera recta")
ROADS["fixed-straight-road"] = {"approaches": [approach_entry(F1, cut_last(road1_to_radar, APPROACH_M))]}

# ---- 2. A 1,000 m radius arc into the radar. ----
F2 = Frame(39.20, -3.80)
arc2 = arc((0.0, 0.0), 1000.0, -90.0, 60.0, step=20.0)  # 150 degrees of arc, 2,618 m, clockwise from the west
GEOMETRY["arc"] = {"frame": F2, "road": arc2 + straight(arc2[-1], 150.0, 500.0, step=50.0)[1:], "radar": arc2[-1]}
point_feature("fixed-arc-road", F2.ll(*arc2[-1]), "Radar fijo curva", maxspeed=90)
ROADS["fixed-arc-road"] = {"approaches": [approach_entry(F2, cut_last(arc2, APPROACH_M))]}

# ---- 3. A mountain road with three switchbacks: four legs 350 m long, 35 m apart, joined by half circles. ----
F3 = Frame(39.20, -3.40)
SEP, LEG = 35.0, 350.0
legs = []
leg1 = straight((-600.0, 0.0), 90.0, 600.0 + LEG, step=25.0)
hp1 = arc((LEG, SEP / 2), SEP / 2, 180.0, 0.0, step=4.0)  # east end, turning left (counterclockwise)
leg2 = straight((LEG, SEP), 270.0, LEG, step=25.0)
hp2 = arc((0.0, SEP * 1.5), SEP / 2, 180.0, 360.0, step=4.0)  # west end, turning right
leg3 = straight((0.0, 2 * SEP), 90.0, LEG, step=25.0)
hp3 = arc((LEG, SEP * 2.5), SEP / 2, 180.0, 0.0, step=4.0)
leg4 = straight((LEG, 3 * SEP), 270.0, LEG + 300.0, step=25.0)
hairpin = cat(leg1, hp1, leg2, hp2, leg3, hp3, leg4)
radar3 = (100.0, 3 * SEP)
to_radar3 = cat(leg1, hp1, leg2, hp2, leg3, hp3, [p for p in leg4 if p[0] > 100.0 + 1e-6], [radar3])
GEOMETRY["hairpin"] = {"frame": F3, "road": hairpin, "to_radar": to_radar3, "radar": radar3}
point_feature("fixed-hairpin-road", F3.ll(*radar3), "Radar fijo puerto de montaña")
ROADS["fixed-hairpin-road"] = {"approaches": [approach_entry(F3, cut_last(to_radar3, APPROACH_M))]}

# ---- 4. A dual carriageway, northbound at x = 0 and southbound 25 m west. Two radars on the northbound side,
# one with a high-confidence travel bearing (km 3) and one with a low-confidence one (km 6.5). ----
F4 = Frame(39.20, -3.00)
north = straight((0.0, 0.0), 0.0, 10000.0, step=250.0)
south = straight((-25.0, 10000.0), 180.0, 10000.0, step=250.0)
GEOMETRY["dual"] = {"frame": F4, "north": north, "south": south, "high": (0.0, 3000.0), "low": (0.0, 6500.0)}
for fid, y, conf, src in (("fixed-dual-high-road", 3000.0, "high", "official_km"), ("fixed-dual-low-road", 6500.0, "low", "osm_tag")):
    point_feature(fid, F4.ll(0.0, y), "Radar fijo autovía", road="A-99", maxspeed=120,
                  extra={"km": y / 1000, "km_direction": "positive", "bearing": 0, "direction_semantics": "travel", "direction_confidence": conf, "bearing_source": src})
    ROADS[fid] = {"approaches": [approach_entry(F4, straight((0.0, y - APPROACH_M), 0.0, APPROACH_M, step=250.0))]}

# ---- 5. A main road north into a radar, and a side road joining it 300 m before the radar at 40 degrees. ----
F5 = Frame(39.50, -4.20)
radar5 = (0.0, 0.0)
junction5 = (0.0, -300.0)
main5 = straight((0.0, -2000.0), 0.0, 2300.0, step=100.0)
side5 = straight((junction5[0] + heading_vec(140)[0] * 1500, junction5[1] + heading_vec(140)[1] * 1500), 320.0, 1500.0, step=50.0)
GEOMETRY["sidejoin"] = {"frame": F5, "main": main5, "side": side5, "junction": junction5, "radar": radar5}
point_feature("fixed-sidejoin-road", F5.ll(*radar5), "Radar fijo cruce")
ROADS["fixed-sidejoin-road"] = {"approaches": [approach_entry(F5, straight((0.0, -APPROACH_M), 0.0, APPROACH_M, step=100.0))]}

# ---- 6. A mobile corridor whose road bows 2 km north of its chord (chord / road = 0.85), with a gate approach
# curving into its west end at 40 degrees to the chord, a dual carriageway at that end, and a straight gate
# approach into its east end. ----
F6 = Frame(39.50, -3.70)
CHORD = 8000.0
half = 0.95798  # chord / arc = sin(h) / h = 0.85
radius6 = CHORD / 2 / math.sin(half)
sag = radius6 * (1 - math.cos(half))
S6, E6 = (0.0, 0.0), (CHORD, 0.0)
center6 = (CHORD / 2, sag - radius6)
deg = math.degrees(half)
bow = arc(center6, radius6, -deg, deg, step=100.0)  # from the west gate clockwise over the top to the east gate
bow[0], bow[-1] = S6, E6
# Into the west gate: a 600 m radius curve ending with heading 50 (40 degrees off the chord, which heads 90).
ACURVE = 600.0
end_heading = 50.0
# Center of the curve: to the right of the final heading (the car turns right, toward the chord, as it arrives).
cx, cy = S6[0] + ACURVE * math.sin(math.radians(end_heading + 90)), S6[1] + ACURVE * math.cos(math.radians(end_heading + 90))
a_end = (math.degrees(math.atan2(S6[0] - cx, S6[1] - cy)) + 360) % 360
sweep = math.degrees(APPROACH_M / ACURVE)
gate_in = arc((cx, cy), ACURVE, a_end - sweep, a_end, step=20.0)
gate_in[-1] = S6
out_carriageway = offset(gate_in, -25.0)[::-1]  # the other carriageway, 25 m to the right of the inbound side, leaving
# Into the east gate: the road beyond the gate, straight, continuing the bow's tangent there.
east_heading = (90.0 + deg) % 360  # the bow arrives at E heading this way
gate_east = straight((E6[0] + heading_vec(east_heading)[0] * APPROACH_M, E6[1] + heading_vec(east_heading)[1] * APPROACH_M), (east_heading + 180) % 360, APPROACH_M, step=100.0)
gate_east[-1] = E6
GEOMETRY["corridor"] = {"frame": F6, "bow": bow, "gate_in": gate_in, "gate_out": out_carriageway, "gate_east": gate_east,
                        "beyond_east": straight(E6, east_heading, 1500.0, step=100.0), "sagitta": sag, "radius": radius6}
road_len = length(bow)
FEATURES.append({
    "type": "Feature", "id": "dgt_invive-curve-road",
    "geometry": {"type": "LineString", "coordinates": [[round(F6.ll(*S6)[1], 7), round(F6.ll(*S6)[0], 7)], [round(F6.ll(*E6)[1], 7), round(F6.ll(*E6)[0], 7)]]},
    "properties": {"name": "Tramo de radar móvil N-999", "source": "dgt_invive", "kind": "stretch", "active": True, "valid_from": None, "valid_to": None,
                   "maxspeed": None, "direction": "both", "province": "13", "url": None, "attribution": "Synthetic road fixture",
                   "road": "N-999", "km_from": 10.0, "km_to": round(10.0 + road_len / 1000, 3)},
})
ROADS["dgt_invive-curve-road"] = {
    "line": encode(F6.lls(bow)),
    "gates": {"start": [approach_entry(F6, gate_in)], "end": [approach_entry(F6, gate_east)]},
}

# ---- 7. A mobile corridor that starts at the top of a switchback road: the gate approach into its start is the last 1,500 m of the switchbacks, and the corridor runs on west-north-west from there. On the legs heading
# west the straight-line cone sees the gate ahead, close and on the chord's course long before the road gets there. ----
F7 = Frame(39.80, -3.00)
s_legs = cat(
    straight((-600.0, 0.0), 90.0, 600.0 + LEG, step=25.0),
    arc((LEG, SEP / 2), SEP / 2, 180.0, 0.0, step=4.0),
    straight((LEG, SEP), 270.0, LEG, step=25.0),
    arc((0.0, SEP * 1.5), SEP / 2, 180.0, 360.0, step=4.0),
    straight((0.0, 2 * SEP), 90.0, LEG, step=25.0),
    arc((LEG, SEP * 2.5), SEP / 2, 180.0, 0.0, step=4.0),
    straight((LEG, 3 * SEP), 270.0, LEG, step=25.0),
)
S7 = s_legs[-1]
E7 = (S7[0] + heading_vec(300.0)[0] * 6000.0, S7[1] + heading_vec(300.0)[1] * 6000.0)
line7 = straight(S7, 300.0, 6000.0, step=500.0)
line7[-1] = E7
GEOMETRY["switchback_corridor"] = {"frame": F7, "road": s_legs, "line": line7}
FEATURES.append({
    "type": "Feature", "id": "dgt_invive-switchback-road",
    "geometry": {"type": "LineString", "coordinates": [[round(F7.ll(*S7)[1], 7), round(F7.ll(*S7)[0], 7)], [round(F7.ll(*E7)[1], 7), round(F7.ll(*E7)[0], 7)]]},
    "properties": {"name": "Tramo de radar móvil N-998", "source": "dgt_invive", "kind": "stretch", "active": True, "valid_from": None, "valid_to": None,
                   "maxspeed": None, "direction": "both", "province": "13", "url": None, "attribution": "Synthetic road fixture",
                   "road": "N-998", "km_from": 20.0, "km_to": 26.0},
})
ROADS["dgt_invive-switchback-road"] = {
    "line": encode(F7.lls(line7)),
    "gates": {"start": [approach_entry(F7, cut_last(s_legs, APPROACH_M))], "end": []},
}


def place_check():
    """Every synthetic feature at least 10 km from every feed-sample feature and from the other scenarios."""
    def hav(a, b):
        la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
        h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
        return 2 * R * math.asin(math.sqrt(h))
    sample = json.load(open(os.path.join(FIX, "feed-sample.geojson"), encoding="utf-8"))
    pts = []
    for f in sample["features"]:
        g = f["geometry"]
        cs = [g["coordinates"]] if g["type"] == "Point" else g["coordinates"]
        pts += [(c[1], c[0]) for c in cs]
    for f in FEATURES:
        g = f["geometry"]
        cs = [g["coordinates"]] if g["type"] == "Point" else g["coordinates"]
        for c in cs:
            near = min(hav((c[1], c[0]), p) for p in pts)
            assert near >= 10000, (f["id"], near)


if __name__ == "__main__":
    place_check()
    feed = {"type": "FeatureCollection", "features": FEATURES}
    with open(os.path.join(FIX, "feed-sample-roads.geojson"), "w", encoding="utf-8") as fh:
        json.dump(feed, fh, ensure_ascii=False, indent=1)
    roads = {"version": 1, "attribution": "© OpenStreetMap contributors (ODbL 1.0)", "precision": 5, "features": ROADS}
    with open(os.path.join(FIX, "roads-sample.json"), "w", encoding="utf-8") as fh:
        json.dump(roads, fh, ensure_ascii=False, indent=1, sort_keys=True)
    for fid in sorted(ROADS):
        e = ROADS[fid]
        if "line" in e:
            print(f"{fid:28} line {len(decode(e['line']))} vertices, gates {len(e['gates']['start'])}+{len(e['gates']['end'])}")
        else:
            print(f"{fid:28} {len(e['approaches'])} approach(es), {[len(decode(a['polyline'])) for a in e['approaches']]} vertices")
