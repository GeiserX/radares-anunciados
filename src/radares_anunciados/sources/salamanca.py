"""Salamanca city's fixed and section radars, from its open data portal.

Dataset "Radares Municipales" (``radares-fijos``) on
https://opendata.aytosalamanca.es, licence "GNU Free Documentation License" as
the dataset states it. The portal's terms add the general conditions of Ley
37/2007, art. 8: the data unaltered, the source cited and the date of the last
update given. The two layers are GeoServer WFS GeoJSON answers in WGS84, found
through the CKAN API: fixed radars as (Multi)Points with ``vmax``, sections as
LineStrings with ``VMAX`` and no name or direction. Which layer is which comes
from the geometry, not the resource name.
"""

from __future__ import annotations

import json
import logging

from .. import net
from ..model import Radar, SourceResult, Stretch
from ..provinces import PROVINCES
from .base import Context, Source

log = logging.getLogger(__name__)

PROVINCE = "37"
DATASET = "radares-fijos"
CATALOGUE = "https://opendata.aytosalamanca.es/datosabiertos/catalogo"
API = f"{CATALOGUE}/api/3/action/package_show?id={DATASET}"
ATTRIBUTION = "Ayuntamiento de Salamanca, Radares Municipales (GNU Free Documentation License)"


def geojson_resources(package: bytes) -> tuple[list[str], str | None]:
    """(GeoJSON layer URLs, last update day) from a CKAN package_show answer."""
    data = json.loads(package)
    if not data.get("success"):
        raise ValueError(f"CKAN package_show for {DATASET} did not succeed")
    result = data["result"]
    urls = [
        r["url"]
        for r in result.get("resources", [])
        if str(r.get("format", "")).lower() == "geojson"
    ]
    if not urls:
        raise ValueError(f"no GeoJSON resource in {DATASET}")
    updated = result.get("modified") or result.get("metadata_modified")
    return urls, (str(updated)[:10] if updated else None)


def _in_salamanca(lat: float, lon: float) -> bool:
    south, west, north, east = PROVINCES[PROVINCE][1]
    return south <= lat <= north and west <= lon <= east


def _limit(props: dict, key: str) -> int | None:
    """The layer's speed limit in km/h ("vmax" on points, "VMAX" on sections)."""
    value = props.get(key, props.get(key.upper()))
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def _points(geometry: dict) -> list[tuple[float, float]]:
    """(lat, lon) of a Point or MultiPoint (GeoJSON order is lon, lat)."""
    coords = geometry["coordinates"]
    if geometry["type"] == "Point":
        coords = [coords]
    return [(float(c[1]), float(c[0])) for c in coords]


def _line(geometry: dict) -> list[tuple[float, float]]:
    """(lat, lon) points of a LineString, or of a MultiLineString with one part."""
    coords = geometry["coordinates"]
    if geometry["type"] == "MultiLineString":
        if len(coords) != 1:
            raise ValueError(f"a section of {len(coords)} parts")
        coords = coords[0]
    return [(float(c[1]), float(c[0])) for c in coords]


def parse(payload: bytes, url: str, updated: str | None = None) -> SourceResult:
    """The radars of one WFS layer. A feature that can't be read is skipped and
    logged."""
    attribution = ATTRIBUTION + (f", actualizado {updated}" if updated else "")
    radars: list[Radar] = []
    stretches: list[Stretch] = []
    for feature in json.loads(payload)["features"]:
        props = feature.get("properties") or {}
        geometry = feature.get("geometry") or {}
        fid = props.get("fid")
        try:
            if not isinstance(fid, int):
                raise ValueError(f"no numeric fid ({fid!r})")
            kind = geometry.get("type")
            if kind in ("Point", "MultiPoint"):
                points = _points(geometry)
            elif kind in ("LineString", "MultiLineString"):
                points = _line(geometry)
                if len(points) < 2:
                    raise ValueError("a section with fewer than 2 points")
            else:
                raise ValueError(f"geometry {kind!r}")
            if not points or not all(_in_salamanca(*p) for p in points):
                raise ValueError(f"position {points[:1]} is outside Salamanca")
        except (ValueError, KeyError, TypeError, IndexError) as exc:
            log.warning("salamanca: feature %s skipped (%s)", feature.get("id"), exc)
            continue
        common = dict(
            source="salamanca",
            radius_m=500,
            url=url,
            attribution=attribution,
            province=PROVINCE,
        )
        if kind in ("Point", "MultiPoint"):
            place = " ".join(str(props.get("Ubicación") or "").split())
            for i, (lat, lon) in enumerate(points):
                radars.append(
                    Radar(
                        id=f"salamanca-{fid}" + (f"-{i}" if len(points) > 1 else ""),
                        kind="fixed",
                        name=f"Radar fijo {place}" if place else "Radar fijo",
                        lat=lat,
                        lon=lon,
                        maxspeed=_limit(props, "vmax"),
                        **common,
                    )
                )
            continue
        # A section: a camera at each end. The layer names no street and no
        # direction, so none is given.
        maxspeed = _limit(props, "vmax")
        for which, (lat, lon) in (("from", points[0]), ("to", points[-1])):
            radars.append(
                Radar(
                    id=f"salamanca-tramo-{fid}-{which}",
                    kind="section",
                    name="Radar de tramo",
                    lat=lat,
                    lon=lon,
                    maxspeed=maxspeed,
                    **common,
                )
            )
        stretches.append(
            Stretch(
                id=f"salamanca-tramo-{fid}",
                source="salamanca",
                name="Tramo",
                road=None,
                start=points[0],
                end=points[-1],
                line=tuple(points),
                maxspeed=maxspeed,
                province=PROVINCE,
                url=url,
                attribution=attribution,
            )
        )
    return SourceResult(radars=radars, stretches=stretches)


def fetch(ctx: Context) -> SourceResult:
    urls, updated = geojson_resources(net.cached_get(API, max_age_s=ctx.max_age_s))
    radars: list[Radar] = []
    stretches: list[Stretch] = []
    for url in urls:
        part = parse(net.cached_get(url, max_age_s=ctx.max_age_s), url, updated)
        if not part.radars:
            # An empty layer would drop every zone of the city; a layer that
            # really emptied is far less likely than a broken answer.
            raise ValueError(f"no radar could be read from {url}")
        radars += part.radars
        stretches += part.stretches
    return SourceResult(radars=radars, stretches=stretches)


SOURCE = Source(
    key="salamanca",
    fetch=fetch,
    attribution=ATTRIBUTION,
    licence=(
        "GNU Free Documentation License (as the dataset states it); the portal's terms add "
        "Ley 37/2007 art. 8: data unaltered, source cited, date of last update given"
    ),
    max_age_s=86_400,
    provinces=frozenset({PROVINCE}),
)
