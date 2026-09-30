from datetime import date
from pathlib import Path

from radares_anunciados import feed
from radares_anunciados.geo import cover, distance_m
from radares_anunciados.sources import dgt, osm
from radares_anunciados.streets import street_key

FIX = Path(__file__).parent / "fixtures"


def test_dgt_keeps_only_requested_province():
    radars = dgt.parse((FIX / "dgt_radares.xml").read_bytes(), {"30"})
    # fixture: 2 Murcia sections (2 ends each) + 2 Murcia cabins; 1 section and
    # 1 cabin from Zaragoza that must be dropped
    assert [r.kind for r in radars].count("section") == 4
    assert [r.kind for r in radars].count("fixed") == 2
    assert all(37 < r.lat < 39 and -2 < r.lon < -0.5 for r in radars)
    assert dgt.parse((FIX / "dgt_radares.xml").read_bytes(), {"99"}) == []


def test_dgt_names_road_and_km():
    names = {r.name for r in dgt.parse((FIX / "dgt_radares.xml").read_bytes(), {"30"})}
    assert "Radar fijo A-30 km 190.5" in names
    assert all(n.startswith("Radar") for n in names)


def test_osm_names_from_note():
    radars = osm.parse((FIX / "osm_es_mc.json").read_bytes())
    assert len(radars) == 27
    assert any(r.name == "Radar A-7 km 758.79" for r in radars)
    assert all(r.name.startswith("Radar") for r in radars)


def test_merge_drops_osm_copies_of_dgt_radars():
    official = dgt.parse((FIX / "dgt_radares.xml").read_bytes(), {"30"})
    mapped = osm.parse((FIX / "osm_es_mc.json").read_bytes())
    merged = feed.merge(official + mapped, date(2026, 9, 30))
    # A-30 km 190.5 is in both; only the DGT copy survives
    near = [r for r in merged if distance_m((r.lat, r.lon), (37.62027, -0.9488051)) < 150]
    assert [r.source for r in near] == ["dgt"]
    assert len(merged) < len(official) + len(mapped)


def test_cover_reaches_every_point_of_the_line():
    line = [(37.96, -1.09), (37.97, -1.10)]  # ~1.4 km
    centres = cover([line], 300)
    for i in range(101):
        p = (37.96 + 0.0001 * i, -1.09 - 0.0001 * i)
        assert min(distance_m(p, c) for c in centres) <= 300


def test_cover_shares_circles_between_parallel_carriageways():
    a = [(37.96, -1.09), (37.97, -1.10)]
    b = [(37.96, -1.09005), (37.97, -1.10005)]  # 4 m apart
    assert len(cover([a, b], 300)) == len(cover([a], 300))


def test_street_key_ignores_honorific_and_linker():
    assert street_key("Avenida Don Juan de Borbón") == street_key("Avenida Juan de Borbón")
    assert street_key("Avenida de Juan Carlos I") == street_key("Avenida Juan Carlos I")
    assert street_key("Calle Morera") != street_key("Avenida Morera")


def test_merge_keeps_one_radar_per_spot():
    # both directions of the RM-603 section share their two end points
    a = dgt.parse((FIX / "dgt_radares.xml").read_bytes(), {"30"})
    twin = [type(r)(**{**r.__dict__, "id": r.id + "-twin", "name": "Radar de tramo X"}) for r in a]
    merged = feed.merge(a + twin, date(2026, 9, 30))
    assert len(merged) == len({(round(r.lat, 5), round(r.lon, 5)) for r in a})
    assert not any(r.id.endswith("-twin") for r in merged)


def test_merge_drops_expired_weekly_radars():
    weekly = [
        type(r)(**{**r.__dict__, "valid_from": date(2026, 9, 21), "valid_to": date(2026, 9, 27)})
        for r in dgt.parse((FIX / "dgt_radares.xml").read_bytes(), {"30"})
    ]
    assert feed.merge(weekly, date(2026, 9, 27))
    assert feed.merge(weekly, date(2026, 9, 28)) == []
