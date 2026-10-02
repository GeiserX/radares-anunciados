"""OpenStreetMap enforcement relations: a camera's direction and limit, average-speed
sections, and cameras mapped only as a relation member. The fixture is a trimmed
Overpass answer of 2 Oct 2026."""

from datetime import date
from pathlib import Path

from radares_anunciados import feed
from radares_anunciados.sources import dgt, osm

FIX = Path(__file__).parent / "fixtures"
RESULT = osm.parse_all((FIX / "osm_enforcement_2026-10-02.json").read_bytes())
BY_ID = {r.id: r for r in RESULT.radars}


def test_a_camera_takes_its_direction_and_limit_from_its_relation():
    # node 992004847 has no direction tag; relation 8407199 goes from 306024148 to 306024146
    assert BY_ID["osm-992004847"].direction == "287"
    # node 1976460257 has no maxspeed; relation 2517637 says 50
    assert BY_ID["osm-1976460257"].maxspeed == 50


def test_a_camera_whose_relations_point_both_ways_gets_no_direction():
    # relations 20455293 and 20455294 enforce opposite directions at one camera
    camera = BY_ID["osm-13734382524"]
    assert (camera.direction, camera.maxspeed) == (None, 40)


def test_an_average_speed_relation_is_two_section_ends_and_a_line():
    ends = [r for r in RESULT.radars if r.id.startswith("osm-relation-1019388-")]
    assert [r.id for r in ends] == ["osm-relation-1019388-from", "osm-relation-1019388-to"]
    assert {r.kind for r in ends} == {"section"}
    # one name for both ends, so the blueprint alerts once for the section
    assert {r.name for r in ends} == {"Radar de tramo (OSM 1019388)"}
    assert {(r.maxspeed, r.direction) for r in ends} == {(70, "242")}
    assert {r.url for r in ends} == {"https://www.openstreetmap.org/relation/1019388"}
    line = next(s for s in RESULT.stretches if s.id == "osm-relation-1019388")
    assert (line.start, line.end) == ((ends[0].lat, ends[0].lon), (ends[1].lat, ends[1].lon))
    # its three cameras stand at the two ends: none is added again as a plain camera
    for camera in (7373959736, 6203468146, 7373951325):
        assert f"osm-{camera}" not in BY_ID


def test_a_section_end_sits_on_its_camera():
    # relation 17135243: camera 2378266882 near "from", 992002534 near "to"
    start = BY_ID["osm-relation-17135243-from"]
    assert (round(start.lat, 7), round(start.lon, 7)) == (41.6087959, -0.9155533)


def test_a_section_with_two_starts_keeps_its_cameras_as_cameras():
    # relation 16901376 has two "from" nodes: no single start and end
    assert not any(s.id == "osm-relation-16901376" for s in RESULT.stretches)
    for camera in (11468893139, 8952335905, 8952335902):
        assert BY_ID[f"osm-{camera}"].kind == "fixed"


def test_a_device_with_no_highway_tag_is_a_camera_and_a_speed_display_is_not():
    bare = BY_ID["osm-7024118307"]  # untagged device of relation 10358149
    assert (bare.kind, bare.maxspeed, bare.direction) == ("fixed", 80, "92")
    assert "osm-12759335510" not in BY_ID  # highway=speed_display, relation 17929026


def test_an_osm_section_an_authority_publishes_goes_with_its_line():
    official = dgt.parse_all((FIX / "dgt_radares.xml").read_bytes(), None)
    radars = feed.merge(official.radars + RESULT.radars, date(2026, 10, 2))
    lines = feed.merge_stretches(official.stretches + RESULT.stretches, radars)
    ids = {r.id for r in radars} | {s.id for s in lines}
    # DGT publishes 17135243 as section CVM_161274 (Zaragoza): its ends are 11 m and 7 m off
    assert not ids & {"osm-relation-17135243", "osm-relation-17135243-from"}
    assert "osm-relation-17135243-to" not in ids
    assert "dgt-CVM_161274" in ids
    # a section no authority publishes stays, line and ends
    assert {"osm-relation-1019388", "osm-relation-1019388-from", "osm-relation-1019388-to"} <= ids


def test_the_query_reads_relations_by_bounding_box():
    q = osm.query_boxes([osm.MURCIA_REGION, (40.0, -4.0, 41.0, -3.0)])
    assert "area" not in q
    assert q.count('relation["type"="enforcement"]') == 2
    assert "node(r.r)" in q  # the members carry the positions
