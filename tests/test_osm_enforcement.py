"""OpenStreetMap enforcement relations: a camera's direction and limit, average-speed
sections, and cameras mapped only as a relation member. The fixtures are the two
Overpass answers of 2 Oct 2026, cameras and relations, trimmed to the same places."""

from dataclasses import replace
from datetime import date
from pathlib import Path

from radares_anunciados import feed, net
from radares_anunciados.model import Radar
from radares_anunciados.sources import Context, dgt, osm
from radares_anunciados.speed import Radius

FIX = Path(__file__).parent / "fixtures"
CAMERAS = (FIX / "osm_cameras_2026-10-02.json").read_bytes()
RELATIONS = (FIX / "osm_enforcement_2026-10-02.json").read_bytes()
RESULT = osm.parse_all(CAMERAS, RELATIONS)
BY_ID = {r.id: r for r in RESULT.radars}


def test_a_camera_takes_its_direction_and_limit_from_its_relation():
    # node 992004847 has no direction tag; relation 8407199 goes from 306024148 to 306024146
    assert BY_ID["osm-992004847"].direction == "287"
    # node 1976460257 has no maxspeed; relation 2517637 says 50
    assert BY_ID["osm-1976460257"].maxspeed == 50


def test_relations_a_few_degrees_apart_agree():
    # node 992001427: relations 9928269 and 9928271 give 75 and 76 degrees
    assert BY_ID["osm-992001427"].direction == "76"


def test_the_camera_s_own_tags_win_over_its_relation():
    # node 6218566440 says direction 0 and maxspeed 50; relation 14878832 says 215 and 30
    camera = BY_ID["osm-6218566440"]
    assert (camera.direction, camera.maxspeed) == ("0", 50)


def test_a_camera_whose_relations_point_both_ways_gets_no_direction():
    # relations 20455293 and 20455294 enforce opposite directions at one camera
    camera = BY_ID["osm-13734382524"]
    assert (camera.direction, camera.maxspeed) == (None, 40)


def test_an_average_speed_relation_is_two_section_ends_and_a_line():
    ends = [r for r in RESULT.radars if r.id.startswith("osm-relation-1019388-")]
    assert [r.id for r in ends] == ["osm-relation-1019388-from", "osm-relation-1019388-to"]
    assert {r.kind for r in ends} == {"section"}
    # one name for both ends, so the blueprint alerts once for the section
    assert {r.name for r in ends} == {"Radar de tramo A-5 (OSM 1019388)"}
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


def test_a_section_is_named_by_its_road_and_keeps_the_id_only_without_one():
    names = {s.id: (s.name, s.road) for s in RESULT.stretches}
    # the road comes from the relation's section ways; the id keeps two A-5
    # sections apart, since the blueprint alerts once per name
    assert names["osm-relation-1019388"] == ("Tramo A-5 (OSM 1019388)", "A-5")
    # a road and km in a tag beat the ways
    assert names["osm-relation-10026551"] == ("Tramo A-7 km 593.28", "A-7")
    # no ref and no name on any way: the id alone
    assert names["osm-relation-21440002"] == ("Tramo (OSM 21440002)", None)


def test_a_short_section_with_one_camera_near_both_ends_uses_the_road_nodes():
    # relation 21440002 is 72 m long; its one camera is the nearest to both ends
    start, end = BY_ID["osm-relation-21440002-from"], BY_ID["osm-relation-21440002-to"]
    assert (start.lat, start.lon) != (end.lat, end.lon)


def test_a_section_with_two_starts_keeps_its_cameras_as_cameras():
    # relation 16901376 has two "from" nodes: no single start and end
    assert not any(s.id == "osm-relation-16901376" for s in RESULT.stretches)
    for camera in (11468893139, 8952335905, 8952335902):
        assert BY_ID[f"osm-{camera}"].kind == "fixed"


def test_a_device_with_no_highway_tag_is_a_camera_and_a_speed_display_is_not():
    bare = BY_ID["osm-7024118307"]  # untagged device of relation 10358149
    assert (bare.kind, bare.maxspeed, bare.direction) == ("fixed", 80, "92")
    assert "osm-12759335510" not in BY_ID  # highway=speed_display, relation 17929026


def sections_left(radars, stretches):
    radars, stretches = feed.drop_copied_sections(radars, stretches)
    lines = {s.id for s in stretches if s.source == "osm"}
    ends = {r.id.rsplit("-", 1)[0] for r in radars if r.kind == "section" and r.source == "osm"}
    assert lines == ends, "a section goes whole, line and both ends"
    return lines


def test_an_osm_section_an_authority_publishes_goes_whole():
    official = dgt.parse_all((FIX / "dgt_radares.xml").read_bytes(), None)
    left = sections_left(official.radars + RESULT.radars, official.stretches + RESULT.stretches)
    # 17135243 is DGT's Z-40 section, ends 11 m and 7 m off. 10026551 and 11547740
    # are DGT's A-7 km 636.1-634.6 at Lorca, ends 54 m to 536 m off: a driver
    # there got three alerts
    assert not left & {
        "osm-relation-17135243",
        "osm-relation-10026551",
        "osm-relation-11547740",
    }
    assert "osm-relation-1019388" in left  # no authority publishes it


def official_section_end(lat, lon):
    return Radar("dgt-x-from", "dgt", "section", "Radar de tramo X", lat, lon, 500)


def test_one_copied_end_takes_the_whole_section():
    start = BY_ID["osm-relation-1019388-from"]
    near = official_section_end(start.lat + 0.006, start.lon)  # about 670 m north of one end
    assert "osm-relation-1019388" not in sections_left([near, *RESULT.radars], RESULT.stretches)
    far = official_section_end(start.lat + 0.012, start.lon)  # about 1.3 km: another section
    assert "osm-relation-1019388" in sections_left([far, *RESULT.radars], RESULT.stretches)
    # a published fixed camera counts only within the camera rule's 150 m
    fixed = replace(near, id="dgt-y", kind="fixed")
    assert "osm-relation-1019388" in sections_left([fixed, *RESULT.radars], RESULT.stretches)
    fixed = replace(fixed, lat=start.lat + 0.001)  # 110 m
    assert "osm-relation-1019388" not in sections_left([fixed, *RESULT.radars], RESULT.stretches)


def test_cameras_come_even_when_the_relations_query_fails(monkeypatch, tmp_path):
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))

    def get(url, data=None, headers=None):
        if data["data"].startswith("[out:json][timeout:180];(relation"):
            raise OSError("HTTP 504")
        return CAMERAS

    monkeypatch.setattr(net, "get", get)
    result = osm.fetch(Context(date(2026, 10, 2), None, (osm.MURCIA_REGION,), Radius()))
    assert len(result.radars) == 20 and result.stretches == []


def test_the_relations_query_reads_by_bounding_box():
    q = osm.relations_query([osm.MURCIA_REGION, (40.0, -4.0, 41.0, -3.0)])
    assert "area" not in q
    assert q.count('relation["type"="enforcement"]') == 2
    assert "node(r.r)" in q  # the members carry the positions
    assert 'way(r.r:"section")' in q and ".w out tags;" in q  # the road of a section
    # the cameras query is its own, as it was, so a cached answer stays valid
    assert "relation" not in osm.query_boxes([osm.MURCIA_REGION, (40.0, -4.0, 41.0, -3.0)])
