"""Merge the sources into one list, keep announced streets as dormant zones, and
write it all as GeoJSON."""

from __future__ import annotations

import json
from dataclasses import replace
from datetime import date, timedelta

from .geo import distance_m
from .model import Radar, Stretch

# An OSM camera this close to a DGT radar is the same camera mapped twice.
DUPLICATE_M = 150


def merge(radars: list[Radar], day: date) -> list[Radar]:
    """Radars in force on ``day`` and dormant ones, active first, then by id,
    without duplicates.

    Dropped: OSM cameras that copy a DGT radar, and any radar at exactly the
    spot of one already kept (the DGT lists both directions of a section with
    the same two end points). The phone watches only 20 zones; two at one spot
    waste one. A dormant circle under an active one gives way to it.
    """
    wanted = (r for r in radars if not r.active or r.active_on(day))
    ordered = sorted(wanted, key=lambda r: (not r.active, r.id))
    official = [r for r in ordered if r.source == "dgt"]
    kept: list[Radar] = []
    spots: set[tuple[float, float]] = set()
    for r in ordered:
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


def remember(
    history: list[Radar], radars: list[Radar], day: date, weeks: int
) -> tuple[list[Radar], list[Radar]]:
    """(dormant radars, the new history) for the streets of periodic lists.

    ``history`` holds the circles of every street a periodic list announced
    (a radar with a ``valid_to``), keyed by source and name. A street in force
    today replaces its entry. A street in the history but not in force today is
    dormant: same name, same circles, ``active=False``. An entry whose period
    ended more than ``weeks`` weeks ago is forgotten. ``weeks`` <= 0 keeps nothing.
    """
    if weeks <= 0:
        return [], []
    now = [r for r in radars if r.active and r.valid_to is not None and r.active_on(day)]
    announced = {(r.source, r.name) for r in now}
    horizon = day - timedelta(weeks=weeks)
    old = [
        h
        for h in history
        if (h.source, h.name) not in announced and h.valid_to is not None and h.valid_to >= horizon
    ]
    dormant = [replace(h, active=False) for h in old]
    return dormant, sorted(old + now, key=lambda r: r.id)


def _common(properties: dict, item: Radar | Stretch) -> dict:
    return properties | {
        "maxspeed": item.maxspeed,
        "direction": item.direction,
        "province": item.province,
        "url": item.url,
        "attribution": item.attribution,
    }


def to_geojson(radars: list[Radar], stretches: list[Stretch] | None = None) -> str:
    features = [
        {
            "type": "Feature",
            "id": r.id,
            "geometry": {"type": "Point", "coordinates": [r.lon, r.lat]},
            "properties": _common(
                {
                    "name": r.name,
                    "source": r.source,
                    "kind": r.kind,
                    "radius_m": r.radius_m,
                    "active": r.active,
                    "valid_from": r.valid_from.isoformat() if r.valid_from else None,
                    "valid_to": r.valid_to.isoformat() if r.valid_to else None,
                },
                r,
            ),
        }
        for r in radars
    ]
    for s in stretches or []:
        points = s.line or (s.start, s.end)
        features.append(
            {
                "type": "Feature",
                "id": s.id,
                "geometry": {
                    "type": "LineString",
                    "coordinates": [[lon, lat] for lat, lon in points],
                },
                "properties": _common(
                    {
                        "name": s.name,
                        "source": s.source,
                        "kind": "stretch",
                        "road": s.road,
                        "km_from": s.km_from,
                        "km_to": s.km_to,
                        "active": True,
                    },
                    s,
                ),
            }
        )
    return json.dumps(
        {"type": "FeatureCollection", "features": features}, ensure_ascii=False, indent=1
    )
