"""HTTP with a real User-Agent and a couple of retries (Overpass 504s under load)."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
import urllib.parse
import urllib.request
from collections.abc import Callable
from pathlib import Path

log = logging.getLogger(__name__)

USER_AGENT = "radares-anunciados (+https://github.com/GeiserX/radares-anunciados)"


def get(
    url: str,
    data: dict[str, str] | None = None,
    headers: dict[str, str] | None = None,
    timeout: int = 90,
    tries: int = 3,
) -> bytes:
    body = urllib.parse.urlencode(data).encode() if data is not None else None
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
    path = _cache_path(url, data)
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


def _cache_path(url: str, data: dict[str, str] | None) -> Path:
    key = hashlib.sha256(json.dumps([url, data], sort_keys=True).encode()).hexdigest()[:32]
    return cache_dir() / key


def cached_copy(
    url: str,
    data: dict[str, str] | None = None,
    validate: Callable[[bytes], None] | None = None,
) -> bytes | None:
    """The copy ``cached_get`` keeps for this request, however old; None when there
    is none or it fails ``validate``. Only for data that adds to a source's own
    answer (the OSM relations around its cameras): a source's own data comes from
    ``cached_get``, so a failed refresh still shows the source as down."""
    try:
        body = _cache_path(url, data).read_bytes()
        if validate is not None:
            validate(body)
    except (OSError, ValueError):
        return None
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
