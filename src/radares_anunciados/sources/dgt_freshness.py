"""How old the DGT fixed-radar file is.

NAP says the file is updated hourly, but on 2026-10-01 its ``Last-Modified`` was
18 Dec 2025, while DGT's own PDF of 3 Aug 2026 lists more fixed radars. The data
in use can only be as fresh as the file, so each DGT fetch also asks for the
file's ``Last-Modified`` (a HEAD request) and logs its age, with a warning once it
is older than ``STALE_AFTER_S``. ``age_s`` is the value for ``/metrics``.

The PDF is not read: it has no coordinates and no open licence.
"""

from __future__ import annotations

import logging
import threading
import time
import urllib.request
from collections.abc import Callable
from dataclasses import replace
from email.utils import parsedate_to_datetime

from .. import net
from ..model import SourceResult
from . import dgt
from .base import Context, Source

log = logging.getLogger(__name__)

STALE_AFTER_S = 30 * 86_400  # a file NAP calls hourly, unchanged for a month

_lock = threading.Lock()
_last_modified: float | None = None  # the file's Last-Modified, epoch seconds


def head(url: str, timeout: int = 30) -> dict[str, str]:
    """The response headers of a HEAD request, names in lower case."""
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": net.USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return {k.lower(): v for k, v in response.headers.items()}


def parse_last_modified(value: str | None) -> float | None:
    """Epoch seconds of an HTTP date ('Thu, 18 Dec 2025 10:56:20 GMT'), or None."""
    if not value:
        return None
    try:
        return parsedate_to_datetime(value).timestamp()
    except (TypeError, ValueError):
        return None


def check(
    url: str = dgt.URL,
    now: float | None = None,
    get_headers: Callable[[str], dict[str, str]] | None = None,
) -> float | None:
    """Ask for the file's Last-Modified, remember it and log its age. Returns the
    age in seconds. Never raises: a failed check, or an answer without the
    header, keeps the last known date (None before any)."""
    global _last_modified
    now = time.time() if now is None else now
    try:
        headers = (get_headers or head)(url)
        modified = parse_last_modified(headers.get("last-modified"))
    except Exception as exc:
        log.warning("could not read Last-Modified of %s: %s", url, exc)
        return age_s(now)
    if modified is None:
        log.warning("%s sent no Last-Modified; its age is unknown", url)
        return age_s(now)
    with _lock:
        _last_modified = modified
    age = max(0.0, now - modified)
    days = age / 86_400
    day = time.strftime("%Y-%m-%d", time.gmtime(modified))
    if age > STALE_AFTER_S:
        log.warning("DGT fixed-radar file last changed %s, %.0f days ago: stale", day, days)
    else:
        log.info("DGT fixed-radar file last changed %s, %.0f days ago", day, days)
    return age


def last_modified() -> float | None:
    """The file's Last-Modified (epoch seconds) from the latest check that got one."""
    with _lock:
        return _last_modified


def age_s(now: float | None = None) -> float | None:
    """Seconds since the file last changed, by the latest check; None before any."""
    modified = last_modified()
    if modified is None:
        return None
    return max(0.0, (time.time() if now is None else now) - modified)


def watch(source: Source) -> Source:
    """``source`` with a freshness check before each fetch. The check never
    fails the fetch."""

    def fetch(ctx: Context) -> SourceResult:
        check()
        return source.fetch(ctx)

    return replace(source, fetch=fetch)
