import os
import time

import pytest

from radares_anunciados import net


def test_cache_hit_skips_the_network(tmp_path, monkeypatch):
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))
    calls = []
    monkeypatch.setattr(net, "get", lambda url, **kw: calls.append(url) or b"one")
    assert net.cached_get("https://x/a") == b"one"
    assert net.cached_get("https://x/a") == b"one"
    assert calls == ["https://x/a"]


def test_stale_copy_survives_a_failed_refresh(tmp_path, monkeypatch):
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))
    monkeypatch.setattr(net, "get", lambda url, **kw: b"old")
    net.cached_get("https://x/b", max_age_s=60)
    for f in tmp_path.iterdir():  # age the copy past max_age_s
        os.utime(f, (time.time() - 120, time.time() - 120))

    def down(url, **kw):
        raise OSError("504")

    monkeypatch.setattr(net, "get", down)
    assert net.cached_get("https://x/b", max_age_s=60) == b"old"
    with pytest.raises(OSError):
        net.cached_get("https://x/never-fetched", max_age_s=60)
