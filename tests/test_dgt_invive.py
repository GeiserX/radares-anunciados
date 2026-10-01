import json
import logging
import os
from dataclasses import replace
from datetime import date
from pathlib import Path

import pytest

from radares_anunciados import feed, net, speed
from radares_anunciados.geo import densify, distance_m
from radares_anunciados.sources import Context, dgt_invive
from radares_anunciados.speed import Radius

FIX = Path(__file__).parent / "fixtures"
XML = (FIX / "dgt_tramos_invive.xml").read_bytes()
# The Overpass answer for Murcia's INVIVE roads, trimmed to RM-D11, RM-F36 and
# five N-332 ways far from the N-332 stretch (as in the full answer).
OVERPASS = (FIX / "overpass_invive_murcia.json").read_bytes()
MURCIA = frozenset({"30"})

# Every province name in the full file of 2026-10-01 (43 provinces, 1,331 stretches).
FILE_PROVINCES = [
    "A CORUÑA", "ALACANT/ALICANTE", "ALBACETE", "ALMERÍA", "ASTURIAS", "BADAJOZ", "BURGOS",
    "CANTABRIA", "CASTELLÓ/CASTELLÓN", "CIUDAD REAL", "CUENCA", "CÁCERES", "CÁDIZ", "CÓRDOBA",
    "GRANADA", "GUADALAJARA", "HUELVA", "HUESCA", "ILLES BALEARS", "JAÉN", "LA RIOJA",
    "LAS PALMAS", "LEÓN", "LUGO", "MADRID", "MURCIA", "MÁLAGA", "NAVARRA", "OURENSE", "PALENCIA",
    "PONTEVEDRA", "SALAMANCA", "SANTA CRUZ DE TENERIFE", "SEGOVIA", "SEVILLA", "SORIA", "TERUEL",
    "TOLEDO", "VALLADOLID", "VALÈNCIA/VALENCIA", "ZAMORA", "ZARAGOZA", "ÁVILA",
]  # fmt: skip


@pytest.fixture(autouse=True)
def clean_env(monkeypatch, tmp_path):
    for name in list(os.environ):
        if name.startswith("RADARES_"):
            monkeypatch.delenv(name)
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))


def ctx(provinces=MURCIA) -> Context:
    return Context(day=date(2026, 10, 1), provinces=provinces, boxes=(), radius=Radius())


def by_road(stretches, road, km_from):
    return next(s for s in stretches if s.road == road and s.km_from == km_from)


def test_parses_the_file_with_its_malformed_xmlns():
    assert b'xmlns:xsd="http:www.w3.org/2001/XMLSchema"' in XML  # kept as served
    stretches = dgt_invive.parse(XML)
    assert len(stretches) == 6
    first = next(s for s in stretches if s.id == "dgt_invive-Tramo_Invive_1")
    assert first.name == "Tramo de radar móvil CM-220 km 17.3-34.8"
    assert (first.road, first.province, first.km_from, first.km_to) == ("CM-220", "02", 17.3, 34.8)
    assert first.start == (39.25851, -1.91995) and first.end == (39.11986, -1.99897)
    assert first.direction == "both"
    assert first.maxspeed is None  # the file publishes no limit
    assert first.url == dgt_invive.URL
    assert first.attribution == dgt_invive.ATTRIBUTION
    assert first.line is None


def test_keeps_only_the_selected_provinces():
    assert {s.province for s in dgt_invive.parse(XML, MURCIA)} == {"30"}
    assert len(dgt_invive.parse(XML, MURCIA)) == 4
    assert [s.province for s in dgt_invive.parse(XML, {"28"})] == ["28"]
    assert dgt_invive.parse(XML, {"08"}) == []


def test_every_province_name_in_the_file_has_its_ine_code():
    codes = [dgt_invive.province_code(n) for n in FILE_PROVINCES]
    assert None not in codes
    assert len(set(codes)) == 43
    assert set(codes) <= dgt_invive.COVERED
    assert dgt_invive.province_code("MURCIA") == "30"
    assert dgt_invive.province_code("VALÈNCIA/VALENCIA") == "46"
    assert dgt_invive.province_code("ALACANT/ALICANTE") == "03"
    assert dgt_invive.province_code("ATLANTIS") is None


def test_a_stretch_in_an_unknown_province_is_skipped_not_guessed(caplog):
    xml = XML.replace(b">ALBACETE<", b">ATLANTIS<")
    with caplog.at_level(logging.WARNING):
        stretches = dgt_invive.parse(xml)
    assert len(stretches) == 5
    assert "Tramo_Invive_1" not in {s.id.removeprefix("dgt_invive-") for s in stretches}
    assert "ATLANTIS" in caplog.text


def test_geometry_query_is_one_ref_alternation_in_the_province_box():
    query = dgt_invive.geometry_query((37.37, -2.35, 38.76, -0.64), ["RM-D11", "N-301a", "x;out;"])
    assert "[bbox:37.37,-2.35,38.76,-0.64]" in query
    assert '"ref"~"^(N-301a|RM-D11)(;|$)|;(N-301a|RM-D11)(;|$)",i' in query
    assert "x;out" not in query  # only road refs reach Overpass
    assert "name" not in query and "area" not in query
    assert query.endswith("out geom qt;")


def test_follows_the_road_between_the_end_points():
    stretches = dgt_invive.follow(dgt_invive.parse(XML, MURCIA), OVERPASS)
    d11 = by_road(stretches, "RM-D11", 0.0)
    assert d11.line is not None
    assert d11.line[0] == d11.start and d11.line[-1] == d11.end
    # the path along OpenStreetMap matches the published km range within 5 %
    length = dgt_invive._length(list(d11.line))
    assert abs(length - 10_390) < 0.05 * 10_390
    assert "OpenStreetMap" in d11.attribution
    assert not d11.name.endswith(dgt_invive.STRAIGHT_NOTE)
    # RM-F36 km 0: the published start is about 1 km off the mapped road; still followed
    assert by_road(stretches, "RM-F36", 0.0).line is not None
    assert by_road(stretches, "RM-F36", 5.82).line is not None


def test_a_road_not_found_stays_a_straight_line_and_says_so():
    stretches = dgt_invive.follow(dgt_invive.parse(XML, MURCIA), OVERPASS)
    n332 = by_road(stretches, "N-332", 0.0)  # the mapped N-332 is km away from these points
    assert n332.line is None
    assert n332.name == "Tramo de radar móvil N-332 km 0-13.07" + dgt_invive.STRAIGHT_NOTE
    assert "OpenStreetMap" not in n332.attribution
    feature = json.loads(feed.to_geojson([], [n332]))["features"][0]
    assert feature["geometry"]["coordinates"] == [
        [n332.start[1], n332.start[0]],
        [n332.end[1], n332.end[0]],
    ]
    assert "línea recta" in feature["properties"]["name"]


def test_without_bridges_a_ref_broken_at_a_roundabout_is_not_followed(monkeypatch):
    # RM-D11's ref stops at a roundabout; only the bridge between way ends joins it.
    monkeypatch.setattr(dgt_invive, "BRIDGE_M", 0)
    stretches = dgt_invive.follow(dgt_invive.parse(XML, MURCIA), OVERPASS)
    assert by_road(stretches, "RM-D11", 0.0).line is None


def test_a_path_far_longer_than_the_published_km_is_refused():
    d11 = by_road(dgt_invive.parse(XML, MURCIA), "RM-D11", 0.0)
    line = dgt_invive.route(dgt_invive.road_ways(OVERPASS, "RM-D11"), d11.start, d11.end)
    assert dgt_invive.plausible(line, d11)
    assert not dgt_invive.plausible(line, replace(d11, km_to=2.0))


def test_along_puts_points_at_both_ends_and_never_further_apart_than_asked():
    line = [(37.96, -1.09), (37.97, -1.10), (37.99, -1.10)]
    points = dgt_invive.along(line, 1000)
    assert points[0] == line[0]
    assert distance_m(points[-1], line[-1]) < 1
    gaps = [distance_m(a, b) for a, b in zip(points, points[1:], strict=False)]
    assert max(gaps) <= 1000 + 1
    assert dgt_invive.along([(37.0, -1.0), (37.0, -1.0)], 1000) == [(37.0, -1.0)]


def test_zones_cover_the_whole_road_with_the_speed_rule_radius():
    d11 = by_road(dgt_invive.follow(dgt_invive.parse(XML, MURCIA), OVERPASS), "RM-D11", 0.0)
    radars = dgt_invive.zones(d11, ctx())
    radius = speed.auto_radius(speed.ROAD_KMH, speed.POINT_LEAD_S)  # no published limit: 90
    assert {r.radius_m for r in radars} == {radius}
    assert {r.name for r in radars} == {"Radar móvil RM-D11 km 0-10.39"}
    assert {r.kind for r in radars} == {"mobile_stretch"}
    assert len({r.id for r in radars}) == len(radars)
    assert (radars[0].lat, radars[0].lon) == d11.start
    assert all(r.province == "30" and r.direction == "both" and r.url for r in radars)
    for point in densify(list(d11.line), 50):
        assert min(distance_m(point, (r.lat, r.lon)) for r in radars) <= 0.9 * radius + 1
    # the core resizes point radars by the same rule, so the spacing still holds
    assert speed.size(radars, Radius()) == radars


def test_zones_are_off_by_default():
    result = dgt_invive.build(XML, ctx(), with_zones=False, max_age_s=1)
    assert result.radars == [] and len(result.stretches) == 4


def test_zones_need_a_province_list(caplog):
    with caplog.at_level(logging.WARNING):
        result = dgt_invive.build(XML, ctx(provinces=None), with_zones=True, max_age_s=1)
    assert result.radars == [] and len(result.stretches) == 6
    assert "province list" in caplog.text


def test_fetch_with_zones_on(monkeypatch):
    calls = []

    def cached_get(url, data=None, headers=None, max_age_s=0):
        calls.append((url, data, max_age_s))
        return XML if url == dgt_invive.URL else OVERPASS

    monkeypatch.setattr(net, "cached_get", cached_get)
    monkeypatch.setenv("RADARES_STRETCH_ZONES", "on")
    result = dgt_invive.fetch(ctx(frozenset({"30", "28"})))
    assert {r.province for r in result.radars} == {"30", "28"}
    assert all(r.name.startswith("Radar") for r in result.radars)
    overpass = [c for c in calls if c[0] != dgt_invive.URL]
    assert len(overpass) == 2  # one query per selected province
    assert {c[2] for c in overpass} == {dgt_invive.GEOMETRY_MAX_AGE_S}
    assert "[bbox:37.37,-2.35,38.76,-0.64]" in overpass[1][1]["data"]


def test_overpass_down_gives_straight_lines_and_still_zones(monkeypatch):
    def cached_get(url, data=None, headers=None, max_age_s=0):
        if url == dgt_invive.URL:
            return XML
        raise OSError("504")

    monkeypatch.setattr(net, "cached_get", cached_get)
    monkeypatch.setenv("RADARES_STRETCH_ZONES", "on")
    result = dgt_invive.fetch(ctx())
    assert all(
        s.line is None and s.name.endswith(dgt_invive.STRAIGHT_NOTE) for s in result.stretches
    )
    assert result.radars


def test_a_wrong_zones_setting_is_refused(monkeypatch):
    monkeypatch.setenv("RADARES_STRETCH_ZONES", "yes please")
    with pytest.raises(ValueError, match="RADARES_STRETCH_ZONES"):
        dgt_invive.zones_wanted()
    monkeypatch.setenv("RADARES_STRETCH_ZONES", "ON")
    assert dgt_invive.zones_wanted()
