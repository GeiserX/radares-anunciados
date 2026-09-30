"""The weekly mobile-radar list of the Policía Local de Murcia.

The police post it on X; local press repeats it as an article whose body lists
"Street, en District" lines. We read the article, pull those pairs out, and
turn each street into circles near its district (see ``streets``). The list
is valid Monday to Sunday of the week it was published.
"""

from __future__ import annotations

import html
import logging
import re
from datetime import date, timedelta

from ..model import Radar
from ..streets import STREET_TYPES, Announced, locate, query

log = logging.getLogger(__name__)

# Municipality of Murcia with a margin, (south, west, north, east)
BBOX = (37.78, -1.40, 38.10, -0.93)
ATTRIBUTION = "Policía Local de Murcia (lista semanal publicada); geometría © OpenStreetMap"

_TYPES = "|".join(sorted(STREET_TYPES | {t.capitalize() for t in STREET_TYPES}, key=len))
_PAIR = re.compile(
    rf"(?P<street>\b(?:{_TYPES}|Avda\.?|C/)\s[^,.;:\n]{{2,80}}?)\s*,\s*"
    r"(?:a su paso por|en el entorno de|en la zona de|junto a|en|de)\s+"
    r"(?:la pedanía de |el barrio de |la localidad de )?"
    r"(?P<place>[A-ZÁÉÍÓÚÑ][^,.;:\n()]{1,60}?)\s*(?=[.;,\n]|$| y )",
)


def _text(page: str) -> str:
    """Article HTML to plain text, one block per line."""
    page = re.sub(r"(?is)<(script|style|noscript)\b.*?</\1>", " ", page)
    page = re.sub(r"(?i)<\s*(br|/p|/li|/h\d|/div)\b[^>]*>", "\n", page)
    page = re.sub(r"<[^>]+>", " ", page)
    page = html.unescape(page)
    return "\n".join(re.sub(r"[ \t\xa0]+", " ", line).strip() for line in page.splitlines())


def parse_article(page: str) -> list[Announced]:
    """Every "Street, en District" pair in the article, in order, without repeats."""
    seen: list[Announced] = []
    for match in _PAIR.finditer(_text(page)):
        street = re.sub(r"^Avda\.?\s", "Avenida ", match.group("street").strip())
        street = re.sub(r"^C/\s*", "Calle ", street)
        item = Announced(street[0].upper() + street[1:], match.group("place").strip())
        if item not in seen:
            seen.append(item)
    return seen


def week_of(day: date) -> tuple[date, date]:
    monday = day - timedelta(days=day.weekday())
    return monday, monday + timedelta(days=6)


def to_radars(
    items: list[Announced],
    overpass_json: bytes,
    published: date,
    radius_m: int,
    url: str | None,
) -> list[Radar]:
    start, end = week_of(published)
    radars: list[Radar] = []
    for item, centres in locate(items, overpass_json, radius_m).items():
        if not centres:
            log.warning("could not place %s (%s) on the map; skipped", item.street, item.place)
            continue
        label = f"Radar anunciado {item.street}" + (f" ({item.place})" if item.place else "")
        slug = re.sub(r"[^a-z0-9]+", "-", f"{item.street} {item.place or ''}".lower()).strip("-")
        for n, (lat, lon) in enumerate(centres):
            radars.append(
                Radar(
                    id=f"murcia-{start.isoformat()}-{slug}-{n}",
                    source="murcia",
                    kind="mobile_announced",
                    name=label,
                    lat=lat,
                    lon=lon,
                    radius_m=radius_m,
                    valid_from=start,
                    valid_to=end,
                    url=url,
                    attribution=ATTRIBUTION,
                )
            )
    return radars


def fetch(day: date, radius_m: int = 300) -> list[Radar]:
    """This week's list, or [] if it has not been published yet."""
    from . import murcia_discovery  # the part that depends on which outlet we poll

    found = murcia_discovery.find_article(day)
    if found is None:
        log.info("no Murcia radar list found for the week of %s", week_of(day)[0])
        return []
    url, published, page = found
    items = parse_article(page)
    if not items:
        log.warning("article %s had no street list we could read", url)
        return []
    from .. import net

    overpass = net.get("https://overpass-api.de/api/interpreter", {"data": query(items, BBOX)})
    return to_radars(items, overpass, published, radius_m, url)
