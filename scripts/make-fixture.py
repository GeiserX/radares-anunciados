#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build Tests/RadaresCoreTests/Fixtures/feed-sample.geojson from a copy of the live feed.

    python3 -I scripts/make-fixture.py /path/to/feed.geojson

Picks about 250 real features: every kind, the two 13-vertex Salamanca lines, -from/-to section twins,
the A-2 radar, the N-232 corridor, the Z-40 average-speed section, every negative OSM bearing, the
León and Murcia weekly lists, an unpaired sct section, and a spread of the rest. Features near a route
vector's target are dropped unless they are wanted, so the vectors meet only the radars they are about.
The selection is deterministic: the same feed gives the same file. Run it only when a vector needs a
radar the fixture lacks; the vectors in Fixtures/vectors depend on the ids and coordinates in here.
"""
import json
import math
import sys
from collections import Counter

R = 6371000.0


def hav(a, b):
    la1, lo1 = math.radians(a[1]), math.radians(a[0])
    la2, lo2 = math.radians(b[1]), math.radians(b[0])
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def gates(f):
    g = f["geometry"]
    if g["type"] == "Point":
        return [g["coordinates"]]
    return [g["coordinates"][0], g["coordinates"][-1]]


def is_numeric(s):
    return isinstance(s, str) and s.lstrip("-").isdigit()


def main(path, out):
    feed = json.load(open(path))
    features = feed["features"]
    byid = {f["id"]: f for f in features}
    props = lambda f: f["properties"]

    # Targets of the route vectors: nothing else from the feed may sit within 3 km of their gates
    # unless it is listed in `wanted` below.
    targets = [
        "dgt-CABINACINEMOMETRO_120001",  # A-2 fixed, direction text ZARAGOZA
        "dgt_invive-Tramo_Invive_344",  # N-232 mobile corridor, 10.1 km
        "dgt-CVM_161274",  # Z-40 average-speed section with -from/-to twins
        "leon-2026-10-07-avenida-de-los-antibioticos-2",  # León weekly list, active, limit 50
        "osm-619772731",  # OSM fixed, direction "-40"
        "dgt-CABINACINEMOMETRO_120452",  # EI-600 pair 123 m apart (pacing, combined sentence)
        "osm-13375593333",  # OSM fixed, direction "both"
        "salamanca-tramo-2",  # 13-vertex line
    ]
    wanted = set(targets) | {
        "dgt-CVM_161274-from",
        "dgt-CVM_161274-to",
        "dgt-CABINACINEMOMETRO_120647",
        "leon-2026-10-06-avenida-de-europa-0",  # expired and inactive: proves the active rule
        "leon-2026-10-06-avenida-de-europa-1",
        "leon-2026-10-04-avenida-de-fernandez-ladreda-0",  # 51 m from the Europa pair, expired
        "salamanca-tramo-4",
    }
    # Every negative OSM bearing.
    wanted |= {f["id"] for f in features if is_numeric(props(f).get("direction")) and props(f)["direction"].startswith("-")}
    # The three OSM "both" points.
    wanted |= {f["id"] for f in features if props(f).get("source") == "osm" and props(f).get("direction") == "both"}
    # Unpaired sections (sct, euskadi): the ones that stay points.
    line_ends = set()
    for f in features:
        if f["geometry"]["type"] == "LineString":
            line_ends.add(tuple(f["geometry"]["coordinates"][0]))
            line_ends.add(tuple(f["geometry"]["coordinates"][-1]))
    unpaired = [f["id"] for f in features if props(f)["kind"] == "section" and tuple(f["geometry"]["coordinates"]) not in line_ends]
    wanted |= set(sorted(unpaired)[:4])
    wanted |= {i for i in unpaired if i.startswith("euskadi")}

    def near_target(f):
        for t in targets:
            for a in gates(byid[t]):
                for b in gates(f):
                    if hav(a, b) < 3000:
                        return True
        return False

    def spread(ids, n):
        ids = sorted(ids)
        if n >= len(ids):
            return ids
        step = len(ids) / n
        return [ids[int(i * step)] for i in range(n)]

    def pick(pred, n):
        return spread([f["id"] for f in features if pred(props(f), f) and not near_target(f) and f["id"] not in wanted], n)

    chosen = set(wanted)
    # DGT stretches with both twins (consecutive DGT stretches share endpoints, so twins may belong to a neighbour).
    dgt_stretches = [f["id"] for f in features if props(f)["kind"] == "stretch" and props(f)["source"] == "dgt" and f["id"] + "-from" in byid and f["id"] + "-to" in byid and not near_target(f)]
    for sid in spread(dgt_stretches, 12):
        chosen |= {sid, sid + "-from", sid + "-to"}
    osm_stretches = [f["id"] for f in features if props(f)["kind"] == "stretch" and props(f)["source"] == "osm" and f["id"] + "-from" in byid and not near_target(f)]
    for sid in spread(osm_stretches, 10):
        chosen |= {sid, sid + "-from"}
        if sid + "-to" in byid:
            chosen.add(sid + "-to")
    chosen |= set(pick(lambda p, f: p["kind"] == "stretch" and p["source"] == "dgt_invive", 30))
    chosen |= set(pick(lambda p, f: p["kind"] == "stretch" and p["source"] in ("madrid", "salamanca"), 4))
    chosen |= set(pick(lambda p, f: p["kind"] == "fixed" and p["source"] == "dgt" and p["direction"] is not None, 20))
    chosen |= set(pick(lambda p, f: p["kind"] == "fixed" and p["source"] == "dgt" and p["direction"] is None, 10))
    chosen |= set(pick(lambda p, f: p["kind"] == "fixed" and p["source"] == "osm" and is_numeric(p["direction"]), 30))
    chosen |= set(pick(lambda p, f: p["kind"] == "fixed" and p["source"] == "osm" and p["direction"] in ("forward", "backward"), 2))
    chosen |= set(pick(lambda p, f: p["kind"] == "fixed" and p["source"] == "osm" and p["direction"] is None, 18))
    chosen |= set(pick(lambda p, f: p["kind"] == "fixed" and p["source"] in ("euskadi", "madrid", "navarra", "donostia", "sct"), 15))
    chosen |= set(pick(lambda p, f: p["kind"] == "mobile_announced" and p["source"] == "leon" and p["active"], 10))
    chosen |= set(pick(lambda p, f: p["kind"] == "mobile_announced" and p["source"] == "leon" and not p["active"], 4))
    chosen |= set(pick(lambda p, f: p["kind"] == "mobile_announced" and p["source"] == "murcia", 6))
    chosen |= set(pick(lambda p, f: p["kind"] == "trailer", 5))
    chosen |= set(pick(lambda p, f: p["kind"] == "reported", 5))
    # Two features of a kind the app does not know, to prove unknown kinds are ignored, not fatal.
    chosen |= set(pick(lambda p, f: p["kind"] not in ("fixed", "section", "stretch", "mobile_announced", "trailer", "reported"), 2))

    picked = sorted((byid[i] for i in chosen), key=lambda f: f["id"])
    json.dump({"type": "FeatureCollection", "features": picked}, open(out, "w"), ensure_ascii=False, indent=1)
    print(len(picked), "features ->", out)
    print(Counter(props(f)["kind"] for f in picked))
    print(Counter(props(f)["source"] for f in picked))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    import os

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    main(sys.argv[1], os.path.join(root, "Tests", "RadaresCoreTests", "Fixtures", "feed-sample.geojson"))
