"""Fixed radars of the city of Donostia / San Sebastián.

GeoDonostia publishes them as ArcGIS layer 41 "Radarra" of its transport
service: one point per radar with the street (in Basque) and the speed limit.
The service's copyright line is "© Donostiako Udala - Ayuntamiento de
Donostia / San Sebastián"; its open-data catalogue entry states no licence, so
it is reused under Ley 37/2007 on the reuse of public-sector information.
"""

from __future__ import annotations

import json

from .. import net
from ..model import Radar, SourceResult
from .base import PUBLIC_SECTOR_REUSE, Context, Source

URL = (
    "https://www.donostia.eus/geozerbitzuak/rest/services/ext/GARRAIOA/MapServer/41/query"
    "?where=1%3D1&outFields=*&outSR=4326&f=geojson"
)
ATTRIBUTION = "© Donostiako Udala - Ayuntamiento de Donostia / San Sebastián"
LICENCE = PUBLIC_SECTOR_REUSE
PROVINCE = "20"


def parse(payload: bytes) -> list[Radar]:
    radars = []
    for feature in json.loads(payload).get("features", []):
        geometry = feature.get("geometry") or {}
        if geometry.get("type") != "Point":
            continue
        lon, lat = geometry["coordinates"][:2]
        props = feature.get("properties") or {}
        street = (props.get("IzenKalea") or "").strip()
        limit = props.get("Abiadura")
        radars.append(
            Radar(
                # The layer's FID is a shapefile row number, which can shift
                # when a row goes; the position cannot.
                id=f"donostia-{lat:.5f}_{lon:.5f}",
                source="donostia",
                kind="fixed",
                name=f"Radar fijo {street}, Donostia" if street else "Radar fijo Donostia",
                lat=lat,
                lon=lon,
                radius_m=500,
                url=URL,
                attribution=ATTRIBUTION,
                maxspeed=int(limit) if limit else None,
                province=PROVINCE,
            )
        )
    return radars


def fetch(ctx: Context) -> SourceResult:
    radars = parse(net.cached_get(URL, max_age_s=ctx.max_age_s))
    if not radars:
        # The city has a dozen; none means a broken answer, which must not delete them.
        raise ValueError("donostia: the radar layer returned no point")
    return SourceResult(radars=radars)


SOURCE = Source(
    key="donostia",
    fetch=fetch,
    attribution=ATTRIBUTION,
    licence=LICENCE,
    max_age_s=86_400,
    provinces=frozenset({PROVINCE}),
)
