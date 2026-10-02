import json
from dataclasses import replace
from pathlib import Path

import pytest

from radares_anunciados import net, osm_limits, speed
from radares_anunciados.model import REPORTED, Radar

FIX = Path(__file__).parent / "fixtures"
PAYLOAD = (FIX / "overpass_limits.json").read_bytes()
WAYS = osm_limits._ways(PAYLOAD)
NOW = 1_790_000_000.0
DAY = 86_400
REAL_ASK = osm_limits._ask  # conftest swaps it for an offline one in every test


def dgt(id_, name, lat, lon, kind="fixed"):
    credit = "Dirección General de Tráfico (CC BY 4.0)"
    return Radar(f"dgt-{id_}", "dgt", kind, name, lat, lon, 500, attribution=credit)


# Real DGT radars (feed of 2026-10-01) and what OpenStreetMap says of their road.
CASES = [
    # their road, two carriageways: the nearest one
    (dgt("120620", "Radar fijo A-30 km 112.9", 38.176327, -1.3138161), 120),
    # the nearest carriageway is 80, the other one 16 m off is 100
    (dgt("165621", "Radar fijo M-40 km 20.3", 40.365585, -3.6622005), 80),
    # a slip road under the radar (0.8 m) loses to the A-45 carriageway 6 m off
    (dgt("161609-to", "Radar de tramo A-45 km 134.2", 36.77529, -4.425749, "section"), 80),
    # 90 one way and 70 the other: no single limit
    (
        dgt(
            "165410-from",
            "Radar de tramo CL-615 km 24.8 (sentido PALENCIA)",
            42.2377,
            -4.6072,
            "section",
        ),
        None,
    ),
    # no drivable way within 30 m
    (dgt("120010", "Radar fijo N-330 km 668.7 (sentido FRANCIA)", 42.757904, -0.5259808), None),
    # the only way near is the EX-109, 5.5 m off: another road's limit is not borrowed
    (dgt("120249", "Radar fijo EX-108 km 90.8", 39.999466, -6.5491147), None),
    # DGT writes N-1, OpenStreetMap N-I
    (dgt("120411", "Radar fijo N-1 km 271.7 (sentido SAN SEBASTIÁN)", 42.4913, -3.3667), 90),
    # the old road through the town, A-431a in OpenStreetMap
    (dgt("120039", "Radar fijo A-431 km 29.7", 37.80637, -5.09753), 30),
    # A-30 and A-7 share this carriageway and OpenStreetMap tags it A-7: on it, 1 m
    (dgt("120622", "Radar fijo A-30 km 136.0", 38.023544, -1.1647367), 80),
    # the way under it has no limit; the 60 of a way 14 m off is not borrowed
    (dgt("120348", "Radar fijo N-357 km 5.5", 36.1264, -5.4423), None),
    # where two pieces of the N-4 meet: the piece 1.3 m farther has the limit
    (dgt("120035", "Radar fijo N-4 km 618.8", 36.83327, -6.066566), 80),
    # the A-45 one above as a mapped camera with no road in its name: the slip
    # road under it still loses to the main carriageway
    (dgt("161609-noroad", "Radar", 36.77529, -4.425749), 80),
]


@pytest.mark.parametrize(("radar", "kmh"), CASES, ids=[r.name for r, _ in CASES])
def test_the_limit_of_the_road_the_radar_is_on(radar, kmh):
    assert osm_limits.choose((radar.lat, radar.lon), osm_limits.road_of(radar), WAYS) == kmh


# Real DGT radars (feed of 2026-10-01) with no way of their road within 30 m;
# Overpass answer of 2026-10-01.
OFFROAD = osm_limits._ways((FIX / "overpass_limits_offroad.json").read_bytes())


@pytest.mark.parametrize(
    "radar",
    [
        # an unclassified roundabout (40, 21 m) and a trunk_link (60, 22 m) near
        # a national road: neither is the N-320
        dgt("n320", "Radar fijo N-320 km 300.5", 40.634655, -3.312912),
        # a trunk_link with no ref (40, 7 m) beside a motorway radar, CV-31 at 17 m
        dgt("v21", "Radar fijo V-21 km 13.6", 39.514683, -0.4326693),
    ],
    ids=lambda r: r.name,
)
def test_a_slip_road_or_side_street_is_not_the_radars_road(radar):
    assert osm_limits.choose((radar.lat, radar.lon), osm_limits.road_of(radar), OFFROAD) is None


def test_a_carriageway_under_the_radar_may_be_its_road_untagged():
    p = (40.0, -3.0)
    line = [(39.999, -3.00001), (40.001, -3.00001)]  # ~1 m east of the radar
    assert osm_limits.choose(p, "A1", [({"highway": "motorway", "maxspeed": "120"}, line)]) == 120
    for highway in ("motorway_link", "trunk_link", "unclassified", "residential", "service"):
        assert osm_limits.choose(p, "A1", [({"highway": highway, "maxspeed": "40"}, line)]) is None
    far = [(39.999, -3.0001), (40.001, -3.0001)]  # ~8.5 m off: beside the road, not on it
    assert osm_limits.choose(p, "A1", [({"highway": "motorway", "maxspeed": "120"}, far)]) is None


@pytest.mark.parametrize(
    ("value", "kmh"),
    [
        ("90", 90),
        ("90 km/h", 90),
        ("50 mph", 80),
        ("ES:motorway", 120),
        ("ES:rural", 90),
        ("ES:zone30", 30),
        ("ES:urban", None),  # 20, 30 or 50 by the lanes since 2021
        ("none", None),
        ("walk", None),
        ("signals", None),
        ("80;90", None),
        ("50|30", None),
        ("0", None),
        ("", None),
        (None, None),
    ],
)
def test_maxspeed_values(value, kmh):
    assert osm_limits.kmh(value) == kmh


@pytest.mark.parametrize(
    ("tags", "kmh"),
    [
        ({"maxspeed": "80", "maxspeed:forward": "100"}, 80),
        ({"maxspeed:forward": "90", "maxspeed:backward": "90"}, 90),
        ({"maxspeed:forward": "90", "maxspeed:backward": "70"}, None),
        ({"maxspeed:forward": "100"}, None),  # two-way road: which way is the radar's?
        ({"maxspeed:forward": "100", "oneway": "yes"}, 100),
        ({"maxspeed:forward": "100", "highway": "motorway"}, 100),
    ],
)
def test_direction_limits(tags, kmh):
    assert osm_limits.way_kmh(tags) == kmh


@pytest.mark.parametrize(
    ("name", "road"),
    [
        ("Radar fijo A-7 km 580.3 (sentido ALMERIA)", "A7"),
        ("Radar fijo N-II km 341.1 (sentido BARCELONA)", "N2"),
        ("Radar fijo N-121-A km 32.6 (sentido FRANCIA)", "N121"),
        ("Radar de tramo CG-1.5 km 16.1", "CG1.5"),
        ("Radar fijo Ma-13 km 4.0", "MA13"),
        ("Radar", None),
    ],
)
def test_the_road_in_a_radar_name(name, road):
    assert osm_limits.road_of(dgt("x", name, 0, 0)) == road


def test_one_query_asks_for_every_point():
    q = osm_limits.query([(38.1, -1.3), (40.36559, -3.6622005)])
    assert q.count("(around:30,") == 2
    assert "38.100000,-1.300000" in q and "40.365590,-3.662200" in q
    assert '"^(motorway|trunk|' in q and "service" in q and q.endswith("out tags geom;")


@pytest.fixture
def cache(monkeypatch, tmp_path):
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))
    return tmp_path


def asked_by(monkeypatch, answer=PAYLOAD):
    calls = []

    def ask(points):
        calls.append(points)
        if isinstance(answer, Exception):
            raise answer
        return answer

    monkeypatch.setattr(osm_limits, "_ask", ask)
    return calls


def test_fill_batches_and_keeps_what_has_a_limit(monkeypatch, cache):
    monkeypatch.setattr(osm_limits, "BATCH", 4)
    calls = asked_by(monkeypatch)
    radars = [r for r, _ in CASES]
    street = Radar("m-1", "murcia", "mobile_announced", "Radar anunciado Calle Mayor", 38, -1, 478)
    published = replace(radars[0], id="osm-1", source="osm", maxspeed=100)
    filled = osm_limits.fill([*radars, street, published], now=NOW)
    assert [len(c) for c in calls] == [4, 4, 4]  # 12 radars, 3 queries, never one each
    assert [r.maxspeed for r in filled[: len(CASES)]] == [kmh for _, kmh in CASES]
    assert filled[0].attribution == f"{radars[0].attribution}; {osm_limits.ATTRIBUTION}"
    assert filled[4].attribution == radars[4].attribution  # no limit found, no OSM data
    assert filled[-2] == street  # a street's circles keep theirs
    assert filled[-1].maxspeed == 100  # a published limit is never replaced


def test_answers_are_kept_30_days(monkeypatch, cache):
    radars = [r for r, _ in CASES]
    calls = asked_by(monkeypatch)
    osm_limits.fill(radars, now=NOW)
    assert len(calls) == 1
    # the next runs ask nothing, for a radar with a limit or without one
    again = osm_limits.fill(radars, now=NOW + 29 * DAY)
    assert len(calls) == 1 and [r.maxspeed for r in again] == [kmh for _, kmh in CASES]
    # a new radar alone is asked for
    moved = replace(radars[0], id="dgt-new", lat=radars[0].lat + 0.00001)
    osm_limits.fill([*radars, moved], now=NOW + DAY)
    assert calls[-1] == [(moved.lat, moved.lon)]
    osm_limits.fill(radars, now=NOW + 31 * DAY)
    assert len(calls) == 3 and len(calls[-1]) == len(radars)


def test_a_failed_query_leaves_the_limit_unknown_and_asks_again(monkeypatch, cache):
    radars = [r for r, _ in CASES]
    calls = asked_by(monkeypatch, OSError("504"))
    monkeypatch.setattr(osm_limits, "BATCH", 4)
    filled = osm_limits.fill(radars, now=NOW)
    assert [r.maxspeed for r in filled] == [None] * len(radars)
    assert len(calls) == 1  # Overpass is down: the other batches wait for the next run
    calls = asked_by(monkeypatch)
    assert osm_limits.fill(radars, now=NOW + 60)[0].maxspeed == 120
    assert len(calls) == 3


def test_an_old_answer_outlives_a_failed_refresh(monkeypatch, cache):
    # A limit names and sizes the zone: losing it to a failed query would delete
    # and recreate every zone, and again when Overpass came back.
    radars = [r for r, _ in CASES]
    expected = [kmh for _, kmh in CASES]
    monkeypatch.setattr(osm_limits, "BATCH", 4)
    asked_by(monkeypatch)
    osm_limits.fill(radars, now=NOW)
    calls = asked_by(monkeypatch, OSError("504"))
    later = NOW + 31 * DAY
    assert [r.maxspeed for r in osm_limits.fill(radars, now=later)] == expected
    assert len(calls) == 1  # it was asked again, and failed
    # the first batch refreshed, the second failed: both keep a limit
    answers = iter([PAYLOAD, OSError("504")])

    def half(points):
        calls.append(points)
        answer = next(answers)
        if isinstance(answer, Exception):
            raise answer
        return answer

    monkeypatch.setattr(osm_limits, "_ask", half)
    assert [r.maxspeed for r in osm_limits.fill(radars, now=later + 60)] == expected
    assert len(calls) == 3
    calls = asked_by(monkeypatch)
    assert [r.maxspeed for r in osm_limits.fill(radars, now=later + 120)] == expected
    assert [len(c) for c in calls] == [4, 4]  # only the 8 still old are asked
    osm_limits.fill(radars, now=later + 180)
    assert len(calls) == 2  # all fresh again


def test_an_old_answer_of_a_radar_gone_is_dropped(monkeypatch, cache):
    asked_by(monkeypatch)
    gone, kept = CASES[0][0], CASES[1][0]
    osm_limits.fill([gone, kept], now=NOW)
    osm_limits.fill([kept], now=NOW + 31 * DAY)
    saved = json.loads((cache / osm_limits.CACHE_FILE).read_text())["limits"]
    assert list(saved) == [osm_limits._key(kept)]


def test_an_overpass_remark_is_a_failed_query(monkeypatch, cache):
    # Overpass answers a timeout or running out of memory with HTTP 200, the
    # elements it had (here none) and a remark (real answer of 2026-10-01).
    remark = (FIX / "overpass_limits_remark.json").read_bytes()
    with pytest.raises(ValueError, match="ran out of memory"):
        osm_limits._ways(remark)
    with pytest.raises(ValueError, match="no elements"):
        osm_limits._ways(b"{}")
    radar = CASES[1][0]
    calls = asked_by(monkeypatch, remark)
    assert osm_limits.fill([radar], now=NOW)[0].maxspeed is None
    calls = asked_by(monkeypatch)
    assert osm_limits.fill([radar], now=NOW + 60)[0].maxspeed == 80
    assert len(calls) == 1  # the remark cached nothing


@pytest.mark.parametrize(
    "limits",
    [{"k": None}, {"k": [80]}, {"k": "80"}, {"k": [True, NOW]}, {"k": [80, "x"]}, [], None],
)
def test_a_malformed_cache_entry_is_asked_again(monkeypatch, cache, limits):
    radar = CASES[0][0]
    if isinstance(limits, dict):
        limits = {osm_limits._key(radar): limits["k"]}
    (cache / osm_limits.CACHE_FILE).write_text(json.dumps({"version": 1, "limits": limits}))
    calls = asked_by(monkeypatch)
    assert osm_limits.fill([radar], now=NOW)[0].maxspeed == 120
    assert len(calls) == 1


def test_one_try_for_the_optional_lookup(monkeypatch):
    seen = {}

    def get(url, **kwargs):
        seen.update(kwargs)
        return b"{}"

    monkeypatch.setattr(net, "get", get)
    REAL_ASK([(38.0, -1.0)])
    assert seen["tries"] == 1 and seen["timeout"] <= 200


def test_an_unreadable_cache_is_asked_again(monkeypatch, cache):
    (cache / osm_limits.CACHE_FILE).write_text("{not json")
    calls = asked_by(monkeypatch)
    assert osm_limits.fill([CASES[0][0]], now=NOW)[0].maxspeed == 120
    assert len(calls) == 1
    saved = json.loads((cache / osm_limits.CACHE_FILE).read_text())
    assert saved["version"] == osm_limits.VERSION and len(saved["limits"]) == 1


def test_the_lookup_runs_before_zones_are_sized(monkeypatch, cache):
    assert osm_limits.fill in speed.LOOKUPS
    asked_by(monkeypatch)
    radar = CASES[1][0]  # M-40, 80 in OpenStreetMap; the fallback would size it for 90
    sized = speed.size(speed.fill_limits([radar]), speed.Radius())
    assert sized[0].maxspeed == 80 and sized[0].radius_m == speed.auto_radius(80, 40)


def test_a_report_is_neither_looked_up_nor_sized(monkeypatch, cache):
    calls = asked_by(monkeypatch)
    note = Radar("osm-note-1", "osm_notes", REPORTED, "radar fijo", 38.0, -1.0, 0)
    assert speed.size(speed.fill_limits([note]), speed.Radius()) == [note]
    assert calls == []  # a report gets no zone: nothing to size, nothing to ask Overpass


def test_no_test_reaches_overpass():
    with pytest.raises(OSError, match="never touch the network"):
        osm_limits._ask([(38.0, -1.0)])
