import os
import time
from datetime import date
from pathlib import Path

import pytest

from radares_anunciados import net


def test_cache_hit_skips_the_network(tmp_path, monkeypatch):
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))
    calls = []
    monkeypatch.setattr(net, "get", lambda url, **kw: calls.append(url) or b"one")
    assert net.cached_get("https://x/a") == b"one"
    assert net.cached_get("https://x/a") == b"one"
    assert calls == ["https://x/a"]


def test_a_failed_refresh_raises_even_with_an_old_copy(tmp_path, monkeypatch):
    # The source layer keeps the last good result and reports the source down;
    # an old copy returned here would look like a source that answered.
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))
    monkeypatch.setattr(net, "get", lambda url, **kw: b"old")
    net.cached_get("https://x/b", max_age_s=60)
    for f in tmp_path.iterdir():  # age the copy past max_age_s
        os.utime(f, (time.time() - 120, time.time() - 120))

    def down(url, **kw):
        raise OSError("504")

    monkeypatch.setattr(net, "get", down)
    with pytest.raises(OSError):
        net.cached_get("https://x/b", max_age_s=60)
    with pytest.raises(OSError):
        net.cached_get("https://x/never-fetched", max_age_s=60)


def test_unwritable_cache_still_returns_the_download(tmp_path, monkeypatch):
    blocker = tmp_path / "file"
    blocker.write_text("not a directory")
    monkeypatch.setenv("RADARES_CACHE", str(blocker / "cache"))  # mkdir fails
    monkeypatch.setattr(net, "get", lambda url, **kw: b"fresh")
    assert net.cached_get("https://x/c") == b"fresh"


FIX = Path(__file__).parent / "fixtures"
# A real Overpass answer: HTTP 200 with no elements and an error remark.
REMARK = (FIX / "overpass_limits_remark.json").read_bytes()
GOOD = (FIX / "osm_es_mc.json").read_bytes()


@pytest.mark.parametrize(
    "body", [REMARK, b"<html>502 Bad Gateway</html>", b'{"version": 0.6}', b"[]"]
)
def test_an_overpass_error_answer_fails_the_check(body):
    with pytest.raises(ValueError):
        net.overpass_answer(body)


def test_an_answer_with_no_elements_and_no_remark_passes_the_check():
    net.overpass_answer(b'{"version": 0.6, "elements": []}')  # nothing there is an answer
    net.overpass_answer(GOOD)


def test_a_body_that_fails_the_check_is_not_cached(tmp_path, monkeypatch):
    # Kept, it would be read back for the whole cache lifetime without asking again.
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))
    answers = iter([REMARK, GOOD])
    calls = []
    monkeypatch.setattr(net, "get", lambda url, **kw: calls.append(url) or next(answers))
    with pytest.raises(ValueError, match="remark"):
        net.cached_get("https://x/o", {"data": "q"}, validate=net.overpass_answer)
    assert list(tmp_path.iterdir()) == []
    for _ in range(2):
        assert net.cached_get("https://x/o", {"data": "q"}, validate=net.overpass_answer) == GOOD
    assert len(calls) == 2  # asked again after the bad answer, then cached


def test_osm_and_murcia_check_their_overpass_answers_before_caching(tmp_path, monkeypatch):
    from radares_anunciados.sources import Context, murcia, osm
    from radares_anunciados.speed import Radius

    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))
    calls = []
    up = [False]

    def get(url, data=None, **kw):
        calls.append(url)
        return GOOD if up[0] else REMARK

    monkeypatch.setattr(net, "get", get)
    ctx = Context(date(2026, 7, 8), None, (osm.MURCIA_REGION,), Radius())
    with pytest.raises(ValueError, match="remark"):
        osm.fetch(ctx)
    article = (FIX / "laopinion_2026-07-07.html").read_text()
    monkeypatch.setattr(murcia, "find_article", lambda day: ("u", date(2026, 7, 7), article))
    with pytest.raises(ValueError, match="remark"):
        murcia.fetch(date(2026, 7, 8))
    up[0] = True
    assert osm.fetch(ctx).radars
    murcia.fetch(date(2026, 7, 8))
    assert len(calls) == 5  # each source asked again: the error answers were not kept


def test_a_cached_copy_that_fails_the_check_is_asked_again(tmp_path, monkeypatch):
    # An error answer cached before the check existed must not be served for the
    # rest of its cache lifetime.
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))
    monkeypatch.setattr(net, "get", lambda url, **kw: REMARK)
    net.cached_get("https://x/p", {"data": "q"})  # cached with no check
    calls = []
    monkeypatch.setattr(net, "get", lambda url, **kw: calls.append(url) or GOOD)
    for _ in range(2):
        assert net.cached_get("https://x/p", {"data": "q"}, validate=net.overpass_answer) == GOOD
    assert len(calls) == 1  # the bad copy was replaced, the good one then served


def test_fail_fast_gives_one_short_try(monkeypatch):
    # A source that answers only Spanish addresses times out from abroad: three tries
    # of 90 s per request, unless the run caps it (RADARES_SPANISH_IP_TIMEOUT).
    asked = []

    def urlopen(request, timeout):
        asked.append(timeout)
        raise TimeoutError("timed out")

    monkeypatch.setattr(net.urllib.request, "urlopen", urlopen)
    monkeypatch.setattr(net.time, "sleep", lambda s: None)
    spain = frozenset({"ayto.es"})
    with net.fail_fast(20, spain), pytest.raises(OSError):
        net.get("https://www.ayto.es/radares")
    assert asked == [20]
    asked.clear()
    with net.fail_fast(20, spain), pytest.raises(OSError):  # another host: no cap
        net.get("https://notayto.es/radares")
    assert asked == [90, 90, 90]
    assert net.timeout_s(60, "https://ayto.es/") == 60  # the cap ends with the block
    asked.clear()
    with pytest.raises(OSError):
        net.get("https://ayto.es/radares")
    assert asked == [90, 90, 90]
    with net.fail_fast(None, spain), pytest.raises(OSError):
        net.get("https://ayto.es/b", timeout=5)
    assert asked[3:] == [5, 5, 5]
