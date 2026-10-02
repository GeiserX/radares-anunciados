"""Barcelona and Madrid traffic fines: where radars stood, by how often a place fined."""

import json
import os
from dataclasses import replace
from datetime import date
from pathlib import Path

import pytest

from radares_anunciados import feed, ha
from radares_anunciados.model import Radar
from radares_anunciados.sources import Context, barcelona_multas, madrid_multas
from radares_anunciados.speed import Radius

FIX = Path(__file__).parent / "fixtures"
DAY = date(2026, 10, 2)
CTX = Context(day=DAY, provinces=None, boxes=(), radius=Radius())
Q4 = barcelona_multas.Quarter("5693bb33-9212-44df-9c67-a90a5fc06838", 2025, 4)
MADRID_MONTH = (
    "https://datos.madrid.es/dataset/210104-0-multas-circulacion-detalle/resource/"
    "210104-{n}-multas-circulacion-detalle/download/{ym}detalle.csv"
)
JANUARY = MADRID_MONTH.format(n=377, ym="202601")
FEBRUARY = MADRID_MONTH.format(n=379, ym="202602")


@pytest.fixture(autouse=True)
def clean_env(monkeypatch, tmp_path):
    for name in list(os.environ):
        if name.startswith("RADARES_"):
            monkeypatch.delenv(name)
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))


def fixture(name: str) -> bytes:
    return (FIX / name).read_bytes()


# ---- Barcelona -----------------------------------------------------------------


def test_barcelona_reads_the_newest_quarter_of_the_datastore():
    quarter, updated = barcelona_multas.newest_quarter(
        fixture("barcelona_multas_package_2026-10-02.json")
    )
    assert quarter == Q4
    assert (quarter.first, quarter.last, quarter.days) == (
        date(2025, 10, 1),
        date(2025, 12, 31),
        92,
    )
    assert updated == "2026-09-01"
    q1 = replace(Q4, quarter=1)
    assert (q1.first, q1.last, q1.days) == (date(2025, 1, 1), date(2025, 3, 31), 90)


def test_barcelona_asks_for_camera_speed_fines_only():
    sql = barcelona_multas.query(Q4.resource)
    assert "\"MITJA_IMPOSICIO\" = 'MTO'" in sql
    assert "'1210'" in sql and "'1232'" in sql and "'1225'" not in sql
    assert f'FROM "{Q4.resource}"' in sql


def test_barcelona_tells_fixed_cameras_from_mobile_spots_by_days():
    result = barcelona_multas.parse(fixture("barcelona_multas_2025_4t.json"), Q4, "2026-09-01")
    by_name = {r.name: r for r in result.radars}
    # 53 camera places: 1 without a position and 5 that fined on one day are left
    # out, and two pairs share a site, which leaves 45 zones
    assert len(result.radars) == 45
    assert sum(r.kind == "fixed" for r in result.radars) == 21
    assert sum(r.kind == "mobile_recurring" for r in result.radars) == 24
    fixed = by_name["Radar fijo Via Augusta 331"]
    assert fixed.kind == "fixed" and (fixed.lat, fixed.lon) == (41.4003214, 2.1228873)
    # 50 of 92 days is most of them; 43 is not, even for a camera that fined every
    # day from mid-November on
    assert by_name["Radar fijo Ronda Litoral (Besòs) 20"].kind == "fixed"
    mobile = by_name["Radar móvil frecuente Ronda del Mig (Descendent) 1 (43 días en 92)"]
    assert mobile.kind == "mobile_recurring"
    assert "Radar móvil frecuente Avinguda Diagonal 579 (28 días en 92)" in by_name
    # a place that fined on a single day gets no zone
    assert not [n for n in by_name if "Bosch i Gimpera" in n or "Cardenal Reig" in n]
    # both directions of one gantry, 7 m apart: one zone
    assert [n for n in by_name if "Ronda de Dalt" in n and " 74" in n] == [
        "Radar fijo Ronda de Dalt (Llobregat) 74"
    ]
    for r in result.radars:
        assert r.source == "barcelona_multas" and r.province == "08"
        assert r.attribution == (
            "Fuente de los datos: Ayuntamiento de Barcelona (CC BY 4.0), multas de tráfico "
            "del 4.º trimestre de 2025 agrupadas por lugar, actualizado 2026-09-01"
        )
        assert r.valid_to is None  # standing places, not a list of the day
    assert len({r.id for r in result.radars}) == len(result.radars)


def test_barcelona_refuses_an_answer_without_places():
    with pytest.raises(ValueError, match="SQL failed"):
        barcelona_multas.parse(b'{"success": false, "error": {"message": "x"}}', Q4)
    empty = json.dumps({"success": True, "result": {"records": []}}).encode()
    with pytest.raises(ValueError, match="no camera place"):
        barcelona_multas.parse(empty, Q4)


def test_barcelona_fetch_queries_the_newest_quarter(monkeypatch):
    answers = {
        barcelona_multas.API: fixture("barcelona_multas_package_2026-10-02.json"),
        barcelona_multas.sql_url(Q4.resource): fixture("barcelona_multas_2025_4t.json"),
    }
    monkeypatch.setattr(barcelona_multas.net, "cached_get", lambda url, **kw: answers[url])
    result = barcelona_multas.SOURCE.fetch(CTX)
    assert len(result.radars) == 45
    assert barcelona_multas.SOURCE.provinces == {"08"}


# ---- Madrid --------------------------------------------------------------------


@pytest.fixture(scope="module")
def names() -> list[str]:
    data = json.loads(fixture("madrid_multas_overpass_names.json"))
    return sorted(e["tags"]["name"] for e in data["elements"])


def test_madrid_finds_the_monthly_files_through_ckan():
    months = madrid_multas.months(fixture("madrid_multas_package_2026-10-02.json"))
    # oldest first; the TXT copy of a month, the grouped files and the PDF are not months
    assert [(m.year, m.month) for m in months] == [(2025, 11), (2025, 12), (2026, 1), (2026, 2)]
    assert months[-1].url == FEBRUARY and months[-1].label() == "febrero de 2026"


def test_madrid_counts_the_speed_fines_of_places_coded_with_a_number():
    lines = fixture("madrid_multas_2026-02.csv").decode("latin-1").splitlines()
    places = madrid_multas.parse_month(lines)
    assert sorted(places) == [
        "N001 PO MORET",
        "N002 AV JUAN DE HERRERA",
        "N094 ALCALDE SAINZ BARAND",
        "N128 JOSEFA VALCARCEL",
        "N320 EMBAJADORES",
        "N378 AV ARAGON",
    ]
    assert places["N378 AV ARAGON"] == {"fines": 3, "limits": {"60": 3}}
    with pytest.raises(ValueError, match="header"):
        madrid_multas.parse_month([lines[0].replace("VEL_LIMITE", "LIMITE")] + lines[1:])
    no_speed = [line for line in lines if "VELOCIDAD" not in line]
    with pytest.raises(ValueError, match="no speed fine"):
        madrid_multas.parse_month(no_speed)


@pytest.mark.parametrize(
    ("written", "mapped"),
    [
        ("AV JUAN DE HERRERA", ["Avenida Juan de Herrera"]),  # not Calle Juan de Herrera
        ("EMBAJADORES", ["Calle de Embajadores"]),  # no type: a street, not the Glorieta
        ("ALCALDE SAINZ BARAND", ["Calle del Alcalde Sáinz de Baranda"]),  # cut at 20
        ("PO GENERAL MARTINEZ", ["Paseo del General Martínez Campos"]),  # cut after a word
        ("AV FCO J SAENZ OIZA", ["Avenida de Francisco Javier Sáenz de Oíza"]),
        ("GOYA", ["Calle Goya", "Calle de Goya"]),  # one street, two spellings
        ("JOSEFA VALCARCEL", ["Calle de Josefa Valcárcel"]),
        ("PO MORETO", []),  # Calle Moreto is another street
        ("AV EMBAJADORES", []),  # no Avenida de Embajadores: never another type
    ],
)
def test_madrid_matches_the_written_street_to_mapped_names(names, written, mapped):
    assert madrid_multas.matches(written, names) == mapped


@pytest.fixture(scope="module")
def addresses() -> madrid_multas.AddressMap:
    return madrid_multas.AddressMap(fixture("madrid_multas_overpass_addresses.json"))


def test_madrid_places_a_number_or_its_nearest_neighbour_on_the_same_side(addresses):
    exact = addresses.find(["Calle de Embajadores"], 320)
    assert {a.number for a in exact} == {320}
    # Sáinz de Baranda 94 is not mapped; 86 is the nearest even number within 10
    near = addresses.find(["Calle del Alcalde Sáinz de Baranda"], 94)
    assert {a.number for a in near} == {86}
    # Josefa Valcárcel is mapped up to 48: nothing within 10 of 128
    assert addresses.find(["Calle de Josefa Valcárcel"], 128) == ()


def test_madrid_fetch_places_the_places_that_recur(monkeypatch, caplog):
    monkeypatch.setattr(madrid_multas, "MONTHS", 2)
    answers = {madrid_multas.API: fixture("madrid_multas_package_2026-10-02.json")}

    def cached_get(url, data=None, **kw):
        if url == madrid_multas.OVERPASS:
            if data["data"] == madrid_multas.NAMES_QUERY:
                return fixture("madrid_multas_overpass_names.json")
            return fixture("madrid_multas_overpass_addresses.json")
        return answers[url]

    files = {JANUARY: "madrid_multas_2026-01.csv", FEBRUARY: "madrid_multas_2026-02.csv"}
    downloads = []

    def download(url):
        downloads.append(url)
        return madrid_multas.parse_month(fixture(files[url]).decode("latin-1").splitlines())

    monkeypatch.setattr(madrid_multas.net, "cached_get", cached_get)
    monkeypatch.setattr(madrid_multas, "_download", download)
    with caplog.at_level("WARNING"):
        result = madrid_multas.SOURCE.fetch(CTX)
    by_name = {r.name: r for r in result.radars}
    # in both months: Juan de Herrera 2, Embajadores 320 (their numbers), Sáinz de
    # Baranda 94 and Moret 1 (a neighbouring number); Josefa Valcárcel 128 has no
    # number mapped near it and is skipped. Aragón 378 and Juan de Herrera 4 fined
    # in one month only.
    assert sorted(by_name) == [
        "Radar móvil frecuente Avenida Juan de Herrera 2 (2 meses de 2)",
        "Radar móvil frecuente Calle de Embajadores 320 (2 meses de 2)",
        "Radar móvil frecuente Calle del Alcalde Sáinz de Baranda 94 (2 meses de 2)",
        "Radar móvil frecuente Paseo de Moret 1 (2 meses de 2)",
    ]
    assert "could not place N128 JOSEFA VALCARCEL" in caplog.text
    herrera = by_name["Radar móvil frecuente Avenida Juan de Herrera 2 (2 meses de 2)"]
    assert herrera.maxspeed == 40 and herrera.kind == "mobile_recurring"
    assert herrera.province == "28" and herrera.valid_to is None
    assert herrera.attribution == (
        "Origen de los datos: Ayuntamiento de Madrid (CC BY 4.0), multas de circulación de "
        "enero de 2026 a febrero de 2026, lugares con multas en 2 meses o más, actualizado "
        "2026-10-02; posición © OpenStreetMap"
    )
    assert sorted(downloads) == [JANUARY, FEBRUARY]
    # a month is read once: the next run uses what was kept of it
    downloads.clear()
    assert madrid_multas.SOURCE.fetch(CTX).radars == result.radars
    assert downloads == []


def test_madrid_reads_a_month_again_when_the_portal_replaces_it(monkeypatch):
    month = madrid_multas.Month(2026, 2, FEBRUARY, "210104-379", "2026-10-02T07:52:11")
    reads = []

    def download(url):
        reads.append(url)
        return {"N001 PO MORET": {"fines": len(reads), "limits": {"50": len(reads)}}}

    monkeypatch.setattr(madrid_multas, "_download", download)
    assert madrid_multas.month_places(month)["N001 PO MORET"]["fines"] == 1
    assert madrid_multas.month_places(month)["N001 PO MORET"]["fines"] == 1
    replaced = replace(month, modified="2026-11-02T07:00:00")
    assert madrid_multas.month_places(replaced)["N001 PO MORET"]["fines"] == 2


# ---- both: in the feed and in Home Assistant -------------------------------------


def _radar(source: str, kind: str, lat: float, name: str = "Radar") -> Radar:
    return Radar(
        id=f"{source}-{kind}-{lat}",
        source=source,
        kind=kind,
        name=name,
        lat=lat,
        lon=2.0,
        radius_m=500,
    )


def test_a_mobile_spot_never_drops_a_mapped_camera_but_a_fixed_place_does():
    camera = _radar("osm", "fixed", 41.0009)  # 100 m north
    spot = _radar("barcelona_multas", "mobile_recurring", 41.0)
    assert len(feed.merge([spot, camera], DAY)) == 2
    fixed = _radar("barcelona_multas", "fixed", 41.0)
    assert [r.id for r in feed.merge([fixed, camera], DAY)] == [fixed.id]
    madrid_spot = _radar("madrid_multas", "mobile_recurring", 41.0)
    assert len(feed.merge([madrid_spot, camera], DAY)) == 2


def test_over_the_cap_a_fines_spot_comes_after_fixed_radars_and_before_stretches():
    home = (41.0, 2.0)
    stretch = _radar("dgt_invive", "mobile_stretch", 41.001)  # nearest of all
    spot = _radar("madrid_multas", "mobile_recurring", 41.01)
    fixed = _radar("dgt", "fixed", 41.1)
    far = _radar("osm", "fixed", 45.0)
    radars = [stretch, spot, fixed, far]
    for cap, want in [(1, [fixed]), (2, [fixed, far]), (3, [fixed, far, spot])]:
        kept, left_out = ha.select(radars, cap, home)
        assert kept == want, cap
        assert left_out == len(radars) - cap
