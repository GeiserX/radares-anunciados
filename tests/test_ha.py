import pytest

from radares_anunciados import ha
from radares_anunciados.model import Radar


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


def test_cap_refuses_a_flood():
    many = [radar(f"Radar {i}", 37 + i / 1000, -1.0) for i in range(ha.MAX_ZONES + 1)]
    with pytest.raises(ValueError):
        ha.plan([], many)


def test_websocket_url():
    assert ha.websocket_url("https://ha.example.org/") == "wss://ha.example.org/api/websocket"
    assert ha.websocket_url("http://10.0.0.2:8123") == "ws://10.0.0.2:8123/api/websocket"


def test_plan_recreates_a_zone_edited_to_not_passive():
    # a radar zone that is not passive would set a person's state to it
    edited = zone("edited", "Radar fijo A-7 km 1.0", 37.1, -1.1, 500.0) | {"passive": False}
    todo = ha.plan([edited], [radar()])
    assert todo.delete == ["edited"] and [s.name for s in todo.create] == ["Radar fijo A-7 km 1.0"]


def test_call_gives_up_when_home_assistant_never_answers(monkeypatch):
    import asyncio
    import json

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
