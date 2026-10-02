"""Open OpenStreetMap notes that report a speed camera: unconfirmed, in the feed only.
The fixture is a trimmed notes search of 2 Oct 2026, plus one closed note."""

import json
from datetime import date
from pathlib import Path

import pytest

from radares_anunciados import feed, net, provinces, store
from radares_anunciados.model import REPORTED, Radar, SourceResult
from radares_anunciados.sources import Context, osm_notes
from radares_anunciados.speed import Radius

FIX = Path(__file__).parent / "fixtures"
PAYLOAD = (FIX / "osm_notes_2026-10-02.json").read_bytes()
SPAIN = tuple(provinces.boxes(None))


def test_notes_give_open_speed_camera_reports_in_spain():
    notes = osm_notes.parse(PAYLOAD, SPAIN)
    # dropped: three red-light cameras in Girona, two notes in other countries
    # (a camera in Brazil, a toilet in England), a radar detector, a closed note,
    # and three inside Lleida's box but outside Spain: two in Andorra (4628291 is
    # 1.3 km from the border) and one in France
    assert [n.id for n in notes] == ["osm-note-5162275", "osm-note-5144466", "osm-note-5144458"]
    first = notes[0]
    assert (first.kind, first.source, first.radius_m) == (REPORTED, "osm_notes", 0)
    assert first.name == "Nuevo radar fijo Doppler de 90kmh ambos sentidos"
    assert first.url == "https://www.openstreetmap.org/note/5162275"
    assert first.reported == date(2026, 2, 10)
    assert (round(first.lat, 4), round(first.lon, 4)) == (38.0905, -0.7313)
    long_text = notes[1].name
    assert len(long_text) == osm_notes.MAX_TEXT and long_text.endswith("…")


@pytest.mark.parametrize(
    ("place", "point", "spain"),
    [
        ("Andorra la Vella", (42.5063, 1.5218), False),
        ("Sant Julià de Lòria, Andorra", (42.4468, 1.4822), False),
        ("Ariège, France", (42.7867, 1.6939), False),
        ("La Seu d'Urgell", (42.3580, 1.4610), True),
        ("Llívia, the enclave in France", (42.4640, 1.9810), True),
        ("Roses, on the coast", (42.2663, 3.1661), True),
        ("Benasque, Huesca: no shape there, the box decides", (42.6040, 0.5240), True),
        ("Lisboa", (38.7223, -9.1393), False),
    ],
)
def test_notes_are_kept_inside_spain_where_the_catalan_boxes_overreach(place, point, spain):
    assert osm_notes.in_spain(*point) is spain, place


@pytest.mark.parametrize(
    ("text", "kept"),
    [
        ("Nuevo radar de tramo entre el pk 523,360 y el 519,200 de 120", True),
        ("Radar fix en ambdós sentits. Limitació: 50 km/h.", True),
        ('"RADAR 30KM/H" OSM snapshot date: 2026-08-11T11:19:54Z', True),
        ("Radar fijo, no está mapeado", True),
        ("Radar foto rojo", False),
        ("semáforo, no está más el radar #OsmAnd", False),
        ("pas de radar ici en ce moment #OsmAnd", False),
        ("Radar pédagogique via StreetComplete 63.4", False),
        ("There is a military radar station on the top of the mountain", False),
        ("There's an accessible RADAR key toilet in this car park", False),
        ("My radar detector would used to go off all the time", False),
        ("velocidade 80 caminhão e 100 veiculos", False),
    ],
)
def test_the_filter_keeps_speed_camera_reports_only(text, kept):
    assert osm_notes.about_speed(text) is kept


def test_a_closed_note_leaves_on_the_next_run(monkeypatch, tmp_path):
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))
    data = json.loads(PAYLOAD)
    later = dict(data, features=[f for f in data["features"] if f["properties"]["id"] != 5162275])
    answers = iter([PAYLOAD, json.dumps(later).encode()])
    monkeypatch.setattr(net, "get", lambda url, data=None, headers=None: next(answers))
    ctx = Context(date(2026, 10, 2), None, SPAIN, Radius(), max_age_s=0)
    assert "osm-note-5162275" in {r.id for r in osm_notes.fetch(ctx).radars}
    assert "osm-note-5162275" not in {r.id for r in osm_notes.fetch(ctx).radars}


def test_an_answer_that_is_no_notes_is_refused_and_not_kept(monkeypatch, tmp_path):
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))
    answers = iter([b"<html>busy</html>", PAYLOAD])
    monkeypatch.setattr(net, "get", lambda url, data=None, headers=None: next(answers))
    ctx = Context(date(2026, 10, 2), None, SPAIN, Radius())
    with pytest.raises(ValueError, match="no JSON"):
        osm_notes.fetch(ctx)
    assert len(osm_notes.fetch(ctx).radars) == 3  # asked again: the bad answer was not cached


def test_a_report_never_drops_or_replaces_a_radar_and_nothing_drops_it():
    camera = Radar("dgt-1", "dgt", "fixed", "Radar fijo A-7 km 1", 38.0905, -0.7313, 500)
    note = osm_notes.parse(PAYLOAD, SPAIN)[0]
    at_the_spot = Radar("osm-note-1", "osm_notes", REPORTED, "radar", camera.lat, camera.lon, 0)
    merged = feed.merge([note, at_the_spot, camera], date(2026, 10, 2))
    assert {r.id for r in merged} == {"dgt-1", "osm-note-5162275", "osm-note-1"}


def test_a_report_keeps_its_date_in_the_last_good_result():
    result = SourceResult(radars=osm_notes.parse(PAYLOAD, SPAIN))
    again = store.result_from_json(json.loads(json.dumps(store.result_to_json(result))))
    assert again == result and again.radars[0].reported == date(2026, 2, 10)


def test_a_note_in_another_shape_is_skipped_and_the_rest_kept(caplog):
    data = json.loads(PAYLOAD)
    broken = json.loads(json.dumps(data["features"][0]))
    del broken["geometry"]
    odd_date = json.loads(json.dumps(data["features"][1]))
    odd_date["properties"]["date_created"] = "yesterday"
    data["features"] += [broken, odd_date]
    data["features"] = data["features"][2:]  # the two originals only in their broken copies
    notes = osm_notes.parse(json.dumps(data).encode(), SPAIN)
    assert [n.id for n in notes] == ["osm-note-5144458"]
    assert caplog.text.count("OSM note skipped") == 2
