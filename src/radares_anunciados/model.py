"""The one record every source produces."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True)
class Radar:
    """A place where a speed control is published, drawn as one circle.

    A fixed radar is one circle. A street from a weekly police list is several
    circles along the street, each its own Radar with the same ``name``.
    """

    id: str  # stable across runs: source + source id (+ circle index)
    source: str  # "dgt", "osm", "murcia"
    kind: str  # "fixed", "section", "mobile_announced"
    name: str  # what the driver reads in the alert
    lat: float
    lon: float
    radius_m: int
    valid_from: date | None = None  # None = always
    valid_to: date | None = None
    url: str | None = None  # where the position was published
    attribution: str = ""

    def active_on(self, day: date) -> bool:
        if self.valid_from and day < self.valid_from:
            return False
        if self.valid_to and day > self.valid_to:
            return False
        return True
