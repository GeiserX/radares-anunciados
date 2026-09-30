"""Merge the sources into one list and write it as GeoJSON."""

from __future__ import annotations

import json
from datetime import date

from .geo import distance_m
from .model import Radar

# An OSM camera this close to a DGT radar is the same camera mapped twice.
DUPLICATE_M = 150


def merge(radars: list[Radar], day: date) -> list[Radar]:
    """Radars active on ``day``, sorted by id, without duplicates.

    Dropped: OSM cameras that copy a DGT radar, and any radar at exactly the
    spot of one already kept (the DGT lists both directions of a section with
    the same two end points). The phone watches only 20 zones; two at one spot
    waste one.
    """
    active = sorted((r for r in radars if r.active_on(day)), key=lambda r: r.id)
    official = [r for r in active if r.source == "dgt"]
    kept: list[Radar] = []
    spots: set[tuple[float, float]] = set()
    for r in active:
        spot = (round(r.lat, 5), round(r.lon, 5))
        if spot in spots:
            continue
        if r.source == "osm" and any(
            distance_m((r.lat, r.lon), (o.lat, o.lon)) <= DUPLICATE_M for o in official
        ):
            continue
        spots.add(spot)
        kept.append(r)
    return kept


def to_geojson(radars: list[Radar]) -> str:
    features = [
        {
            "type": "Feature",
            "id": r.id,
            "geometry": {"type": "Point", "coordinates": [r.lon, r.lat]},
            "properties": {
                "name": r.name,
                "source": r.source,
                "kind": r.kind,
                "radius_m": r.radius_m,
                "valid_from": r.valid_from.isoformat() if r.valid_from else None,
                "valid_to": r.valid_to.isoformat() if r.valid_to else None,
                "url": r.url,
                "attribution": r.attribution,
            },
        }
        for r in radars
    ]
    return json.dumps(
        {"type": "FeatureCollection", "features": features}, ensure_ascii=False, indent=1
    )
