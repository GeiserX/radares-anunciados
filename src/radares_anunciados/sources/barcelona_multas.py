"""Where Barcelona's speed cameras fined, from the city's traffic-fines open data.

Dataset "denuncies_sancions_transit_bcn_detall" on Open Data BCN (CC BY 4.0):
every fine the Institut Municipal d'Hisenda processed, one CSV per quarter, each
with the date and the WGS84 point of the place it names. The portal's
conditions ask for "Fuente de los datos: Ayuntamiento de Barcelona", the date of
the last update, and for any transformation to be stated: ours groups the fines
by place.

The direct CSV download sits behind a captcha; the portal's datastore SQL API
answers without one, so one query groups the newest quarter's speed fines from
cameras (``MITJA_IMPOSICIO`` "MTO", "medio técnico operativo (imágenes)") by
place and counts the days each place fined. A place that fined on most days of
the quarter is a fixed camera; one that fined on only some days is where a
mobile or temporary radar stood. The data runs about nine months behind (on
2 Oct 2026 the newest quarter was the last of 2025), so it says where radars
stand, not where one stands today.
"""

from __future__ import annotations

import json
import logging
import re
import urllib.parse
from dataclasses import dataclass
from datetime import date, timedelta

from .. import net
from ..geo import distance_m
from ..model import Radar, SourceResult
from ..provinces import PROVINCES
from ..streets import fold
from .base import Context, Source

log = logging.getLogger(__name__)

PROVINCE = "08"
PORTAL = "https://opendata-ajuntament.barcelona.cat/data"
DATASET = "denuncies_sancions_transit_bcn_detall"
API = f"{PORTAL}/api/3/action/package_show?id={DATASET}"
SQL_API = f"{PORTAL}/api/3/action/datastore_search_sql"
URL = f"{PORTAL}/es/dataset/{DATASET}"
ATTRIBUTION = "Fuente de los datos: Ayuntamiento de Barcelona (CC BY 4.0)"

# Speeding under RGC art. 50.1 and 52.1, every fine band (the portal's codes
# dataset "denuncies_sancions_transit_bcn_codis"). 1225-1227 are other offences.
SPEED_CODES = (*range(1210, 1225), *range(1228, 1233))
CAMERA = "MTO"

# Fixed or mobile, by the share of the quarter's days a place fined on. In the
# last quarter of 2025 (92 days) 52 camera places had a position: 22 fined on 50
# to 90 days (Via Augusta, Diagonal, the rondas), 25 on 2 to 43 days and 5 on a
# single day. Nothing fined on 44 to 49 days. The 41 to 43 band holds the Ronda
# del Mig cameras, which fined every day from 20 Nov on: a camera that starts or
# stops within the quarter counts as mobile until a full quarter shows it.
FIXED_SHARE = 0.5  # fined on more than this share of the days: a fixed camera
# A place that fined on one day only (5 in that quarter, 19 to 26 in each of the
# three before) is no recurring spot: it gets no zone.
MIN_DAYS = 2
# One gantry can be listed per direction a few metres apart (Ronda de Dalt 74,
# 7 m): within this distance two places are one zone, the one with more days.
SAME_SITE_M = 50


@dataclass(frozen=True)
class Quarter:
    resource: str  # datastore resource id
    year: int
    quarter: int

    @property
    def first(self) -> date:
        return date(self.year, 3 * self.quarter - 2, 1)

    @property
    def last(self) -> date:
        if self.quarter == 4:
            return date(self.year, 12, 31)
        return date(self.year, 3 * self.quarter + 1, 1) - timedelta(days=1)

    @property
    def days(self) -> int:
        return (self.last - self.first).days + 1


def newest_quarter(package: bytes) -> tuple[Quarter, str | None]:
    """The newest quarterly CSV in the datastore, and the dataset's last update day."""
    data = json.loads(package)
    if not data.get("success"):
        raise ValueError(f"CKAN package_show for {DATASET} did not succeed")
    result = data["result"]
    quarters = []
    for r in result.get("resources", []):
        m = re.match(r"(\d{4})_([1-4])t_", str(r.get("name", "")))
        if m and r.get("datastore_active") and str(r.get("format", "")).upper() == "CSV":
            quarters.append(Quarter(r["id"], int(m.group(1)), int(m.group(2))))
    if not quarters:
        raise ValueError(f"no quarterly CSV in the datastore of {DATASET}")
    updated = str(result.get("metadata_modified") or "")[:10] or None
    return max(quarters, key=lambda q: (q.year, q.quarter)), updated


def query(resource: str) -> str:
    """The SQL that groups one quarter's camera speed fines by place."""
    codes = ",".join(f"'{c}'" for c in SPEED_CODES)
    return (
        'SELECT "Nom_Carrer" street, "Num_Carrer" num, "Latitud_WGS84" lat, '
        '"Longitud_WGS84" lon, count(*) fines, count(distinct "Data_Infraccio") days '
        f'FROM "{resource}" WHERE "MITJA_IMPOSICIO" = \'{CAMERA}\' '
        f'AND "Infraccio_Codi" IN ({codes}) GROUP BY 1, 2, 3, 4 ORDER BY 1, 2'
    )


def sql_url(resource: str) -> str:
    return f"{SQL_API}?{urllib.parse.urlencode({'sql': query(resource)})}"


def _in_barcelona(lat: float, lon: float) -> bool:
    south, west, north, east = PROVINCES[PROVINCE][1]
    return south <= lat <= north and west <= lon <= east


def parse(answer: bytes, quarter: Quarter, updated: str | None = None) -> SourceResult:
    """One radar per place that fined on ``MIN_DAYS`` days or more. Raises when the
    answer is no SQL result or holds no place, so a broken answer never empties
    the feed (the registry keeps the last good result instead)."""
    data = json.loads(answer)
    if not data.get("success"):
        raise ValueError(f"datastore SQL failed: {data.get('error')}")
    records = data["result"]["records"]
    period = f"{quarter.quarter}.º trimestre de {quarter.year}"
    attribution = f"{ATTRIBUTION}, multas de tráfico del {period} agrupadas por lugar"
    if updated:
        attribution += f", actualizado {updated}"
    places: list[tuple[int, Radar]] = []
    once = unplaced = 0
    for rec in records:
        days = int(rec["days"])
        try:
            lat, lon = float(rec["lat"]), float(rec["lon"])
        except (TypeError, ValueError):
            lat = lon = None
        if lat is None or lon is None or not _in_barcelona(lat, lon):
            log.warning("barcelona_multas: place without a position skipped: %s", rec)
            unplaced += 1
            continue
        if days < MIN_DAYS:
            once += 1
            continue
        street = " ".join(str(rec["street"]).split())
        num = str(rec["num"]).strip()
        label = f"{street} {int(num)}" if num.isdigit() and int(num) else street
        fixed = days > FIXED_SHARE * quarter.days
        name = (
            f"Radar fijo {label}"
            if fixed
            else f"Radar móvil frecuente {label} ({days} días en {quarter.days})"
        )
        slug = fold(f"{street} {num}").replace(" ", "-")
        places.append(
            (
                days,
                Radar(
                    id=f"barcelona_multas-{slug}",
                    source="barcelona_multas",
                    kind="fixed" if fixed else "mobile_recurring",
                    name=name,
                    lat=lat,
                    lon=lon,
                    radius_m=500,
                    url=URL,
                    attribution=attribution,
                    province=PROVINCE,
                ),
            )
        )
    log.info(
        "barcelona_multas: %s, %d places, %d fined on one day only and %d without a "
        "position left out",
        period,
        len(places),
        once,
        unplaced,
    )
    if not places:
        raise ValueError(f"no camera place in the speed fines of the {period}")
    return SourceResult(radars=_one_per_site(places))


def _one_per_site(places: list[tuple[int, Radar]]) -> list[Radar]:
    """Places within SAME_SITE_M of one with more days give no zone of their own."""
    kept: list[Radar] = []
    for _, r in sorted(places, key=lambda p: (-p[0], p[1].id)):
        twin = next(
            (k for k in kept if distance_m((k.lat, k.lon), (r.lat, r.lon)) <= SAME_SITE_M), None
        )
        if twin is None:
            kept.append(r)
        else:
            log.info("barcelona_multas: %s is at the site of %s; one zone kept", r.id, twin.id)
    return sorted(kept, key=lambda r: r.id)


def fetch(ctx: Context) -> SourceResult:
    quarter, updated = newest_quarter(net.cached_get(API, max_age_s=ctx.max_age_s))
    answer = net.cached_get(sql_url(quarter.resource), max_age_s=ctx.max_age_s)
    return parse(answer, quarter, updated)


SOURCE = Source(
    key="barcelona_multas",
    fetch=fetch,
    attribution=ATTRIBUTION + ", detalle de las denuncias y sanciones de tráfico",
    licence="CC BY 4.0",
    max_age_s=7 * 86_400,  # a new quarter appears a few times a year
    provinces=frozenset({PROVINCE}),
)
