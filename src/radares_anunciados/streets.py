"""Turn "street, district" pairs from a police list into circles on the map.

One Overpass query fetches, inside a bounding box, every way whose name ends
like each announced street, plus each district (a place node or a district
boundary). Names are then compared on a folded key, so the press's "Avenida
Juan de Borbón" matches OSM's "Avenida Don Juan de Borbón". Only the parts of
a street within ``NEAR_M`` of its district are kept: "Avenida Juan Carlos I"
exists in a dozen districts of Murcia alone.
"""

from __future__ import annotations

import json
import re
import unicodedata
from dataclasses import dataclass

from .geo import cover, distance_m

NEAR_M = 2500

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
_LEADING = re.compile(r"^((de las|de los|de la|del|de|don|dona) )+")
_ACCENTS = {"a": "aá", "e": "eé", "i": "ií", "o": "oó", "u": "uúü", "n": "nñ"}


@dataclass(frozen=True)
class Announced:
    street: str  # "Camino de Tiñosa"
    place: str | None  # "Los Dolores"


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


def _regex(text: str) -> str:
    out = ""
    for ch in fold(text):
        out += f"[{_ACCENTS[ch]}]" if ch in _ACCENTS else (ch if ch.isalnum() or ch == " " else ".")
    return out


def query(items: list[Announced], bbox: tuple[float, float, float, float]) -> str:
    south, west, north, east = bbox
    ways = "".join(f'way["highway"]["name"~"{_regex(street_key(i.street)[1])}$",i];' for i in items)
    names = sorted({i.place for i in items if i.place})
    places = "".join(
        f'node["place"]["name"~"^{_regex(p)}$",i];'
        f'relation["boundary"="administrative"]["name"~"^{_regex(p)}$",i];'
        for p in names
    )
    return (
        f"[out:json][timeout:90][bbox:{south},{west},{north},{east}];"
        f"({ways});out geom;({places});out center;"
    )


def locate(
    items: list[Announced], overpass_json: bytes, radius_m: float
) -> dict[Announced, list[tuple[float, float]]]:
    """Circle centres per announced street. A street or district not found maps to []."""
    elements = json.loads(overpass_json).get("elements", [])
    places: dict[str, list[tuple[float, float]]] = {}
    ways: dict[tuple[str | None, str], list[list[tuple[float, float]]]] = {}
    for el in elements:
        name = el.get("tags", {}).get("name", "")
        if el["type"] == "way" and "geometry" in el:
            line = [(g["lat"], g["lon"]) for g in el["geometry"]]
            ways.setdefault(street_key(name), []).append(line)
        elif el["type"] == "node":
            places.setdefault(fold(name), []).append((el["lat"], el["lon"]))
        elif el["type"] == "relation" and "center" in el:
            places.setdefault(fold(name), []).append((el["center"]["lat"], el["center"]["lon"]))

    result: dict[Announced, list[tuple[float, float]]] = {}
    for item in items:
        kind, core = street_key(item.street)
        lines = [
            line
            for (k, c), group in ways.items()
            if c == core and (kind is None or k is None or k == kind)
            for line in group
        ]
        if item.place:
            # A district we can't find means we can't tell which of the
            # same-named streets it is: better no circle than a dozen wrong ones.
            anchors = places.get(fold(item.place), [])
            lines = [
                line
                for line in lines
                if any(distance_m(p, a) <= NEAR_M for p in line for a in anchors)
            ]
        result[item] = cover(lines, radius_m)
    return result
