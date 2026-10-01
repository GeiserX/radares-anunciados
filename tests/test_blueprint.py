"""The alert blueprint: which zones count as one radar, which alert, and runs that stay short."""

import re
from collections import Counter
from datetime import date
from pathlib import Path

from radares_anunciados import ha
from radares_anunciados.sources import dgt, osm
from radares_anunciados.sources.murcia import to_radars
from radares_anunciados.streets import Announced

ROOT = Path(__file__).parents[1]
FIX = ROOT / "tests" / "fixtures"
BLUEPRINT = (ROOT / "blueprints" / "radar_zone_alert.yaml").read_text()


def grouped_prefixes() -> tuple[str, ...]:
    """The name prefixes the blueprint groups into one radar, the same in each copy of the macro."""
    found = re.findall(r"name if name\.startswith\(\(([^)]*)\)\)", BLUEPRINT)
    assert found, "the blueprint no longer limits grouping by name to known prefixes"
    copies = {tuple(re.findall(r"'([^']*)'", f)) for f in found}
    assert len(copies) == 1, f"the copies of the grouping macro disagree: {copies}"
    return copies.pop()


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


def test_only_zones_in_force_alert():
    # the icon the service gives a radar in force; dormant zones (another icon) must stay silent
    assert re.findall(r"is_state_attr\(zone, 'icon', '([^']*)'\)", BLUEPRINT) == [ha.ICON]


def test_both_apps_and_the_tracker_trigger_the_alert():
    for trigger in (
        "event_type: ios.zone_entered",
        "event_type: android.zone_entered",
        "entity_id: !input phones",
    ):
        assert trigger in BLUEPRINT


def test_runs_stay_short():
    # A run that waits holds its slot; enough waiting runs and Home Assistant drops new alerts.
    for wait in ("delay:", "wait_template:", "wait_for_trigger:"):
        assert wait not in BLUEPRINT
    # one run at a time, so an app event and a tracker update for one entry alert once
    assert re.search(r"^mode: queued$", BLUEPRINT, re.M)
