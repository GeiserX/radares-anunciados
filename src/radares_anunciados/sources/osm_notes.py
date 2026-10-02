"""Open OpenStreetMap notes in which someone reports a speed camera.

A note is a message anyone can pin on the map, often a camera nobody has
mapped yet ("Nuevo radar fijo de 90kmh ambos sentidos"). It is unconfirmed: no
authority published it and no mapper has checked it. So each one has kind
``REPORTED``: it is in the feed and on the map with its link, date and text,
but never a zone (``ha.zoned``), and it never drops or replaces another radar
(``feed.merge``). A note closed on OpenStreetMap leaves with the next download.

Off by default (``Source.default``): notes are served by OpenStreetMap's
editing API, whose usage policy rules out read-only projects, so the published
feed is the one reader (``RADARES_SOURCES=default,osm_notes``). One request per
run: an open-note search for "radar" over the whole world (225 notes, 232 KB,
on 2 Oct 2026). The notes API refuses a box over 25 square degrees, so Spain
alone would take 7. The province boxes then keep Spain's, ``in_spain`` drops
Andorra's and France's that the Catalan boxes take in, and ``about_speed``
drops notes about red-light cameras and other "radars".

Data (c) OpenStreetMap contributors, ODbL 1.0.
"""

from __future__ import annotations

import json
import logging
import re
import urllib.parse
from datetime import date

from .. import net
from ..model import REPORTED, Radar, SourceResult
from ..provinces import PROVINCES, Box
from . import catalonia_shapes
from .base import Context, Source

log = logging.getLogger(__name__)

URL = "https://api.openstreetmap.org/api/0.6/notes/search.json?" + urllib.parse.urlencode(
    {"q": "radar", "closed": "0", "limit": "10000"}  # closed=0: open notes only
)
ATTRIBUTION = "© OpenStreetMap contributors (ODbL 1.0)"
MAX_TEXT = 200

_SPEED = re.compile(r"radar|cinem[oó]metr", re.IGNORECASE)
# A note that is no report of a speed camera: a red-light camera, a camera
# that is gone, a radar station or antenna, a speed display ("radar
# pédagogique"), a "RADAR key" toilet, an app's automatic note, or anything a
# radar detector found (the project never uses that, see AGENTS.md).
_OTHER = re.compile(
    r"foto\s*-?\s*rojo|fotomulta|sem[aà]f[oò]r|feu\s+(rouge|tricolore)|red[\s-]*light"
    r"|ya no|no hay radar|no est[aá] (m[aá]s )?el radar|pas de radar|retirad|removed"
    r"|gone or never existed"
    r"|militar|military|nato\b|estaci[oó]n|station|antena|antenna|aeron|aviation|meteo|weather"
    r"|p[eé]dagogique|\bkey\b|toilet|weed\s+radar|detector",
    re.IGNORECASE,
)


# The boxes of the Catalan provinces take in Andorra and a strip of France.
_CATALAN_BOXES = {PROVINCES[code][1] for code in catalonia_shapes.RINGS}


def in_spain(lat: float, lon: float) -> bool:
    """Inside a province box and, where only Catalan boxes reach, inside
    Catalonia's outline. Elsewhere the boxes are all there is: a note just across
    the border with Portugal, or with France west of Catalonia, stays in."""
    boxes = [b for _, b in PROVINCES.values() if b[0] <= lat <= b[2] and b[1] <= lon <= b[3]]
    if not boxes:
        return False
    return not all(b in _CATALAN_BOXES for b in boxes) or catalonia_shapes.inside(lat, lon)


def about_speed(text: str) -> bool:
    """True when a note's opening text reports a speed camera."""
    return bool(_SPEED.search(text)) and not _OTHER.search(text)


def answer(body: bytes) -> None:
    """Raise ValueError unless ``body`` is a notes search answer."""
    try:
        data = json.loads(body)
    except ValueError as exc:
        raise ValueError(f"the notes API answered with no JSON: {body[:80]!r}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("features"), list):
        raise ValueError(f"the notes API answered with no notes: {body[:80]!r}")


def _trim(text: str) -> str:
    text = " ".join(text.split())
    return text if len(text) <= MAX_TEXT else text[: MAX_TEXT - 1].rstrip() + "…"


def parse(payload: bytes, boxes: list[Box] | tuple[Box, ...]) -> list[Radar]:
    """The open notes inside ``boxes`` whose opening text reports a speed camera.
    A note the API answers in another shape is skipped and logged: one odd note
    must not hold back the others, nor keep a closed one in the feed."""
    radars = []
    for feature in json.loads(payload)["features"]:
        try:
            note = _note(feature, boxes)
        except (KeyError, TypeError, ValueError) as exc:
            log.warning("OSM note skipped, not in the shape expected (%r): %s", exc, feature)
            continue
        if note is not None:
            radars.append(note)
    return radars


def _note(feature: dict, boxes: list[Box] | tuple[Box, ...]) -> Radar | None:
    p = feature["properties"]
    lon, lat = (float(x) for x in feature["geometry"]["coordinates"])
    opened = next((c for c in p.get("comments", []) if c.get("action") == "opened"), None)
    if p.get("status") != "open" or opened is None or not about_speed(opened["text"]):
        return None
    if not any(s <= lat <= n and w <= lon <= e for s, w, n, e in boxes) or not in_spain(lat, lon):
        return None
    return Radar(
        id=f"osm-note-{int(p['id'])}",
        source="osm_notes",
        kind=REPORTED,
        name=_trim(opened["text"]),
        lat=lat,
        lon=lon,
        radius_m=0,
        url=f"https://www.openstreetmap.org/note/{int(p['id'])}",
        attribution=ATTRIBUTION,
        reported=date.fromisoformat(p["date_created"][:10]),
    )


def fetch(ctx: Context) -> SourceResult:
    payload = net.cached_get(URL, max_age_s=ctx.max_age_s, validate=answer)
    return SourceResult(radars=parse(payload, ctx.boxes))


SOURCE = Source(
    key="osm_notes",
    fetch=fetch,
    attribution=ATTRIBUTION,
    licence="ODbL 1.0",
    max_age_s=86_400,
    official=False,
    # Notes never become zones, so an install gains nothing from them, and the
    # notes API is OSM's editing API: only the published feed reads them.
    default=False,
)
