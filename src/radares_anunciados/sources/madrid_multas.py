"""Where Madrid's mobile radars stood, from the city's traffic-fines open data.

Dataset 210104 "Multas de circulación: detalle" on https://datos.madrid.es
(CC BY 4.0, cited like ``madrid``): one CSV a month with every fine the city
processed, found through the CKAN API by its "Detalle. <mes> <año>" resource. A
speed fine names its place; a mobile radar's place is coded as a street number
and a street, such as ``N378 AV ARAGON``, with no coordinates (fixed cameras are
coded otherwise and come from ``madrid``). The data runs about seven months
behind: on 2 Oct 2026 the newest month was February 2026.

A place gets a zone when it fined in ``MIN_MONTHS`` of the last ``MONTHS``
months. It is placed on OpenStreetMap: its street is matched, by name, against
the streets mapped around Madrid, then placed at that street's house number, or
at the nearest number on the same side within ``NUMBER_GAP``, inside Madrid's
municipal border. A place that cannot be placed that way is skipped and logged,
never guessed.

Each month's file is about 60 MB. Only what a month says about these places (a
few kilobytes) is kept, under ``sources/madrid_multas/`` in the cache folder,
which the published feed keeps between runs, so a month is downloaded once and
again only when the portal replaces its file.
"""

from __future__ import annotations

import csv
import io
import json
import logging
import math
import re
import urllib.request
from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass

from .. import net
from ..geo import distance_m
from ..model import Radar, SourceResult
from ..streetnames import expand, same_words, split
from ..streets import fold
from .base import Context, Source

log = logging.getLogger(__name__)

PROVINCE = "28"
DATASET = "210104-0-multas-circulacion-detalle"
API = f"https://datos.madrid.es/api/3/action/package_show?id={DATASET}"
URL = f"https://datos.madrid.es/dataset/{DATASET}"
ATTRIBUTION = "Origen de los datos: Ayuntamiento de Madrid (CC BY 4.0)"
OVERPASS = "https://overpass-api.de/api/interpreter"
# The municipality of Madrid (OSM relation 5326784: 40.312-40.644, -3.889 to
# -3.518). (south, west, north, east)
BBOX = (40.31, -3.89, 40.645, -3.518)
MAP_AGE_S = 30 * 86_400  # street names and house numbers change slowly

# Recurrence measured over Sep 2025 to Feb 2026: 124 places coded "N", 91 of them
# in one month only, 16 in two, 9 in three, 4 in four, 2 in five and 2 in all six.
# Over the last 2 months 12 of 65 places recur, over 3 months 16 of 72, over 4
# months 20 of 84, over 6 months 33 of 124. Six months keep the most places that
# came back, at a cost of the oldest data being about 13 months old.
MONTHS = 6
MIN_MONTHS = 2

# The place field keeps 20 characters of the street ("ALCALDE SAINZ BARAND"),
# and a name cut after a space loses that space too: a street written in 19 or
# 20 characters may continue on the map ("PO GENERAL MARTINEZ" is "Paseo del
# General Martínez Campos").
CUT_AT = 19
# Street types as the file writes them; no type is a "Calle".
TYPES = {
    "AV": "Avenida",
    "CR": "Carretera",
    "CU": "Cuesta",
    "GL": "Glorieta",
    "PO": "Paseo",
    "PZ": "Plaza",
    "RD": "Ronda",
}
# Not every house number is mapped. A place whose number is not uses the
# nearest one on the same side of the street, at most this many numbers away
# (five doorways, about 50 to 150 m, well inside the zone).
NUMBER_GAP = 10
# The points one house number is mapped at (a node and a building, or a street
# that repeats in another district) more than this far apart: not one place.
SAME_PLACE_M = 200

_PLACE = re.compile(r"^N(\d{1,4})(\S*)\s+(\S.*)$")
MONTH_NAMES = (
    "enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre"
).split()


@dataclass(frozen=True)
class Month:
    year: int
    month: int
    url: str
    resource: str
    modified: str  # the resource's last change; a new one is read again

    def label(self) -> str:
        return f"{MONTH_NAMES[self.month - 1]} de {self.year}"


def months(package: bytes) -> list[Month]:
    """Every monthly "Detalle" CSV of a CKAN package_show answer, oldest first."""
    data = json.loads(package)
    if not data.get("success"):
        raise ValueError(f"CKAN package_show for {DATASET} did not succeed")
    found: dict[tuple[int, int], Month] = {}
    for r in data["result"].get("resources", []):
        desc = fold(str(r.get("description", "")))
        m = re.fullmatch(r"detalle (\w+) (\d{4})", desc)
        if not m or m.group(1) not in MONTH_NAMES or str(r.get("format", "")).upper() != "CSV":
            continue
        year, month = int(m.group(2)), MONTH_NAMES.index(m.group(1)) + 1
        modified = str(r.get("last_modified") or r.get("created") or "")
        found[year, month] = Month(year, month, r["url"], r["id"], modified)
    if not found:
        raise ValueError(f"no monthly detail CSV in {DATASET}")
    return [found[k] for k in sorted(found)]


def parse_month(lines: Iterable[str]) -> dict[str, dict]:
    """{place: {"fines": n, "limits": {limit: n}}} for the speed fines at places
    coded "N<number> <street>". Raises when the header lacks a column it needs
    or the month holds no speed fine at all (a changed file)."""
    rows = csv.reader(lines, delimiter=";")
    header = [h.strip() for h in next(rows, [])]
    needed = ("LUGAR", "VEL_LIMITE", "VEL_CIRCULA")
    if any(c not in header for c in needed):
        raise ValueError(f"fines CSV header lacks {needed}: {header}")
    where, limit, speed = (header.index(c) for c in needed)
    places: dict[str, dict] = {}
    speeding = 0
    for row in rows:
        if len(row) <= max(where, limit, speed):
            continue
        kmh, driven = row[limit].strip(), row[speed].strip()
        if not (kmh.isdigit() and driven.isdigit()):
            continue
        speeding += 1
        place = " ".join(row[where].split())
        if not _PLACE.match(place):
            continue
        entry = places.setdefault(place, {"fines": 0, "limits": {}})
        entry["fines"] += 1
        entry["limits"][kmh] = entry["limits"].get(kmh, 0) + 1
    if not speeding:
        raise ValueError("the fines CSV holds no speed fine")
    return places


def _month_path(m: Month):
    return net.cache_dir() / "sources" / "madrid_multas" / f"{m.year}-{m.month:02d}.json"


def _download(url: str) -> dict[str, dict]:
    """Read a month's CSV as it arrives: a whole file in memory is 60 MB."""
    request = urllib.request.Request(url, headers={"User-Agent": net.USER_AGENT})
    with urllib.request.urlopen(request, timeout=300) as response:
        return parse_month(io.TextIOWrapper(response, encoding="latin-1", newline=""))


def month_places(m: Month) -> dict[str, dict]:
    """A month's places, from the kept summary while the portal's file is the same."""
    path = _month_path(m)
    try:
        kept = json.loads(path.read_text("utf-8"))
        if kept.get("resource") == m.resource and kept.get("modified") == m.modified:
            return kept["places"]
    except FileNotFoundError:
        pass
    except (OSError, ValueError, KeyError) as exc:
        log.warning("ignoring a damaged summary of %s: %s", m.label(), exc)
    places = _download(m.url)
    data = {"resource": m.resource, "modified": m.modified, "places": places}
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False), "utf-8")
        tmp.replace(path)
    except OSError as exc:  # an unwritable cache must not fail a download that worked
        log.warning("could not keep the summary of %s: %s", m.label(), exc)
    return places


# ---- the map --------------------------------------------------------------


def _quote(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


# Every street name mapped in BBOX, one element per name (about 14,500, 1.3 MB).
# A smaller maxsize than Overpass's default gets a slot when it is busy.
_HEAD = "[out:json][timeout:90][maxsize:67108864][bbox:{},{},{},{}];".format(*BBOX)
NAMES_QUERY = _HEAD + 'way["highway"]["name"];for (t["name"]) { make street name=_.val; out; }'


def addresses_query(names: list[str]) -> str:
    """The house numbers mapped on these streets, and Madrid's border. An exact
    name is an index lookup; a name regex over the municipality times out."""
    wanted = "".join(f'nwr["addr:street"="{_quote(n)}"]["addr:housenumber"];' for n in names)
    border = 'relation["boundary"="administrative"]["admin_level"="8"]["name"="Madrid"];'
    return f"{_HEAD}({wanted});out center;{border}out geom;"


def written(street: str) -> tuple[str | None, tuple[str, ...]]:
    """'AV FCO J SAENZ OIZA' -> ('avenida', ('francisco', 'j', 'saenz', 'oiza'))."""
    first, _, rest = street.partition(" ")
    text = f"{TYPES[first]} {rest}" if first in TYPES and rest else f"Calle {street}"
    return split(expand(text))


def matches(street: str, names: list[str]) -> list[str]:
    """The mapped names ``street`` can be: the same words (an initial matches a
    word; a street cut at CUT_AT may continue) and the same street type. A street
    written with no type is a Calle, or a name mapped with none ("Gran Vía")."""
    kind, words = written(street)
    if not words:
        return []
    types = {kind} if street.partition(" ")[0] in TYPES else {kind, None}
    cut = len(street) >= CUT_AT
    found = set()
    for name in names:
        mapped_kind, mapped = split(name)
        if mapped_kind not in types:
            continue
        if cut and len(mapped) > len(words):
            mapped = mapped[: len(words)]
        if cut and mapped and mapped[-1].startswith(words[-1]):
            mapped = (*mapped[:-1], words[-1])
        if same_words(words, mapped):
            found.add(name)
    return sorted(found)


@dataclass(frozen=True)
class Address:
    street: str
    number: int
    point: tuple[float, float]


class AddressMap:
    """The house numbers of the queried streets that lie inside Madrid."""

    def __init__(self, overpass_json: bytes):
        elements = json.loads(overpass_json).get("elements", [])
        border = [
            ((a["lat"], a["lon"]), (b["lat"], b["lon"]))
            for e in elements
            if e["type"] == "relation"
            for m in e.get("members", [])
            if m.get("role") in ("outer", "inner") and m.get("geometry")
            for a, b in zip(m["geometry"], m["geometry"][1:], strict=False)
            if a and b
        ]
        if not border:
            raise OSError("the map of Madrid came without the municipality's border")
        self.by_street: dict[str, list[Address]] = {}
        for e in elements:
            tags = e.get("tags", {})
            point = (e["lat"], e["lon"]) if "lat" in e else e.get("center")
            if isinstance(point, dict):
                point = (point["lat"], point["lon"])
            number = re.match(r"\d+", tags.get("addr:housenumber", ""))
            if point and number and _inside(border, *point):
                street = tags["addr:street"]
                self.by_street.setdefault(street, []).append(
                    Address(street, int(number.group()), point)
                )

    def find(self, names: list[str], number: int) -> tuple[Address, ...]:
        """The mapped addresses at ``number``, or at the nearest number on the same
        side within NUMBER_GAP. () when there is none."""
        mapped = [a for n in names for a in self.by_street.get(n, [])]
        side = [a for a in mapped if a.number % 2 == number % 2]
        gaps = [abs(a.number - number) for a in side if abs(a.number - number) <= NUMBER_GAP]
        if not gaps:
            return ()
        return tuple(a for a in side if abs(a.number - number) == min(gaps))


def _inside(border, lat: float, lon: float) -> bool:
    inside = False
    for (y1, x1), (y2, x2) in border:
        if (y1 > lat) != (y2 > lat) and lon < x1 + (lat - y1) * (x2 - x1) / (y2 - y1):
            inside = not inside
    return inside


# ---- the radars -------------------------------------------------------------


@dataclass
class Placement:
    """How the recurring places of one run were placed, for the log."""

    places: int = 0  # distinct places in the window
    recurring: int = 0
    by_number: int = 0
    by_neighbour: int = 0
    skipped: list[str] | None = None


def recurring(window: list[dict[str, dict]]) -> dict[str, tuple[int, Counter]]:
    """{place: (months it fined in, fines by limit)} for the places in MIN_MONTHS."""
    seen: dict[str, tuple[int, Counter]] = {}
    for places in window:
        for place, entry in places.items():
            n, limits = seen.get(place, (0, Counter()))
            seen[place] = (n + 1, limits + Counter(entry["limits"]))
    return {p: v for p, v in seen.items() if v[0] >= MIN_MONTHS}


def to_radars(
    window: list[Month],
    places: dict[str, tuple[int, Counter]],
    names: list[str],
    addresses: AddressMap,
    stats: Placement,
    updated: str | None = None,
) -> list[Radar]:
    period = f"{window[0].label()} a {window[-1].label()}"
    attribution = (
        f"{ATTRIBUTION}, multas de circulación de {period}, lugares con multas en "
        f"{MIN_MONTHS} meses o más"
    )
    if updated:
        attribution += f", actualizado {updated}"
    attribution += "; posición © OpenStreetMap"
    stats.skipped = []
    radars: list[Radar] = []
    for place, (seen, limits) in sorted(places.items()):
        m = _PLACE.match(place)
        number, suffix, street = int(m.group(1)), m.group(2), m.group(3)
        candidates = matches(street, names)
        found = addresses.find(candidates, number) if number and not suffix else ()
        points = [a.point for a in found]
        why = ""
        if not candidates:
            why = "street not on the map"
        elif not found:
            why = f"no house number mapped within {NUMBER_GAP} of {number}{suffix}"
        elif max(distance_m(a, b) for a in points for b in points) > SAME_PLACE_M:
            why = "house number mapped at several places"
        if why:
            log.warning("madrid_multas: could not place %s (%s); skipped", place, why)
            stats.skipped.append(place)
            continue
        if found[0].number == number:
            stats.by_number += 1
        else:
            stats.by_neighbour += 1
        lat = math.fsum(p[0] for p in points) / len(points)
        lon = math.fsum(p[1] for p in points) / len(points)
        label = Counter(a.street for a in found).most_common(1)[0][0]
        limit = max(limits, key=lambda k: (limits[k], int(k)))
        radars.append(
            Radar(
                id=f"madrid_multas-{fold(place).replace(' ', '-')}",
                source="madrid_multas",
                kind="mobile_recurring",
                name=f"Radar móvil frecuente {label} {number} ({seen} meses de {len(window)})",
                lat=lat,
                lon=lon,
                radius_m=500,
                url=URL,
                attribution=attribution,
                maxspeed=int(limit),
                province=PROVINCE,
            )
        )
    return radars


def fetch(ctx: Context) -> SourceResult:
    package = net.cached_get(API, max_age_s=ctx.max_age_s)
    updated = str(json.loads(package)["result"].get("modified") or "")[:10] or None
    window = months(package)[-MONTHS:]
    month_data = [month_places(m) for m in window]
    places = recurring(month_data)
    stats = Placement(len(set().union(*month_data)), len(places))
    check = net.overpass_answer
    names_json = net.cached_get(
        OVERPASS, {"data": NAMES_QUERY}, max_age_s=MAP_AGE_S, validate=check
    )
    names = sorted({e["tags"]["name"] for e in json.loads(names_json)["elements"]})
    wanted = sorted({n for p in places for n in matches(_PLACE.match(p).group(3), names)})
    addresses = AddressMap(
        net.cached_get(
            OVERPASS, {"data": addresses_query(wanted)}, max_age_s=MAP_AGE_S, validate=check
        )
    )
    radars = to_radars(window, places, names, addresses, stats, updated)
    log.info(
        "madrid_multas: %s to %s, %d places, %d in %d months or more: %d placed by house "
        "number, %d by a neighbouring number, %d skipped",
        window[0].label(),
        window[-1].label(),
        stats.places,
        stats.recurring,
        MIN_MONTHS,
        stats.by_number,
        stats.by_neighbour,
        len(stats.skipped or []),
    )
    if not radars:
        raise ValueError("no recurring place of the Madrid fines could be placed")
    return SourceResult(radars=radars)


SOURCE = Source(
    key="madrid_multas",
    fetch=fetch,
    attribution=ATTRIBUTION + ", multas de circulación: detalle; posición © OpenStreetMap",
    licence="CC BY 4.0. Geometry: ODbL 1.0",
    max_age_s=7 * 86_400,  # a new month appears about once a month
    provinces=frozenset({PROVINCE}),
)
