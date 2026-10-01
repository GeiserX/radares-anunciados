"""The contract every source module fulfils.

A source module exposes ``SOURCE = Source(...)`` and is listed once in
``sources/__init__.py``. Its ``fetch`` gets a ``Context`` and returns one
``SourceResult``; it raises on any failure. Raising is safe: the registry then
uses the source's last good result, so a source that is down never costs its
zones. Returning an empty result is not safe in the same way: it is taken as
"nothing published", and the zones go.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import date

from ..model import SourceResult
from ..provinces import Box
from ..speed import Radius


@dataclass(frozen=True)
class Context:
    """What a fetch may depend on. A fetch reads nothing else from the environment."""

    day: date
    provinces: frozenset[str] | None  # INE codes; None = all of Spain
    boxes: tuple[Box, ...]  # (south, west, north, east) areas to search by bounding box
    radius: Radius  # use radius.street_m(limit) for the circles along an announced street
    max_age_s: int = 86_400  # the source's own cache age, from its Source entry


@dataclass(frozen=True)
class Source:
    key: str  # "dgt"; the RADARES_SOURCES name, the metrics label, the cache file name
    fetch: Callable[[Context], SourceResult]
    attribution: str
    licence: str
    spanish_ip: bool = False  # the publisher answers only from a Spanish IP
    max_age_s: int = 86_400  # how long a download stays fresh in the cache
    # The provinces it covers (a city's list: its province). None: any. A source
    # is skipped when none of its provinces is selected.
    provinces: frozenset[str] | None = None
    # True: an authority publishes these positions. False: a crowd-sourced map
    # (OSM), whose camera within feed.DUPLICATE_M of an official radar is a copy.
    official: bool = True
