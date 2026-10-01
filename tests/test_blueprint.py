"""The alert blueprint treats a name as one radar only where the sources make it so."""

import re
from collections import Counter
from datetime import date
from pathlib import Path

from radares_anunciados.sources import dgt, osm
from radares_anunciados.sources.murcia import to_radars
from radares_anunciados.streets import Announced

ROOT = Path(__file__).parents[1]
FIX = ROOT / "tests" / "fixtures"


def grouped_prefixes() -> tuple[str, ...]:
    """The name prefixes the blueprint's cooldown groups into one radar."""
    text = (ROOT / "blueprints" / "radar_zone_alert.yaml").read_text()
    found = re.search(r"radar\.startswith\(\(([^)]*)\)\)", text)
    assert found, "the blueprint no longer limits grouping by name to known prefixes"
    return tuple(re.findall(r"'([^']*)'", found.group(1)))


def test_names_shared_by_different_cameras_are_not_grouped():
    cameras = osm.parse((FIX / "osm_es_mc.json").read_bytes()) + [
        r for r in dgt.parse((FIX / "dgt_radares.xml").read_bytes(), {"30"}) if r.kind == "fixed"
    ]
    names = [r.name for r in cameras]
    # different OSM cameras share a name, so a cooldown on it would hide the second one
    assert Counter(names)["Radar (límite 50)"] == 2
    assert [n for n in names if n.startswith(grouped_prefixes())] == []


def test_one_radar_drawn_as_several_circles_is_grouped():
    sections = [
        r for r in dgt.parse((FIX / "dgt_radares.xml").read_bytes(), {"30"}) if r.kind == "section"
    ]
    street = to_radars(
        [Announced("Camino Tiñosa", "San José de la Vega")],
        (FIX / "overpass_weeks.json").read_bytes(),
        date(2026, 7, 14),
        300,
        "u",
    )
    assert len(sections) > 1 and len(street) > 1
    assert all(r.name.startswith(grouped_prefixes()) for r in sections + street)
