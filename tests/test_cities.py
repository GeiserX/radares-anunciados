"""Madrid and Salamanca fixed and section radars, from their open data portals."""

import json
import logging
from dataclasses import replace
from datetime import date
from pathlib import Path

import pytest

from radares_anunciados import feed
from radares_anunciados.geo import distance_m
from radares_anunciados.sources import Context, madrid, salamanca
from radares_anunciados.speed import Radius

FIX = Path(__file__).parent / "fixtures"
CSV_URL = (
    "https://datos.madrid.es/dataset/300049-0-radares-fijos-moviles/resource/"
    "300049-1-radares-fijos-moviles-csv/download/300049-1-radares-fijos-moviles-csv.csv"
)
CTX = Context(day=date(2026, 10, 1), provinces=None, boxes=(), radius=Radius())


def madrid_csv() -> bytes:
    return (FIX / "madrid_radares.csv").read_bytes()


def test_madrid_finds_the_csv_through_ckan():
    url, updated = madrid.csv_resource((FIX / "madrid_package.json").read_bytes())
    assert url == CSV_URL
    assert updated == "2026-07-31"


def test_madrid_reads_every_row_of_the_real_file():
    result = madrid.parse(madrid_csv(), CSV_URL, "2026-07-31")
    fixed = [r for r in result.radars if r.kind == "fixed"]
    sections = [r for r in result.radars if r.kind == "section"]
    # 27 fixed rows and 9 section rows (a start and an exit camera each) are 26
    # sites: lanes of one gantry and section ends that share a camera are one
    assert len(fixed) == 20
    assert len(sections) == 6
    assert len(result.stretches) == 9
    first = next(r for r in fixed if r.id == "madrid-1")
    assert (first.lat, first.lon) == (40.47934148, -3.67433808)
    assert first.maxspeed == 90
    assert first.name == "Radar fijo M-30, ENTRADA DE LA A-1, SENTIDO PUENTE DE VENTAS P.K. 0,500"
    assert first.direction == "Calzada interior"
    for r in result.radars:
        assert r.name.startswith("Radar")
        assert r.source == "madrid" and r.province == "28" and r.url == CSV_URL
        assert r.attribution == (
            "Origen de los datos: Ayuntamiento de Madrid (CC BY 4.0), actualizado 2026-07-31"
        )
        assert 40.3 < r.lat < 40.5 and -3.8 < r.lon < -3.6
    assert len({r.id for r in result.radars}) == len(result.radars)


def test_madrid_section_runs_from_its_start_to_its_exit_camera():
    result = madrid.parse(madrid_csv(), CSV_URL)
    # row 28: its "Ubicación Calle 30" cell is quoted and split over two lines
    stretch = next(s for s in result.stretches if s.id == "madrid-28")
    assert stretch.start == (40.387572, -3.699380)
    assert stretch.end == (40.378590, -3.696519)
    assert stretch.maxspeed == 50 and stretch.direction == "Salida"
    ends = {r.id: (r.lat, r.lon) for r in result.radars if r.id.startswith("madrid-28-")}
    assert ends == {"madrid-28-from": stretch.start, "madrid-28-to": stretch.end}


def test_madrid_skips_and_logs_rows_it_cannot_read(caplog):
    lines = madrid_csv().decode("utf-8-sig").splitlines()
    shifted = "40;" + lines[1].split(";", 1)[1].replace(";Fijo;", ";;Fijo;", 1)  # 17 columns
    blank_type = "41;" + lines[1].split(";", 1)[1].replace(";Fijo;", ";;", 1)  # no type
    outside = "42;" + lines[1].split(";", 1)[1].replace("40.47934148", "41.47934148")
    no_number = ";" + lines[1].split(";", 1)[1]
    repeated = "1;" + lines[3].split(";", 1)[1]  # Nº 1 again, at row 3's camera
    text = "\r\n".join([*lines, shifted, blank_type, outside, no_number, repeated]) + "\r\n"
    with caplog.at_level(logging.WARNING):
        result = madrid.parse(("﻿" + text).encode(), CSV_URL)
    assert not {"madrid-40", "madrid-41", "madrid-42"} & {r.id for r in result.radars}
    assert len(result.radars) == 26
    assert len({r.id for r in result.radars}) == 26
    log = caplog.text
    assert "has 17 columns, not 16" in log
    assert "unknown type ''" in log
    assert "outside Madrid" in log
    assert "radar number '' is not a number" in log
    assert "radar number 1 appears twice" in log


def test_madrid_refuses_a_changed_header_rather_than_emptying_the_feed():
    renamed = madrid_csv().replace("Velocidad límite".encode(), b"Limite")
    with pytest.raises(ValueError, match="velocidad limite"):
        madrid.parse(renamed, CSV_URL)
    header_only = madrid_csv().decode("utf-8-sig").splitlines()[0].encode()
    with pytest.raises(ValueError, match="no radar"):
        madrid.parse(header_only, CSV_URL)


def test_madrid_fetch_goes_through_ckan(monkeypatch):
    answers = {
        madrid.API: (FIX / "madrid_package.json").read_bytes(),
        CSV_URL: madrid_csv(),
    }
    monkeypatch.setattr(madrid.net, "cached_get", lambda url, **kw: answers[url])
    result = madrid.SOURCE.fetch(replace(CTX, provinces=frozenset({"28"})))
    assert len(result.radars) == 26
    assert madrid.SOURCE.provinces == {"28"}


def test_madrid_keeps_one_radar_per_site(caplog):
    with caplog.at_level(logging.INFO):
        radars = madrid.parse(madrid_csv(), CSV_URL).radars
    ids = {r.id for r in radars}
    # lanes of one gantry, 0 to 12 m apart: the lowest Nº stays
    for kept, gone in [(1, 2), (4, 5), (6, 7), (8, 9), (18, 19), (21, 22), (23, 24)]:
        assert f"madrid-{kept}" in ids and f"madrid-{gone}" not in ids
    # a section end 34 m from fixed radar 20, and section ends 11 to 18 m apart
    assert "madrid-29-from" not in ids and "madrid-20" in ids
    assert "madrid-35-to" not in ids and "madrid-31-from" in ids
    assert "madrid-34-from" not in ids and "madrid-32-to" in ids
    # 148 m apart on the same tunnel: two cameras, two zones
    assert {"madrid-14", "madrid-15"} <= ids
    for i, a in enumerate(radars):
        for b in radars[i + 1 :]:
            near = distance_m((a.lat, a.lon), (b.lat, b.lon)) <= madrid.SAME_SITE_M
            assert not (near and a.maxspeed == b.maxspeed), (a.id, b.id)
    assert "madrid-2 is at the site of madrid-1" in caplog.text
    assert len(feed.merge(radars, date(2026, 10, 1))) == len(radars) == 26


def test_madrid_keeps_two_limits_at_one_site_apart():
    lines = madrid_csv().decode("utf-8-sig").splitlines()
    slower = lines[2].rsplit(";", 2)
    lines[2] = ";".join([slower[0], "70", slower[2]])  # Nº 2, 4 m from Nº 1, limit 70
    radars = madrid.parse("\r\n".join(lines).encode(), CSV_URL).radars
    assert {"madrid-1", "madrid-2"} <= {r.id for r in radars}


SA_FIXED = (
    "https://ide.aytosalamanca.es/geoserver/ide_salamanca_tic/ows?service=WFS&version=1.0.0"
    "&request=GetFeature&typeName=ide_salamanca_tic%3ARadares_Fijos&outputFormat="
    "application%2Fjson&srsName=EPSG%3A4326"
)
SA_TRAMO = (
    "https://ide.aytosalamanca.es/geoserver/ide_salamanca_movilidad/ows?service=WFS&version=1.0.0"
    "&request=GetFeature&typeName=ide_salamanca_movilidad%3ARADAR_TRAMO&outputFormat="
    "application%2Fjson&srsName=EPSG%3A4326"
)


def test_salamanca_finds_both_layers_through_ckan():
    package = (FIX / "salamanca_package.json").read_bytes()
    # each layer's own date; the catalogue entry's metadata_modified (2025-10-22)
    # moves when its description is edited and is never the data's date
    assert salamanca.geojson_resources(package) == [
        (SA_FIXED, "2024-08-08"),  # last_modified
        (SA_TRAMO, "2025-01-22"),  # never modified: created
    ]
    undated = json.loads(package)
    for r in undated["result"]["resources"]:
        r.pop("last_modified"), r.pop("created")
    assert [d for _, d in salamanca.geojson_resources(json.dumps(undated).encode())] == [None] * 2
    undated["result"]["modified"] = "2026-01-02T00:00:00"
    assert [d for _, d in salamanca.geojson_resources(json.dumps(undated).encode())] == [
        "2026-01-02"
    ] * 2


def test_salamanca_fixed_points():
    result = salamanca.parse((FIX / "salamanca_fijos.json").read_bytes(), SA_FIXED, "2024-08-08")
    assert len(result.radars) == 20 and not result.stretches
    first = next(r for r in result.radars if r.id == "salamanca-1")
    # GeoJSON is (lon, lat); the "Latitud"/"Longitud" properties are UTM and unused
    assert (first.lat, first.lon) == (40.95233426, -5.67012994)
    assert first.name == "Radar fijo Avenida Saavedra y Fajardo"
    assert first.maxspeed == 50 and first.kind == "fixed" and first.province == "37"
    assert first.attribution.endswith("actualizado 2024-08-08")
    assert {r.maxspeed for r in result.radars} == {30, 50}
    assert all(r.name.startswith("Radar fijo ") for r in result.radars)


def test_salamanca_sections_are_lines_with_a_camera_at_each_end():
    result = salamanca.parse((FIX / "salamanca_tramo.json").read_bytes(), SA_TRAMO)
    assert len(result.stretches) == 4
    assert len(result.radars) == 8
    assert all(r.kind == "section" and r.maxspeed == 30 for r in result.radars)
    one = next(s for s in result.stretches if s.id == "salamanca-tramo-1")
    assert one.start == (40.95486928, -5.69108462) and one.end == (40.95491575, -5.68603896)
    two = next(s for s in result.stretches if s.id == "salamanca-tramo-2")
    assert len(two.line) > 2 and two.line[0] == two.start and two.line[-1] == two.end
    # features 1 and 3 (and 2 and 4) share their geometry: one circle per spot
    assert len(feed.merge(result.radars, date(2026, 10, 1))) == 4


def test_salamanca_skips_and_logs_features_it_cannot_read(caplog):
    payload = (FIX / "salamanca_fijos.json").read_text()
    swapped = payload.replace("[[-5.67012994,40.95233426]]", "[[40.95233426,-5.67012994]]")
    no_geometry = swapped.replace(
        '"geometry":{"type":"MultiPoint","coordinates":[[-5.66292203,40.94945195]]}',
        '"geometry":null',
    )
    no_fid = no_geometry.replace('"properties":{"fid":3,', '"properties":{', 1)
    assert no_fid != no_geometry != swapped != payload
    with caplog.at_level(logging.WARNING):
        result = salamanca.parse(no_fid.encode(), SA_FIXED)
    ids = {r.id for r in result.radars}
    assert ids.isdisjoint({"salamanca-1", "salamanca-2", "salamanca-3", "salamanca-None"})
    assert len(result.radars) == 17
    assert "Radares_Fijos.3 skipped (no numeric fid (None))" in caplog.text
    assert "Radares_Fijos.1 skipped" in caplog.text and "outside Salamanca" in caplog.text
    assert "Radares_Fijos.2 skipped" in caplog.text


def test_salamanca_fetch_refuses_an_empty_layer(monkeypatch):
    answers = {
        salamanca.API: (FIX / "salamanca_package.json").read_bytes(),
        SA_FIXED: (FIX / "salamanca_fijos.json").read_bytes(),
        SA_TRAMO: (FIX / "salamanca_tramo.json").read_bytes(),
    }
    monkeypatch.setattr(salamanca.net, "cached_get", lambda url, **kw: answers[url])
    result = salamanca.SOURCE.fetch(CTX)
    assert len(result.radars) == 28 and len(result.stretches) == 4
    dates = {r.kind: r.attribution.rsplit(" ", 1)[1] for r in result.radars}
    assert dates == {"fixed": "2024-08-08", "section": "2025-01-22"}
    answers[SA_TRAMO] = b'{"type":"FeatureCollection","features":[]}'
    with pytest.raises(ValueError, match="no radar"):
        salamanca.SOURCE.fetch(CTX)


def _osm_copy(r, north_m: float):
    from radares_anunciados.model import Radar

    return Radar(
        id=f"osm-copy-of-{r.id}", source="osm", kind="fixed", name="Radar",
        lat=r.lat + north_m / 111_320, lon=r.lon, radius_m=500,
    )  # fmt: skip


def test_a_madrid_or_salamanca_radar_drops_its_osm_copy():
    # Both are official sources (the registry default), so an OpenStreetMap camera
    # within feed.DUPLICATE_M of one is the same camera mapped twice.
    day = date(2026, 10, 1)
    city = [
        madrid.parse(madrid_csv(), CSV_URL, "2026-07-31").radars[0],
        salamanca.parse((FIX / "salamanca_fijos.json").read_bytes(), SA_FIXED).radars[0],
    ]
    for r in city:
        assert [x.id for x in feed.merge([r, _osm_copy(r, 5)], day)] == [r.id]
        assert len(feed.merge([r, _osm_copy(r, 300)], day)) == 2  # another camera
