"""The alert blueprint: which zones count as one radar, which alert, and runs that stay short."""

import ast
import re
import unicodedata
from collections import Counter
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import yaml
from jinja2.sandbox import ImmutableSandboxedEnvironment

from radares_anunciados import ha
from radares_anunciados.sources import dgt, osm
from radares_anunciados.sources.murcia import to_radars
from radares_anunciados.streets import Announced

ROOT = Path(__file__).parents[1]
FIX = ROOT / "tests" / "fixtures"
BLUEPRINT = (ROOT / "blueprints" / "radar_zone_alert.yaml").read_text()


class _Loader(yaml.SafeLoader):
    pass


_Loader.add_constructor("!input", lambda loader, node: {"!input": loader.construct_scalar(node)})
SPEC = yaml.load(BLUEPRINT, Loader=_Loader)


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
    names = [ha.ZoneSpec.from_radar(r).name for r in cameras]  # the zone name is what groups
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


def test_the_tracker_trigger_fires_on_every_update():
    # A zone that comes into force leaves `in_zones` as it was; the next location update tells.
    # `attribute:` or `to:` here would wait for `in_zones` or the state to change instead.
    (tracker,) = [t for t in SPEC["triggers"] if t.get("id") == "tracker"]
    assert tracker == {"trigger": "state", "entity_id": {"!input": "phones"}, "id": "tracker"}


def test_a_scene_reload_marks_again():
    # scene.reload deletes every scene made by scene.create, so it marks again like a restart does
    ids = {t.get("event") or t.get("event_type"): t["id"] for t in SPEC["triggers"]}
    assert ids["start"] == ids["scene_reloaded"] == "start"
    (start,) = [c for c in SPEC["actions"][0]["choose"] if c["conditions"][0].get("id") == "start"]
    assert "notify" not in str(start["sequence"])


# The decision templates rendered with plain Jinja2 and stand-ins for the Home Assistant functions
# they call. A function the stand-ins lack fails the render instead of passing silently.

NOW = datetime(2026, 10, 2, 12, 0, tzinfo=UTC)
COOLDOWN = 10
ONE, TWO = "device_tracker.one", "device_tracker.two"


def _slugify(text):
    text = unicodedata.normalize("NFKD", str(text)).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")


def _state(entity_id, age=0, /, **attributes):
    return SimpleNamespace(
        entity_id=entity_id, attributes=attributes, last_changed=NOW - timedelta(minutes=age)
    )


class Home:
    """Zones, two phones and the markers, and the template functions the blueprint calls on them."""

    def __init__(self):
        self.states = {}
        self.devices = {ONE: "device_one", TWO: "device_two"}
        for n in (1, 2, 3):
            self.zone(f"zone.calle_mayor_{n}", "Radar anunciado Calle Mayor")
        self.zone("zone.osm_1", "Radar (límite 50)")
        self.zone("zone.osm_2", "Radar (límite 50)")
        self.zone("zone.dormant", "Radar (límite 80)", "mdi:camera-off")
        self.zone("zone.tramo_a", "Radar de tramo A-7 km 10")
        self.zone("zone.tramo_b", "Radar de tramo A-7 km 10")
        self.zone("zone.home", "Home", "mdi:home")
        for tracker in self.devices:
            self.states[tracker] = _state(tracker, in_zones=[])

    def zone(self, entity_id, name, icon=ha.ICON):
        self.states[entity_id] = _state(entity_id, friendly_name=name, icon=icon)

    def mark(self, radar, age=0):
        """The scene the blueprint creates for a radar it alerted for."""
        scene = f"scene.{radar['marker']}"
        self.states[scene] = _state(scene, age, entity_id=[radar["tracker"], radar["zone"]])

    def render(self, template, trigger, **variables):
        states = self.states

        class States:
            def __getattr__(self, domain):
                return [s for e, s in sorted(states.items()) if e.startswith(domain + ".")]

            def __getitem__(self, entity_id):
                return states.get(entity_id)

        def state_attr(entity_id, name):
            return states[entity_id].attributes.get(name) if entity_id in states else None

        env = ImmutableSandboxedEnvironment()
        env.filters["slugify"] = _slugify
        env.globals.update(
            states=States(),
            state_attr=state_attr,
            is_state_attr=lambda entity_id, name, value: state_attr(entity_id, name) == value,
            device_id=self.devices.get,
            now=lambda: NOW,
            timedelta=timedelta,
        )
        out = env.from_string(template).render(trigger=trigger, cooldown=COOLDOWN, **variables)
        # Home Assistant turns a rendered variable that reads as a Python literal into that value
        return ast.literal_eval(out)

    def radars(self, trigger):
        """The `radars` variable: what to alert for (or, on start, to mark)."""
        phones = list(self.devices)
        return self.render(SPEC["variables"]["radars"], trigger, phones=phones, sender="")

    def moved(self, tracker, was_in, now_in):
        """`radars` for a tracker update from `was_in` to `now_in`."""
        before = _state(tracker, in_zones=was_in)
        self.states[tracker] = _state(tracker, in_zones=now_in)
        trigger = {"id": "tracker", "entity_id": tracker}
        return self.radars(dict(trigger, from_state=before, to_state=self.states[tracker]))


def alerted(radars):
    return [(r["tracker"], r["zone"]) for r in radars]


def test_a_first_entry_alerts_once_per_radar():
    got = Home().moved(
        ONE, [], ["zone.calle_mayor_1", "zone.calle_mayor_2", "zone.osm_1", "zone.osm_2"]
    )
    # two circles of one street alert once; two cameras that share a name alert each
    assert alerted(got) == [(ONE, "zone.calle_mayor_1"), (ONE, "zone.osm_1"), (ONE, "zone.osm_2")]


def test_zones_not_in_force_and_other_zones_never_alert():
    assert Home().moved(ONE, [], ["zone.dormant", "zone.home"]) == []


def test_a_zone_that_comes_into_force_while_inside_alerts_at_the_next_update():
    home = Home()
    assert home.moved(ONE, [], ["zone.dormant"]) == []
    home.zone("zone.dormant", "Radar (límite 80)")
    assert alerted(home.moved(ONE, ["zone.dormant"], ["zone.dormant"])) == [(ONE, "zone.dormant")]


def test_a_marker_holds_back_that_radar_for_that_phone_only():
    home = Home()
    (street,) = home.moved(ONE, [], ["zone.calle_mayor_1"])
    home.mark(street)
    # the next circle of the street
    assert home.moved(ONE, ["zone.calle_mayor_1"], ["zone.calle_mayor_2"]) == []
    # the second of an app event and a tracker update for one entry, or a repeated app event
    assert home.moved(ONE, [], ["zone.calle_mayor_1"]) == []
    # the other phone, same radar
    assert alerted(home.moved(TWO, [], ["zone.calle_mayor_2"])) == [(TWO, "zone.calle_mayor_2")]


def test_a_new_entry_alerts_again_only_after_the_cooldown():
    home = Home()
    (end_a,) = home.moved(ONE, [], ["zone.tramo_a"])
    # the other end of the section, with no radar zone in between
    home.mark(end_a, age=COOLDOWN - 1)
    assert home.moved(ONE, [], ["zone.tramo_b"]) == []
    home.mark(end_a, age=COOLDOWN)
    assert alerted(home.moved(ONE, [], ["zone.tramo_b"])) == [(ONE, "zone.tramo_b")]
    # staying inside is no new entry, however old the marker
    assert home.moved(ONE, ["zone.tramo_b"], ["zone.tramo_b"]) == []


def test_on_start_every_radar_a_phone_is_in_is_marked():
    home = Home()
    home.states[ONE] = _state(ONE, in_zones=["zone.calle_mayor_1", "zone.calle_mayor_2"])
    home.states[TWO] = _state(TWO, in_zones=["zone.dormant"])
    marks = home.radars({"id": "start"})
    assert alerted(marks) == [(ONE, "zone.calle_mayor_1")]
    for radar in marks:
        home.mark(radar)
    assert home.moved(ONE, ["zone.calle_mayor_2"], ["zone.calle_mayor_3"]) == []


def test_a_queued_run_skips_what_an_earlier_run_marked():
    home = Home()
    todo = SPEC["actions"][0]["default"][0]["variables"]["todo"]
    radars = home.moved(ONE, [], ["zone.osm_1"])
    assert home.render(todo, {"id": "tracker"}, radars=radars) == radars
    # the app event's run, queued before this one, alerted and marked
    home.mark(radars[0])
    assert home.render(todo, {"id": "tracker"}, radars=radars) == []
