import logging
from datetime import date
from pathlib import Path

import pytest

from radares_anunciados import feed, net
from radares_anunciados.model import Radar
from radares_anunciados.sources import Context, sct
from radares_anunciados.sources.catalonia_shapes import province
from radares_anunciados.speed import Radius

FIX = Path(__file__).parent / "fixtures"
# Real rows of both files, trimmed: tests/fixtures/sct_radars.txt keeps four
# broken rows the publisher ships (a missing decimal comma, two northings).
FIXED = (FIX / "sct_radars.txt").read_text()
TRAILER = (FIX / "sct_radars-remolc.txt").read_text()


# The real HEAD answer for radars.txt on 2026-10-01.
HEAD = dict(
    line.split(": ", 1)
    for line in (FIX / "sct_radars_head.txt").read_text().splitlines()
    if ": " in line
)


@pytest.fixture(autouse=True)
def offline_head(monkeypatch):
    def head(url):
        raise OSError("tests never touch the network")

    monkeypatch.setattr(sct, "head", head)


def by_id(radars: list[Radar]) -> dict[str, Radar]:
    return {r.id: r for r in radars}


def test_fixed_rows_become_radars_and_broken_rows_are_skipped():
    radars = by_id(sct.parse_fixed(FIXED))
    # 14 rows: B-10 x2 and C-17 lack the decimal comma, A-2 501,5 has an easting
    # of 3.4 million. None is repaired.
    assert sorted(radars) == [
        "sct-A-2-445.35",
        "sct-C-14-4.35",
        "sct-C-32nord-85",
        "sct-C-32sud-48.085",
        "sct-C-58cc-1.8-3.0",
        "sct-C-58cc-3.0-1.8",
        "sct-GI-552-13.345",
        "sct-N-230-150.5-156",
        "sct-N-230-156-150.5",
        "sct-TV-3141-5.224",
    ]
    a2 = radars["sct-A-2-445.35"]
    assert (a2.source, a2.kind, a2.name) == ("sct", "fixed", "Radar fijo A-2 km 445.35")
    assert (a2.maxspeed, a2.province, a2.direction) == (120, "25", None)
    assert a2.url == sct.FIXED_URL
    assert a2.attribution == sct.ATTRIBUTION
    assert all(r.name.startswith("Radar") for r in radars.values())


@pytest.mark.parametrize(
    ("radar_id", "lat", "lon"),
    [
        # pyproj, EPSG:25831 -> EPSG:4326, for the same X/Y
        ("sct-A-2-445.35", 41.5382285, 0.4594567),
        ("sct-C-32nord-85", 41.4833541, 2.2950070),
        ("sct-C-58cc-1.8-3.0", 41.4662952, 2.1739190),
        ("sct-GI-552-13.345", 41.7990867, 2.5435991),
        ("sct-N-230-150.5-156", 42.6726251, 0.7773750),
        ("sct-TV-3141-5.224", 41.1240821, 1.0963278),
    ],
)
def test_utm_31n_lands_where_pyproj_puts_it(radar_id, lat, lon):
    radar = by_id(sct.parse_fixed(FIXED))[radar_id]
    assert radar.lat == pytest.approx(lat, abs=1e-6)
    assert radar.lon == pytest.approx(lon, abs=1e-6)


def test_a_pk_range_is_a_section_and_a_named_half_keeps_its_name():
    radars = by_id(sct.parse_fixed(FIXED))
    section = radars["sct-C-58cc-1.8-3.0"]
    assert (section.kind, section.name, section.maxspeed) == (
        "section",
        "Radar de tramo C-58cc km 1.8-3.0",
        90,
    )
    assert radars["sct-C-32nord-85"].name == "Radar fijo C-32 nord km 85"
    assert radars["sct-C-32sud-48.085"].name == "Radar fijo C-32 sud km 48.085"


def test_every_province_comes_from_the_point():
    provinces = {r.id: r.province for r in sct.parse_fixed(FIXED)}
    assert provinces["sct-C-32nord-85"] == "08"  # Barcelona
    assert provinces["sct-GI-552-13.345"] == "17"  # Girona
    assert provinces["sct-N-230-150.5-156"] == "25"  # Lleida
    assert provinces["sct-TV-3141-5.224"] == "43"  # Tarragona


def test_trailer_spots_keep_both_rows_at_one_pk():
    radars = sct.parse_trailer(TRAILER)
    assert len(radars) == 8
    ids = [r.id for r in radars]
    assert ids[2:6] == [
        "sct_remolc-AP-7-129.5",
        "sct_remolc-AP-7-129.5-2",
        "sct_remolc-AP-7-160.6",
        "sct_remolc-AP-7-160.6-2",
    ]
    first = radars[0]
    assert (first.source, first.kind, first.name) == (
        "sct_remolc",
        "trailer",
        "Radar en remolque A-2 km 501.25",
    )
    assert (first.maxspeed, first.province, first.url) == (120, "25", sct.TRAILER_URL)
    assert [r.maxspeed for r in radars[4:6]] == [80, 100]


def test_province_of_points_in_and_out_of_catalonia():
    assert province(41.3874, 2.1686) == "08"  # Barcelona
    assert province(41.9794, 2.8214) == "17"  # Girona
    assert province(41.6176, 0.6200) == "25"  # Lleida
    assert province(41.1189, 1.2445) == "43"  # Tarragona
    assert province(42.4636, 1.9808) == "17"  # Llívia, an exclave in France
    assert province(41.6488, -0.8891) is None  # Zaragoza
    assert province(42.6887, 2.8948) is None  # Perpignan
    assert province(39.4699, -0.3763) is None  # Valencia
    assert province(41.2830, 2.1300) == "08"  # 1.3 km off the simplified coast at El Prat
    assert province(41.2500, 2.2500) is None  # 9.5 km out to sea


def test_a_row_inside_the_utm_box_but_outside_catalonia_is_skipped(monkeypatch):
    # a fifth unusable row of 14 crosses MAX_SKIPPED, which is not under test here
    monkeypatch.setattr(sct, "MAX_SKIPPED", 1.0)
    # The TV-3141 row moved to Fraga, in Aragon: plausible numbers, wrong place.
    moved = FIXED.replace("340194,8559 4554277,8842", "279000,0000 4599500,0000")
    ids = {r.id for r in sct.parse_fixed(moved)}
    assert "sct-TV-3141-5.224" in {r.id for r in sct.parse_fixed(FIXED)}
    assert "sct-TV-3141-5.224" not in ids


def test_a_changed_format_raises_instead_of_emptying_the_source():
    with pytest.raises(ValueError, match="header"):
        sct.parse_fixed(FIXED.replace("Velocitat", "Limit"))
    with pytest.raises(ValueError, match="header"):
        sct.parse_trailer(TRAILER.replace("Velocitat", "Limit"))
    only_broken = "\n".join(FIXED.splitlines()[:3] + [FIXED.splitlines()[5]])
    with pytest.raises(ValueError, match="no usable row"):
        sct.parse_fixed(only_broken)


def test_fetch_keeps_only_the_selected_provinces(monkeypatch):
    payloads = {sct.FIXED_URL: FIXED.encode(), sct.TRAILER_URL: TRAILER.encode()}
    monkeypatch.setattr(net, "cached_get", lambda url, **kw: payloads[url])
    ctx = Context(day=date(2026, 10, 1), provinces=frozenset({"17"}), boxes=(), radius=Radius())
    fixed = sct.SOURCE.fetch(ctx).radars
    assert [r.id for r in fixed] == ["sct-GI-552-13.345"]
    assert [r.id for r in sct.TRAILER.fetch(ctx).radars] == ["sct_remolc-N-II-687.75"]
    every = Context(day=date(2026, 10, 1), provinces=None, boxes=(), radius=Radius())
    assert len(sct.SOURCE.fetch(every).radars) == 10
    assert sct.SOURCE.provinces == sct.TRAILER.provinces == {"08", "17", "25", "43"}


def _osm(lat: float, lon: float) -> Radar:
    return Radar(
        id="osm-1", source="osm", kind="fixed", name="Radar", lat=lat, lon=lon, radius_m=500
    )


def test_merge_drops_an_osm_copy_of_an_sct_radar():
    official = by_id(sct.parse_fixed(FIXED))["sct-GI-552-13.345"]
    copy = _osm(official.lat + 0.0009, official.lon)  # 100 m north
    merged = feed.merge([official, copy], date(2026, 10, 1))
    assert [r.id for r in merged] == [official.id]
    away = _osm(official.lat + 0.0027, official.lon)  # 300 m north: another camera
    assert len(feed.merge([official, away], date(2026, 10, 1))) == 2


def test_merge_keeps_an_osm_camera_on_an_announced_street():
    street = Radar(
        id="murcia-x-0",
        source="murcia",
        kind="mobile_announced",
        name="Radar Calle X",
        lat=37.98,
        lon=-1.13,
        radius_m=300,
    )
    camera = _osm(37.9805, -1.13)  # 55 m away: a fixed camera, not the police's van
    assert len(feed.merge([street, camera], date(2026, 10, 1))) == 2


def test_a_file_that_lost_a_large_share_of_its_rows_is_refused(caplog):
    # The fixture keeps 4 broken rows of 14 and passes, with the count logged. Two
    # more rows without their decimal comma (6 of 14) look like a bad export: the
    # source raises and the registry keeps the last good result.
    with caplog.at_level(logging.WARNING):
        assert len(sct.parse_fixed(FIXED)) == 10
    assert "4 of 14 rows skipped" in caplog.text
    worse = FIXED.replace("441144,0836", "4411440836 ").replace("416219,5211", "4162195211 ")
    assert worse != FIXED
    with pytest.raises(ValueError, match="6 of 14 rows"):
        sct.parse_fixed(worse)


def test_the_attribution_carries_the_date_of_the_files_last_update(monkeypatch):
    # The gencat reuse terms ask for the date of the last update.
    payloads = {sct.FIXED_URL: FIXED.encode(), sct.TRAILER_URL: TRAILER.encode()}
    monkeypatch.setattr(net, "cached_get", lambda url, **kw: payloads[url])
    every = Context(day=date(2026, 10, 1), provinces=None, boxes=(), radius=Radius())
    monkeypatch.setattr(sct, "head", lambda url: {k.lower(): v for k, v in HEAD.items()})
    radars = sct.SOURCE.fetch(every).radars
    assert {r.attribution for r in radars} == {sct.ATTRIBUTION + ", actualizado 2026-09-17"}
    # no date to be had: the radars still come, credited without it
    monkeypatch.setattr(sct, "head", lambda url: {})
    assert {r.attribution for r in sct.SOURCE.fetch(every).radars} == {sct.ATTRIBUTION}
