"""Speed cameras mapped in OpenStreetMap (highway=speed_camera).

Data (c) OpenStreetMap contributors, ODbL 1.0. A feed that includes these
points is a derived database and must stay under ODbL.
"""

from __future__ import annotations

import json
import re

from ..model import Radar

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
ATTRIBUTION = "© OpenStreetMap contributors (ODbL 1.0)"

_ROAD_KM = re.compile(r"\b([A-Z]{1,3}-\d{1,4})\s+Km\.?\s*([\d.,]+)", re.IGNORECASE)


# Región de Murcia plus a margin, (south, west, north, east). A bounding box
# is far cheaper for Overpass than an area lookup, which 504s under load.
MURCIA_REGION = (37.37, -2.35, 38.76, -0.64)


def query(bbox: tuple[float, float, float, float]) -> str:
    """Overpass QL for every speed camera node in a bounding box."""
    south, west, north, east = bbox
    return (
        f"[out:json][timeout:60][bbox:{south},{west},{north},{east}];"
        'node["highway"="speed_camera"];'
        "out body;"
    )


def _name(tags: dict[str, str]) -> str:
    for key in ("note", "description", "name", "ref"):
        match = _ROAD_KM.search(tags.get(key, ""))
        if match:
            return f"Radar {match.group(1).upper()} km {match.group(2).replace(',', '.')}"
    if "maxspeed" in tags:
        return f"Radar (límite {tags['maxspeed']})"
    return "Radar"


def parse(payload: bytes, radius_m: int = 500) -> list[Radar]:
    data = json.loads(payload)
    return [
        Radar(
            id=f"osm-{el['id']}",
            source="osm",
            kind="fixed",
            name=_name(el.get("tags", {})),
            lat=el["lat"],
            lon=el["lon"],
            radius_m=radius_m,
            url=f"https://www.openstreetmap.org/node/{el['id']}",
            attribution=ATTRIBUTION,
        )
        for el in data.get("elements", [])
        if el.get("type") == "node"
    ]
