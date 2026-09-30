"""HTTP with a real User-Agent and a couple of retries (Overpass 504s under load)."""

from __future__ import annotations

import time
import urllib.parse
import urllib.request

USER_AGENT = "radares-anunciados (+https://github.com/GeiserX/radares-anunciados)"


def get(url: str, data: dict[str, str] | None = None, timeout: int = 90, tries: int = 3) -> bytes:
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    for attempt in range(1, tries + 1):
        request = urllib.request.Request(url, data=body, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except OSError:
            if attempt == tries:
                raise
            time.sleep(10 * attempt)
    raise AssertionError("unreachable")
