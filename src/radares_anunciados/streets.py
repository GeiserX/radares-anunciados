"""Turn "street, district" pairs from a police list into circles on the map.

Two Overpass queries: first each district (a place node or a district
boundary), then, within ``NEAR_M`` of each district, every way whose name ends
like its announced street. Names are then compared on a folded key, so the press's "Avenida
Juan de Borbón" matches OSM's "Avenida Don Juan de Borbón".

Common names repeat: Murcia has a dozen "Avenida Juan Carlos I" and a "Calle
Mayor" in most districts. So only the stretch of street near the district is
kept (a ring road announced "a su paso por El Puntal" is not the whole ring
road).
"""

from __future__ import annotations

import json
import re
import unicodedata
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass

from .geo import cover, densify, distance_m
from .model import Announced, WeeklyList  # noqa: F401  (sources import them from here)

NEAR_M = 5000  # a street farther than this from its district is not it
CLIP_M = 1500  # keep the stretch up to this much farther than the nearest point

STREET_TYPES = {
    "avenida",
    "calle",
    "camino",
    "carretera",
    "carril",
    "paseo",
    "plaza",
    "ronda",
    "travesia",
    "vereda",
    "senda",
    "autovia",
    "costera",
    "glorieta",
    "rambla",
}
_LEADING = re.compile(r"^((de las|de los|de la|del|de|don|dona|la|las|los|el) )+")
_ACCENTS = {"a": "aá", "e": "eé", "i": "ií", "o": "oó", "u": "uúü", "n": "nñ"}


@dataclass(frozen=True)
class Placed:
    """An announced street on the map: circle centres, the speed limit OSM gives
    for most of the stretch (None if untagged), and the radius of the circles."""

    centres: list[tuple[float, float]]
    maxspeed: int | None
    radius_m: float


def fold(text: str) -> str:
    """Lowercase, no accents, no punctuation, single spaces."""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = re.sub(r"[^\w\s]", " ", text)
    return re.sub(r"\s+", " ", text).strip().lower()


def street_key(name: str) -> tuple[str | None, str]:
    """('avenida', 'juan de borbon') for 'Avenida Don Juan de Borbón'."""
    words = fold(name).split(" ")
    kind = words[0] if words[0] in STREET_TYPES else None
    core = " ".join(words[1:] if kind else words)
    return kind, _LEADING.sub("", core)


_PLACE_STOPWORDS = {"y", "de", "del", "la", "las", "los", "el"}


def place_words(name: str) -> frozenset[str]:
    """{'santiago', 'zaraiche'} for both 'Santiago y Zaraiche' and 'Santiago Zaraiche'."""
    return frozenset(w for w in fold(name).split(" ") if w and w not in _PLACE_STOPWORDS)


def _anchors(place: str, places: dict[str, list[tuple[float, float]]]) -> list[tuple[float, float]]:
    """Points of the district. An exact name wins; otherwise every district
    whose name holds all the announced words ('Los Martinez' finds 'Los
    Martínez del Puerto')."""
    exact = places.get(fold(place))
    if exact:
        return exact
    wanted = place_words(place)
    return [
        p for name, pts in places.items() if wanted and wanted <= place_words(name) for p in pts
    ]


def _regex(text: str) -> str:
    out = ""
    for ch in fold(text):
        out += f"[{_ACCENTS[ch]}]" if ch in _ACCENTS else (ch if ch.isalnum() or ch == " " else ".")
    return out


def places_query(items: list[Announced], bbox: tuple[float, float, float, float]) -> str:
    """Step 1: every district named in the list (cheap: few elements carry place=*)."""
    south, west, north, east = bbox
    # Loose on purpose (the district's longest word, anywhere in the name):
    # the press writes "Santiago Zaraiche" for OSM's "Santiago y Zaraiche".
    # ``_anchors`` does the exact comparison afterwards.
    words = sorted(
        {max(place_words(i.place), key=len) for i in items if i.place and place_words(i.place)}
    )
    places = "".join(
        f'node["place"]["name"~"{_regex(w)}",i];'
        f'relation["boundary"="administrative"]["name"~"{_regex(w)}",i];'
        for w in words
    )
    return f"[out:json][timeout:90][bbox:{south},{west},{north},{east}];({places});out center;"


def ways_query(
    items: list[Announced], places_json: bytes, bbox: tuple[float, float, float, float]
) -> str:
    """Step 2: each street, searched only within ``NEAR_M`` of its district.

    A name regex over every way in the municipality is what makes Overpass
    time out (504); around a few points it answers in seconds.
    """
    south, west, north, east = bbox
    places = _places(json.loads(places_json).get("elements", []))
    parts = []
    for item in items:
        name = f'"name"~"{_regex(street_key(item.street)[1])}$",i'
        if not item.place:
            parts.append(f'way["highway"][{name}]({south},{west},{north},{east});')
            continue
        for lat, lon in sorted(set(_anchors(item.place, places))):
            parts.append(f'way["highway"][{name}](around:{NEAR_M},{lat:.6f},{lon:.6f});')
    return f"[out:json][timeout:90];({''.join(parts)});out geom;"


def _places(elements: list[dict]) -> dict[str, list[tuple[float, float]]]:
    places: dict[str, list[tuple[float, float]]] = {}
    for el in elements:
        name = el.get("tags", {}).get("name", "")
        if el["type"] == "node":
            places.setdefault(fold(name), []).append((el["lat"], el["lon"]))
        elif el["type"] == "relation" and "center" in el:
            places.setdefault(fold(name), []).append((el["center"]["lat"], el["center"]["lon"]))
    return places


Line = list[tuple[float, float]]
Way = tuple[Line, int | None]  # points and the way's maxspeed


def maxspeed_kmh(tag: str | None) -> int | None:
    """km/h from an OSM ``maxspeed`` value: "50" and "50 km/h" give 50; "30 mph",
    "ES:urban", "none" and "30;50" give None (not a single limit we can trust)."""
    if not tag:
        return None
    match = re.fullmatch(r"\s*(\d{1,3})\s*(km/h|kmh|kph)?\s*", tag)
    return int(match.group(1)) if match and int(match.group(1)) > 0 else None


def _near(ways: list[Way], anchors: list[tuple[float, float]]) -> list[Way]:
    """The stretch of the street near the district, as runs of points.

    Keeps every point up to ``CLIP_M`` farther from the district than the
    street's nearest point. A same-named street in the next district may slip
    in; that costs an extra alert, while cutting a real stretch would cost a
    missed one.
    """
    if not ways or not anchors:
        return []

    def gap(p: tuple[float, float]) -> float:
        return min(distance_m(p, a) for a in anchors)

    dense = [(densify(line, 20.0), speed) for line, speed in ways]
    best = min(gap(p) for line, _ in dense for p in line)
    if best > NEAR_M:
        return []
    runs: list[Way] = []
    for line, speed in dense:
        run: Line = []
        for p in line:
            if gap(p) <= best + CLIP_M:
                run.append(p)
            elif run:
                runs.append((run, speed))
                run = []
        if run:
            runs.append((run, speed))
    return runs


def _limit(runs: list[Way]) -> int | None:
    """The limit on most of the stretch, by points (20 m apart once densified).
    A tie goes to the higher limit, which draws the larger circles."""
    weight: Counter[int] = Counter()
    for line, speed in runs:
        if speed:
            weight[speed] += len(line)
    if not weight:
        return None
    return max(weight, key=lambda s: (weight[s], s))


def place(
    items: list[Announced],
    overpass_json: bytes,
    radius_m: float | Callable[[int | None], float],
) -> dict[Announced, Placed]:
    """Each announced street on the map. ``radius_m`` is a number, or a function
    of the street's limit (None when OSM has no single limit for it). A street or
    district not found gets no centres."""
    elements = json.loads(overpass_json).get("elements", [])
    places = _places(elements)
    ways: dict[tuple[str | None, str], list[Way]] = {}
    seen: set[int] = set()
    for el in elements:
        if el["type"] == "way" and "geometry" in el and el["id"] not in seen:
            seen.add(el["id"])  # two districts' searches can return the same way
            tags = el.get("tags", {})
            line = [(g["lat"], g["lon"]) for g in el["geometry"]]
            way = (line, maxspeed_kmh(tags.get("maxspeed")))
            ways.setdefault(street_key(tags.get("name", "")), []).append(way)

    result: dict[Announced, Placed] = {}
    for item in items:
        kind, core = street_key(item.street)
        same_type = [w for (k, c), g in ways.items() if c == core and k == kind for w in g]
        any_type = [w for (k, c), g in ways.items() if c == core for w in g]
        if not item.place:
            runs = same_type or any_type
        else:
            # A district we can't find means we can't tell which of the
            # same-named streets it is: better no circle than a dozen wrong ones.
            anchors = _anchors(item.place, places)
            # The press writes "Calle Campillo" for what is mapped as "Carril
            # Campillo": fall back to any street type only if none of the stated
            # type is near the district.
            runs = _near(same_type, anchors) or _near(any_type, anchors)
        limit = _limit(runs)
        radius = radius_m(limit) if callable(radius_m) else radius_m
        result[item] = Placed(cover([line for line, _ in runs], radius), limit, radius)
    return result


def locate(
    items: list[Announced], overpass_json: bytes, radius_m: float
) -> dict[Announced, list[tuple[float, float]]]:
    """Circle centres per announced street. A street or district not found maps to []."""
    return {item: p.centres for item, p in place(items, overpass_json, radius_m).items()}
