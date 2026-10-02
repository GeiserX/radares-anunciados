"""HTTP with a real User-Agent and a couple of retries (Overpass 504s under load)."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
import urllib.parse
import urllib.request
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path

log = logging.getLogger(__name__)

USER_AGENT = "radares-anunciados (+https://github.com/GeiserX/radares-anunciados)"

# Set by ``fail_fast``: every request gets one try and at most this many seconds.
_cap: ContextVar[int | None] = ContextVar("timeout_cap", default=None)


@contextmanager
def fail_fast(seconds: int | None) -> Iterator[None]:
    """Within the block, one try per request and a timeout of at most ``seconds``
    (None: no change). A source that answers only Spanish addresses runs in it on a
    runner outside Spain, where it would time out three times per request."""
    token = _cap.set(seconds)
    try:
        yield
    finally:
        _cap.reset(token)


def timeout_s(default: int) -> int:
    """``default``, or the ``fail_fast`` cap when that is lower."""
    cap = _cap.get()
    return default if cap is None else min(default, cap)


def get(
    url: str,
    data: dict[str, str] | None = None,
    headers: dict[str, str] | None = None,
    timeout: int = 90,
    tries: int = 3,
) -> bytes:
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    if _cap.get() is not None:
        timeout, tries = timeout_s(timeout), 1
    for attempt in range(1, tries + 1):
        request = urllib.request.Request(
            url, data=body, headers={"User-Agent": USER_AGENT, **(headers or {})}
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except OSError:
            if attempt == tries:
                raise
            time.sleep(10 * attempt)
    raise AssertionError("unreachable")


def cache_dir() -> Path:
    return Path(os.environ.get("RADARES_CACHE", Path.home() / ".cache" / "radares-anunciados"))


def cached_get(
    url: str,
    data: dict[str, str] | None = None,
    headers: dict[str, str] | None = None,
    max_age_s: int = 86_400,
    validate: Callable[[bytes], None] | None = None,
) -> bytes:
    """``get`` through a file cache. A copy younger than ``max_age_s`` is used as is;
    an older one is refreshed. A failed refresh raises, also with an old copy on
    disk: the source then reuses its last good result and reports itself down
    (``sources.run``), instead of looking like a source that answered.

    ``validate`` raises on a body that is no answer (``overpass_answer``). It runs
    before the write, so an error answer is never kept for the cache lifetime, and
    on a cached copy too: a copy that fails it (kept before the check existed) is
    stale and asked again."""
    key = hashlib.sha256(json.dumps([url, data], sort_keys=True).encode()).hexdigest()[:32]
    path = cache_dir() / key
    if path.exists() and time.time() - path.stat().st_mtime < max_age_s:
        cached = path.read_bytes()
        try:
            if validate is not None:
                validate(cached)
            return cached
        except ValueError as exc:
            log.warning("cached copy of %s fails its check, asking again: %s", url, exc)
    body = get(url, data=data, headers=headers)
    if validate is not None:
        validate(body)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_bytes(body)
        tmp.replace(path)
    except OSError as exc:  # an unwritable cache must not fail a download that worked
        log.warning("could not cache %s in %s: %s", url, path.parent, exc)
    return body


def overpass_answer(body: bytes) -> None:
    """Raise ValueError unless ``body`` is a complete Overpass answer. A query that
    ran out of time or memory still answers 200, with a ``remark`` and whatever it
    had found so far (often nothing); a proxy in front of it may answer HTML."""
    try:
        data = json.loads(body)
    except ValueError as exc:
        raise ValueError(f"Overpass answered with no JSON: {body[:80]!r}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("elements"), list):
        raise ValueError(f"Overpass answered with no elements: {body[:80]!r}")
    if data.get("remark"):
        raise ValueError(f"Overpass remark: {data['remark']}")
