"""Speed cameras mapped in OpenStreetMap: ``highway=speed_camera`` nodes and the
``type=enforcement`` relations around them.

An enforcement relation (https://wiki.openstreetmap.org/wiki/Relation:enforcement)
ties a ``device`` (the camera) to a ``from`` node on the road where the control
starts and, optionally, a ``to`` node where it ends; without a ``to``, the
device is the end. Two kinds are read, ``enforcement=maxspeed`` and
``average_speed``:

- ``maxspeed``: the camera gets the relation's limit and the bearing from
  ``from`` to the end as its direction, unless the node has its own tags. A
  camera whose relations disagree gets neither: a wrong one is worse than none.
- ``average_speed``: a section, drawn as its two ends (kind ``section``, both
  named ``Radar de tramo …``) and a line between them. A camera of the
  relation within ``END_M`` of its ``from`` or ``to`` node is that end: the end
  goes where the camera is, which is what an authority publishes, and the
  camera is not added again. An end with no camera goes on the node. A section
  with more than one ``from`` or ``to`` says no single start and end; its
  cameras stay plain ones.
- A ``device`` node tagged as no ``highway`` at all (a bare node, a
  ``man_made=surveillance``) is a camera too; one tagged as something else
  (``highway=speed_display``) is not.

Data (c) OpenStreetMap contributors, ODbL 1.0. A feed that includes these
points is a derived database and must stay under ODbL.
"""

from __future__ import annotations

import json
import re

from .. import net
from ..geo import bearing_deg, distance_m
from ..model import Radar, SourceResult, Stretch
from ..provinces import Box
from ..streets import maxspeed_kmh
from .base import Context, Source

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
ATTRIBUTION = "© OpenStreetMap contributors (ODbL 1.0)"
ENFORCEMENT = ("maxspeed", "average_speed")
END_M = 150  # a section's camera this close to one of its ends is that end
MIN_SPAN_M = 5  # closer than this, two nodes give no direction

_ROAD_KM = re.compile(r"\b([A-Z]{1,3}-\d{1,4})\s+Km\.?\s*([\d.,]+)", re.IGNORECASE)


# Región de Murcia plus a margin, (south, west, north, east). A bounding box
# is far cheaper for Overpass than an area lookup, which 504s under load.
MURCIA_REGION = (37.37, -2.35, 38.76, -0.64)


def query(bbox: Box) -> str:
    """Overpass QL for the speed cameras and enforcement relations in a bounding box."""
    return query_boxes([bbox])


def query_boxes(boxes: list[Box] | tuple[Box, ...]) -> str:
    """One query over several boxes (all of Spain is 52 province boxes): every
    camera node, every enforcement relation with a member in a box, and the
    member nodes of those relations, which carry the positions."""
    cameras = "".join(f'node["highway"="speed_camera"]({s},{w},{n},{e});' for s, w, n, e in boxes)
    kinds = "|".join(ENFORCEMENT)
    relations = "".join(
        f'relation["type"="enforcement"]["enforcement"~"^({kinds})$"]({s},{w},{n},{e});'
        for s, w, n, e in boxes
    )
    return (
        f"[out:json][timeout:180];({cameras})->.c;({relations})->.r;"
        "node(r.r)->.m;(.c;.m;);out body;.r out body;"
    )


def _road_km(tags: dict[str, str]) -> str | None:
    for key in ("note", "description", "name", "ref"):
        match = _ROAD_KM.search(tags.get(key, ""))
        if match:
            return f"{match.group(1).upper()} km {match.group(2).replace(',', '.')}"
    return None


def _name(tags: dict[str, str]) -> str:
    road_km = _road_km(tags)
    # the zone name adds the limit when the camera has one
    return f"Radar {road_km}" if road_km else "Radar"


def _point(node: dict) -> tuple[float, float]:
    return node["lat"], node["lon"]


def _roles(relation: dict, nodes: dict[int, dict]) -> dict[str, list[dict]]:
    """The relation's member nodes by role, those in the answer only."""
    out: dict[str, list[dict]] = {"device": [], "from": [], "to": []}
    for m in relation.get("members", []):
        if m.get("type") == "node" and m.get("role") in out and m.get("ref") in nodes:
            out[m["role"]].append(nodes[m["ref"]])
    return out


def _end(node: dict, devices: list[dict]) -> tuple[float, float]:
    """Where a section end goes: the relation's camera at that end, the position an
    authority publishes too, or without one the node on the road."""
    camera = min(devices, key=lambda d: distance_m(_point(d), _point(node)), default=None)
    if camera is not None and distance_m(_point(camera), _point(node)) <= END_M:
        return _point(camera)
    return _point(node)


def _direction(start: dict, end: dict) -> str | None:
    if distance_m(_point(start), _point(end)) < MIN_SPAN_M:
        return None
    return str(bearing_deg(_point(start), _point(end)))


def _agreed(values: list) -> object | None:
    """The one value every relation gives, or None when they differ or give none."""
    found = {v for v in values if v is not None}
    return found.pop() if len(found) == 1 else None


def parse_all(payload: bytes, radius_m: int = 500) -> SourceResult:
    data = json.loads(payload)
    elements = data.get("elements", [])
    nodes = {el["id"]: el for el in elements if el.get("type") == "node"}
    relations = sorted(
        (
            el
            for el in elements
            if el.get("type") == "relation" and el.get("tags", {}).get("enforcement") in ENFORCEMENT
        ),
        key=lambda el: el["id"],
    )
    cameras = {i: n for i, n in nodes.items() if n.get("tags", {}).get("highway") == "speed_camera"}
    directions: dict[int, list[str | None]] = {}
    limits: dict[int, list[int | None]] = {}
    radars: list[Radar] = []
    stretches: list[Stretch] = []
    ends_of: set[int] = set()  # cameras that are the end of a section
    for rel in relations:
        tags = rel.get("tags", {})
        roles = _roles(rel, nodes)
        for device in roles["device"]:
            if "highway" not in device.get("tags", {}):
                cameras.setdefault(device["id"], device)
        limit = maxspeed_kmh(tags.get("maxspeed"))
        starts, ends = roles["from"], roles["to"]
        if tags["enforcement"] == "maxspeed":
            for device in roles["device"]:
                direction = None
                if len(starts) == 1 and len(ends) <= 1:
                    direction = _direction(starts[0], ends[0] if ends else device)
                directions.setdefault(device["id"], []).append(direction)
                limits.setdefault(device["id"], []).append(limit)
            continue
        ends = ends or roles["device"]  # without a "to", the camera is the end
        if len(starts) != 1 or len(ends) != 1:
            continue  # no single start and end
        start, end = _end(starts[0], roles["device"]), _end(ends[0], roles["device"])
        if start == end:
            start, end = _point(starts[0]), _point(ends[0])
        # A name of its own: the blueprint alerts once per name, so two sections
        # both called "Radar de tramo" would alert only for the first.
        found = [_road_km(n.get("tags", {})) for n in [rel, *roles["device"]]]
        label = next((x for x in found if x), f"(OSM {rel['id']})")
        url = f"https://www.openstreetmap.org/relation/{rel['id']}"
        direction = _direction(starts[0], ends[0])
        for which, (lat, lon) in (("from", start), ("to", end)):
            radars.append(
                Radar(
                    id=f"osm-relation-{rel['id']}-{which}",
                    source="osm",
                    kind="section",
                    name=f"Radar de tramo {label}",
                    lat=lat,
                    lon=lon,
                    radius_m=radius_m,
                    url=url,
                    attribution=ATTRIBUTION,
                    maxspeed=limit,
                    direction=direction,
                )
            )
        stretches.append(
            Stretch(
                id=f"osm-relation-{rel['id']}",
                source="osm",
                name=f"Tramo {label}",
                road=None,
                start=start,
                end=end,
                maxspeed=limit,
                direction=direction,
                url=url,
                attribution=ATTRIBUTION,
            )
        )
        for device in roles["device"]:
            if min(distance_m(_point(device), _point(n)) for n in (starts[0], ends[0])) <= END_M:
                ends_of.add(device["id"])
    for i, node in sorted(cameras.items()):
        if i in ends_of:
            continue
        tags = node.get("tags", {})
        radars.append(
            Radar(
                id=f"osm-{i}",
                source="osm",
                kind="fixed",
                name=_name(tags),
                lat=node["lat"],
                lon=node["lon"],
                radius_m=radius_m,
                url=f"https://www.openstreetmap.org/node/{i}",
                attribution=ATTRIBUTION,
                maxspeed=maxspeed_kmh(tags.get("maxspeed")) or _agreed(limits.get(i, [])),
                direction=tags.get("direction") or _agreed(directions.get(i, [])),
            )
        )
    return SourceResult(radars=radars, stretches=stretches)


def parse(payload: bytes, radius_m: int = 500) -> list[Radar]:
    return parse_all(payload, radius_m).radars


def fetch(ctx: Context) -> SourceResult:
    payload = net.cached_get(
        OVERPASS_URL,
        {"data": query_boxes(ctx.boxes)},
        max_age_s=ctx.max_age_s,
        validate=net.overpass_answer,
    )
    return parse_all(payload)


SOURCE = Source(
    key="osm",
    fetch=fetch,
    attribution=ATTRIBUTION,
    licence="ODbL 1.0",
    max_age_s=86_400,
    official=False,
)
