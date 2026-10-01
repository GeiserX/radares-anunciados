"""Madrid and Salamanca fixed and section radars, from their open data portals."""

import logging
from dataclasses import replace
from datetime import date
from pathlib import Path

import pytest

from radares_anunciados import feed
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
    # 27 fixed rows; 9 section rows, each with its start and exit camera
    assert len(fixed) == 27
    assert len(sections) == 18
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
    text = "\r\n".join([*lines, shifted, blank_type, outside, no_number]) + "\r\n"
    with caplog.at_level(logging.WARNING):
        result = madrid.parse(("﻿" + text).encode(), CSV_URL)
    assert not {"madrid-40", "madrid-41", "madrid-42"} & {r.id for r in result.radars}
    assert len(result.radars) == 27 + 18
    log = caplog.text
    assert "has 17 columns, not 16" in log
    assert "unknown type ''" in log
    assert "outside Madrid" in log
    assert "radar number '' is not a number" in log


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
    assert len(result.radars) == 45
    assert madrid.SOURCE.provinces == {"28"}


def test_madrid_merge_keeps_one_circle_per_spot():
    # rows 23 and 24 are two lanes of one camera at the same point
    radars = madrid.parse(madrid_csv(), CSV_URL).radars
    merged = feed.merge(radars, date(2026, 10, 1))
    assert len(merged) == len({(round(r.lat, 5), round(r.lon, 5)) for r in radars})
    assert len(merged) < len(radars)


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
    urls, updated = salamanca.geojson_resources((FIX / "salamanca_package.json").read_bytes())
    assert urls == [SA_FIXED, SA_TRAMO]
    assert updated == "2025-10-22"


def test_salamanca_fixed_points():
    result = salamanca.parse((FIX / "salamanca_fijos.json").read_bytes(), SA_FIXED, "2025-10-22")
    assert len(result.radars) == 20 and not result.stretches
    first = next(r for r in result.radars if r.id == "salamanca-1")
    # GeoJSON is (lon, lat); the "Latitud"/"Longitud" properties are UTM and unused
    assert (first.lat, first.lon) == (40.95233426, -5.67012994)
    assert first.name == "Radar fijo Avenida Saavedra y Fajardo"
    assert first.maxspeed == 50 and first.kind == "fixed" and first.province == "37"
    assert first.attribution.endswith("actualizado 2025-10-22")
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
    assert no_geometry != swapped != payload
    with caplog.at_level(logging.WARNING):
        result = salamanca.parse(no_geometry.encode(), SA_FIXED)
    assert {r.id for r in result.radars}.isdisjoint({"salamanca-1", "salamanca-2"})
    assert len(result.radars) == 18
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
    answers[SA_TRAMO] = b'{"type":"FeatureCollection","features":[]}'
    with pytest.raises(ValueError, match="no radar"):
        salamanca.SOURCE.fetch(CTX)
