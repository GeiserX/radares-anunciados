import asyncio
import json
from dataclasses import replace
from datetime import date

import pytest

from radares_anunciados import ha
from radares_anunciados.model import REPORTED, Radar


def radar(name="Radar fijo A-7 km 1.0", lat=37.1, lon=-1.1, r=500):
    return Radar(id=name, source="dgt", kind="fixed", name=name, lat=lat, lon=lon, radius_m=r)


def zone(zid, name, lat, lon, radius, icon=ha.ICON):
    return {
        "id": zid,
        "name": name,
        "latitude": lat,
        "longitude": lon,
        "radius": radius,
        "passive": True,
        "icon": icon,
    }


def test_plan_creates_missing_and_deletes_stale():
    existing = [
        zone("keep", "Radar fijo A-7 km 1.0", 37.1, -1.1, 500.0),
        zone("stale", "Radar fijo A-7 km 9.0", 37.9, -1.9, 500.0),
    ]
    todo = ha.plan(existing, [radar(), radar("Radar fijo A-30 km 2.0", 37.2, -1.2)])
    assert todo.keep == 1
    assert [s.name for s in todo.create] == ["Radar fijo A-30 km 2.0"]
    assert todo.delete == ["stale"]


def test_plan_never_touches_foreign_zones():
    existing = [
        zone("home", "Home", 37.9, -1.0, 100.0, icon="mdi:home"),
        zone("work", "Radar Street Office", 37.8, -1.0, 100.0, icon="mdi:office-building"),
        zone("mine-no-prefix", "Gym", 37.7, -1.0, 100.0),  # our icon, not our name
    ]
    todo = ha.plan(existing, [])
    assert todo.delete == []


def test_plan_deletes_duplicates_of_a_kept_zone():
    existing = [
        zone("a", "Radar fijo A-7 km 1.0", 37.1, -1.1, 500.0),
        zone("b", "Radar fijo A-7 km 1.0", 37.1, -1.1, 500.0),
    ]
    todo = ha.plan(existing, [radar()])
    assert todo.keep == 1 and todo.create == [] and len(todo.delete) == 1


def test_small_radius_is_raised_to_one_region():
    # under 100 m the iOS app splits a zone into 3 regions of its 20
    todo = ha.plan([], [radar(r=40)])
    assert todo.create[0].radius == 100.0


def test_websocket_url():
    assert ha.websocket_url("https://ha.example.org/") == "wss://ha.example.org/api/websocket"
    assert ha.websocket_url("http://10.0.0.2:8123") == "ws://10.0.0.2:8123/api/websocket"


def test_plan_recreates_a_zone_edited_to_not_passive():
    # a radar zone that is not passive would set a person's state to it
    edited = zone("edited", "Radar fijo A-7 km 1.0", 37.1, -1.1, 500.0) | {"passive": False}
    todo = ha.plan([edited], [radar()])
    assert todo.delete == ["edited"] and [s.name for s in todo.create] == ["Radar fijo A-7 km 1.0"]


def test_call_gives_up_when_home_assistant_never_answers(monkeypatch):
    class Silent:  # pings for ever, never a result
        async def send(self, _):
            pass

        async def recv(self):
            await asyncio.sleep(0.01)
            return json.dumps({"type": "pong"})

    monkeypatch.setattr(ha, "CALL_TIMEOUT_S", 0.05)
    client = ha.HomeAssistant("http://ha.test", "t")
    client._ws = Silent()
    with pytest.raises(TimeoutError):
        asyncio.run(client.call("zone/list"))


def street(name="Radar anunciado Calle Mayor (Los Dolores)", lat=37.97, lon=-1.1, **kw):
    fields = {
        "id": f"murcia-{name}-{lat}",
        "source": "murcia",
        "kind": "mobile_announced",
        "name": name,
        "lat": lat,
        "lon": lon,
        "radius_m": 478,
        "valid_from": date(2026, 9, 28),
        "valid_to": date(2026, 10, 4),
    }
    return Radar(**(fields | kw))


def test_an_icon_only_change_updates_the_zone_in_place():
    # Last week's street is now dormant: same name, same circle, another icon.
    existing = [zone("z1", street().name, 37.97, -1.1, 478.0)]
    todo = ha.plan(existing, [replace(street(), active=False)])
    assert todo.update == [("z1", ha.DORMANT_ICON)]
    assert todo.create == [] and todo.delete == [] and todo.keep == 1
    assert todo.changed
    # Announced again: back to the alerting icon, same zone id.
    dormant = [zone("z1", street().name, 37.97, -1.1, 478.0, icon=ha.DORMANT_ICON)]
    todo = ha.plan(dormant, [street()])
    assert todo.update == [("z1", ha.ICON)] and todo.create == [] and todo.delete == []


def test_an_unchanged_zone_is_not_touched():
    todo = ha.plan([zone("z1", street().name, 37.97, -1.1, 478.0)], [street()])
    assert (todo.create, todo.delete, todo.update, todo.keep) == ([], [], [], 1)
    assert not todo.changed


def test_a_dormant_zone_that_ages_out_is_deleted():
    dormant = [zone("z1", street().name, 37.97, -1.1, 478.0, icon=ha.DORMANT_ICON)]
    assert ha.plan(dormant, []).delete == ["z1"]


def test_a_foreign_zone_with_the_dormant_icon_is_never_touched():
    existing = [
        zone("cam", "Cámara del garaje", 37.9, -1.0, 100.0, icon=ha.DORMANT_ICON),
        zone("off", "Oficina", 37.8, -1.0, 100.0, icon="mdi:camera-off"),
    ]
    todo = ha.plan(existing, [street()])
    assert todo.delete == [] and todo.update == []
    assert [s.name for s in todo.create] == [street().name]


def test_the_limit_goes_in_the_zone_name():
    spec = ha.ZoneSpec.from_radar(replace(radar("Radar fijo A-7 km 580.3"), maxspeed=100))
    assert spec.name == "Radar fijo A-7 km 580.3 (límite 100)"
    assert (
        ha.ZoneSpec.from_radar(radar("Radar fijo A-7 km 580.3")).name == "Radar fijo A-7 km 580.3"
    )
    tramo = replace(radar("Radar de tramo RM-1 km 2.0"), maxspeed=80)
    assert ha.ZoneSpec.from_radar(tramo).name.startswith("Radar de tramo ")
    named = ha.ZoneSpec.from_radar(replace(street(), maxspeed=40)).name
    assert named == "Radar anunciado Calle Mayor (Los Dolores) (límite 40)"


def test_over_the_cap_keeps_listed_then_nearest_fixed_then_newest_dormant():
    home = (37.98, -1.13)
    listed = [street(lat=37.97 + i / 1000) for i in range(3)]
    near = radar("Radar fijo cerca", 37.99, -1.13)
    far = radar("Radar fijo lejos", 43.0, -8.0)
    new_dormant = replace(street("Radar anunciado Nueva", 37.5, -1.0), active=False)
    old_dormant = replace(
        street("Radar anunciado Vieja", 37.6, -1.0, valid_to=date(2026, 6, 1)), active=False
    )
    radars = [far, old_dormant, near, new_dormant, *listed]
    for cap, want in [
        (3, listed),
        (4, [*listed, near]),
        (5, [*listed, near, far]),
        (6, [*listed, near, far, new_dormant]),
    ]:
        kept, left_out = ha.select(radars, cap, home)
        assert kept == want, cap
        assert left_out == len(radars) - len(want)
    assert ha.select(radars, 7, home) == (radars, 0)  # under the cap: all, untouched


def test_sync_degrades_over_the_cap_instead_of_refusing():
    many = [radar(f"Radar {i}", 37 + i / 1000, -1.0) for i in range(12)]
    fake = FakeWS(zones=[], config={"latitude": 37.0, "longitude": -1.0})
    client = ha.HomeAssistant("http://ha.test", "t")
    client._ws = fake
    todo = asyncio.run(client.sync(many, dry_run=True, max_zones=10))
    assert len(todo.create) == 10 and todo.left_out == 2
    # nearest to home first: the two farthest north are the ones left out
    assert {s.name for s in todo.create} == {f"Radar {i}" for i in range(10)}


def test_a_report_nobody_published_never_becomes_a_zone():
    """A place people report (an open OSM note) is in the feed and on the map only."""
    report = replace(radar("Nuevo radar fijo de 90kmh"), id="osm-note-1", kind=REPORTED, radius_m=0)
    fixed = [radar(f"Radar {i}", 37 + i / 1000, -1.0) for i in range(3)]
    fake = FakeWS(zones=[], config={"latitude": 37.0, "longitude": -1.0})
    client = ha.HomeAssistant("http://ha.test", "t")
    client._ws = fake
    todo = asyncio.run(client.sync([report, *fixed], dry_run=True, max_zones=3))
    # no zone, and no place under the cap taken from a radar
    assert sorted(s.name for s in todo.create) == ["Radar 0", "Radar 1", "Radar 2"]
    assert todo.left_out == 0


class FakeWS:
    """A Home Assistant websocket that answers zone/list, zone/update and get_config."""

    def __init__(self, zones, config=None):
        self.zones = zones
        self.config = config or {}
        self.sent: list[dict] = []
        self._replies: list[str] = []

    async def send(self, text):
        msg = json.loads(text)
        self.sent.append(msg)
        result = None
        if msg["type"] == "zone/list":
            result = [dict(z) for z in self.zones]
        elif msg["type"] == "get_config":
            result = self.config
        elif msg["type"] == "zone/update":
            z = next(z for z in self.zones if z["id"] == msg["zone_id"])
            z.update({k: v for k, v in msg.items() if k not in ("id", "type", "zone_id")})
            result = z
        self._replies.append(
            json.dumps({"id": msg["id"], "type": "result", "success": True, "result": result})
        )

    async def recv(self):
        return self._replies.pop(0)


def test_nudge_moves_one_zone_a_centimetre_that_the_next_plan_ignores():
    ours = zone("radar_b", street().name, 37.97, -1.1, 478.0)
    foreign = zone("a_home", "Home", 37.9, -1.0, 100.0, icon="mdi:home")
    fake = FakeWS([foreign, ours])
    client = ha.HomeAssistant("http://ha.test", "t")
    client._ws = fake
    assert asyncio.run(client.nudge()) == "radar_b"
    update = fake.sent[-1]
    assert update["type"] == "zone/update" and update["zone_id"] == "radar_b"
    assert set(update) == {"id", "type", "zone_id", "latitude"}
    assert update["latitude"] != 37.97  # a real change: Home Assistant emits state_changed
    assert abs(update["latitude"] - 37.97) < 2e-7
    todo = ha.plan(fake.zones, [street()])
    assert not todo.changed and todo.keep == 1
    # and back: repeated nudges never drift
    asyncio.run(client.nudge())
    assert fake.zones[1]["latitude"] == 37.97


def test_nudge_with_no_zone_of_ours_does_nothing():
    fake = FakeWS([zone("a_home", "Home", 37.9, -1.0, 100.0, icon="mdi:home")])
    client = ha.HomeAssistant("http://ha.test", "t")
    client._ws = fake
    assert asyncio.run(client.nudge()) is None
    assert [m["type"] for m in fake.sent] == ["zone/list"]
