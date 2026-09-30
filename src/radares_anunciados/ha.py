"""Keep Home Assistant zones equal to the radar list.

Every radar becomes a *passive* zone: the iOS companion app monitors it and
fires ``ios.zone_entered``, but a person inside it stays ``not_home`` instead of
taking the zone's name, so existing presence automations don't change.

The iOS app monitors at most 20 regions and itself keeps the 20 zones nearest
to its last location, re-choosing on every location event
(``ZoneManagerRegionFilter`` in home-assistant/iOS). So we load every radar and
let the phone pick. Zones under 100 m radius cost the app three regions each,
so radii here are never below 100 m.

The app only downloads changed zones while it is open on screen, so after a
change we send a notification: tapping it opens the app and loads the new zones.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from itertools import count

import websockets

from .model import Radar

log = logging.getLogger(__name__)

# A zone is ours only if it has this icon AND its name starts with "Radar".
# Nothing else is ever updated or deleted.
ICON = "mdi:camera-timer"
MIN_RADIUS_M = 100
MAX_ZONES = 400  # a parser gone wrong must not flood Home Assistant


@dataclass(frozen=True)
class ZoneSpec:
    name: str
    latitude: float
    longitude: float
    radius: float

    @classmethod
    def from_radar(cls, r: Radar) -> ZoneSpec:
        return cls(r.name, round(r.lat, 6), round(r.lon, 6), float(max(r.radius_m, MIN_RADIUS_M)))

    @classmethod
    def from_zone(cls, z: dict) -> ZoneSpec:
        return cls(z["name"], round(z["latitude"], 6), round(z["longitude"], 6), float(z["radius"]))


def is_ours(zone: dict) -> bool:
    return zone.get("icon") == ICON and str(zone.get("name", "")).startswith("Radar")


@dataclass
class Plan:
    create: list[ZoneSpec]
    delete: list[str]  # zone ids
    keep: int


def plan(existing: list[dict], radars: list[Radar]) -> Plan:
    wanted = {ZoneSpec.from_radar(r) for r in radars}
    if len(wanted) > MAX_ZONES:
        raise ValueError(f"{len(wanted)} zones is over the {MAX_ZONES} cap; refusing to sync")
    have: dict[ZoneSpec, str] = {}
    delete: list[str] = []
    for z in existing:
        if not is_ours(z):
            continue
        spec = ZoneSpec.from_zone(z)
        if spec in wanted and spec not in have:
            have[spec] = z["id"]
        else:
            delete.append(z["id"])  # stale, or a duplicate of one we keep
    create = sorted(wanted - have.keys(), key=lambda s: (s.name, s.latitude, s.longitude))
    return Plan(create=create, delete=sorted(delete), keep=len(have))


def websocket_url(base_url: str) -> str:
    base = base_url.rstrip("/")
    if base.startswith("https://"):
        return "wss://" + base.removeprefix("https://") + "/api/websocket"
    if base.startswith("http://"):
        return "ws://" + base.removeprefix("http://") + "/api/websocket"
    return base


class HomeAssistant:
    def __init__(self, base_url: str, token: str):
        self.url = websocket_url(base_url)
        self.token = token
        self._ids = count(1)
        self._ws = None

    async def __aenter__(self) -> HomeAssistant:
        self._ws = await websockets.connect(self.url, max_size=16 * 1024 * 1024)
        hello = json.loads(await self._ws.recv())
        if hello.get("type") != "auth_required":
            raise RuntimeError(f"unexpected hello from Home Assistant: {hello}")
        await self._ws.send(json.dumps({"type": "auth", "access_token": self.token}))
        auth = json.loads(await self._ws.recv())
        if auth.get("type") != "auth_ok":
            raise RuntimeError(f"Home Assistant refused the token: {auth.get('message', auth)}")
        return self

    async def __aexit__(self, *exc) -> None:
        await self._ws.close()

    async def call(self, msg_type: str, **payload) -> object:
        msg_id = next(self._ids)
        await self._ws.send(json.dumps({"id": msg_id, "type": msg_type, **payload}))
        while True:
            reply = json.loads(await self._ws.recv())
            if reply.get("id") != msg_id or reply.get("type") != "result":
                continue
            if not reply.get("success"):
                raise RuntimeError(f"{msg_type} failed: {reply.get('error')}")
            return reply.get("result")

    async def sync(self, radars: list[Radar], dry_run: bool = False) -> Plan:
        existing = await self.call("zone/list")
        todo = plan(existing, radars)
        log.info(
            "zones: %d kept, %d to create, %d to delete",
            todo.keep,
            len(todo.create),
            len(todo.delete),
        )
        if dry_run:
            return todo
        for zone_id in todo.delete:
            await self.call("zone/delete", zone_id=zone_id)
        for spec in todo.create:
            await self.call(
                "zone/create",
                name=spec.name,
                latitude=spec.latitude,
                longitude=spec.longitude,
                radius=spec.radius,
                passive=True,
                icon=ICON,
            )
        return todo

    async def notify(self, targets: list[str], title: str, message: str) -> None:
        for target in targets:
            service = target.removeprefix("notify.")
            await self.call(
                "call_service",
                domain="notify",
                service=service,
                service_data={"title": title, "message": message},
            )
