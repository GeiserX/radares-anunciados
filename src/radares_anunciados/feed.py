"""Merge the sources into one list, keep announced streets as dormant zones, and
write it all as GeoJSON."""

from __future__ import annotations

import json
from dataclasses import replace
from datetime import date, timedelta

from .geo import distance_m
from .model import Radar, Stretch
from .sources import REGISTRY

# A mapped camera (OSM) this close to a radar an authority publishes is the same
# camera mapped twice.
DUPLICATE_M = 150

# Kinds that stand for one camera at one place. A street from a police list
# (mobile_announced), a circle of a DGT mobile-radar stretch (mobile_stretch) and a
# place where fines show a radar on some days only (mobile_recurring) are no
# camera standing there, so a mapped camera near one is no copy of it.
CAMERAS = ("fixed", "section", "trailer")


def _official(r: Radar) -> bool:
    """A camera whose position an authority publishes: its source is marked
    ``official`` in the registry and its kind is in ``CAMERAS``."""
    source = REGISTRY.get(r.source)
    return source is not None and source.official and r.kind in CAMERAS


def _mapped(r: Radar) -> bool:
    """A camera from a source the registry marks as not official (OSM)."""
    source = REGISTRY.get(r.source)
    return source is not None and not source.official


def merge(radars: list[Radar], day: date) -> list[Radar]:
    """Radars in force on ``day`` and dormant ones, active first, then by id,
    without duplicates.

    Dropped: mapped cameras that copy an official radar, a place where fines show
    a mobile radar (``mobile_recurring``) within DUPLICATE_M of a camera of another
    source, official or mapped (the camera already warns there, with its own
    limit), and any radar at exactly the spot of one already kept (the DGT lists
    both directions of a section with the same two end points). The phone watches
    only 20 zones; two at one spot waste one. A dormant circle under an active one
    gives way to it.
    """
    wanted = (r for r in radars if not r.active or r.active_on(day))
    ordered = sorted(wanted, key=lambda r: (not r.active, r.id))
    official = [r for r in ordered if _official(r)]
    cameras = [r for r in ordered if r.kind in CAMERAS]
    kept: list[Radar] = []
    spots: set[tuple[float, float]] = set()
    for r in ordered:
        spot = (round(r.lat, 5), round(r.lon, 5))
        if spot in spots:
            continue
        if _mapped(r) and any(
            distance_m((r.lat, r.lon), (o.lat, o.lon)) <= DUPLICATE_M for o in official
        ):
            continue
        if r.kind == "mobile_recurring" and any(
            c.source != r.source and distance_m((r.lat, r.lon), (c.lat, c.lon)) <= DUPLICATE_M
            for c in cameras
        ):
            continue
        spots.add(spot)
        kept.append(r)
    return kept


def remember(
    history: list[Radar], radars: list[Radar], day: date, weeks: int
) -> tuple[list[Radar], list[Radar]]:
    """(remembered radars, the new history) for the streets of periodic lists.

    ``history`` holds the circles of every street a periodic list announced
    (a radar with a ``valid_to``), keyed by source and name. A street in
    ``radars`` today replaces its entry. A street only in the history comes back
    as it was while its period lasts (its source gave nothing this run), and
    dormant once the period has ended: same name, same circles, ``active=False``.
    An entry whose period ended more than ``weeks`` weeks ago is forgotten.
    ``weeks`` <= 0 keeps nothing.
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
    remembered = [h if h.active_on(day) else replace(h, active=False) for h in old]
    return remembered, sorted(old + now, key=lambda r: r.id)


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
