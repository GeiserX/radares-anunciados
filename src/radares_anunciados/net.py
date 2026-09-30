"""HTTP with a real User-Agent and a couple of retries (Overpass 504s under load)."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
import urllib.parse
import urllib.request
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
) -> bytes:
    """``get`` through a file cache. A copy younger than ``max_age_s`` is used as is;
    an older one is refreshed, and kept if the refresh fails (Overpass 504s for
    hours at a time, and last week's street geometry is still right)."""
    key = hashlib.sha256(json.dumps([url, data], sort_keys=True).encode()).hexdigest()[:32]
    path = cache_dir() / key
    if path.exists() and time.time() - path.stat().st_mtime < max_age_s:
        return path.read_bytes()
    try:
        body = get(url, data=data, headers=headers)
    except OSError:
        if path.exists():
            log.warning("using cached copy of %s after a failed refresh", url)
            return path.read_bytes()
        raise
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_bytes(body)
    tmp.replace(path)
    return body
