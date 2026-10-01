"""The published feed: `radares feed --status`, the page and the data license."""

import json
import os
import re
from datetime import date, timedelta
from html.parser import HTMLParser
from pathlib import Path

import pytest

from radares_anunciados import cli, sources, store
from radares_anunciados.model import Radar, SourceResult, Stretch
from radares_anunciados.sources import Source

ROOT = Path(__file__).parent.parent


@pytest.fixture(autouse=True)
def clean_env(monkeypatch, tmp_path):
    for name in list(os.environ):
        if name.startswith("RADARES_"):
            monkeypatch.delenv(name)
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path / "cache"))


def fake(key, answers, spanish_ip=False):
    def fetch(ctx):
        answer = next(answers)
        if isinstance(answer, Exception):
            raise answer
        return answer

    return Source(key, fetch, f"{key} people", f"{key} licence", spanish_ip=spanish_ip)


def radar(source, n=0, **kw):
    return Radar(f"{source}-{n}", source, "fixed", f"Radar {n}", 37.0 + n / 10, -1.0, 500, **kw)


def test_status_says_which_sources_are_fresh_stale_or_missing(monkeypatch):
    stretch = Stretch("ok-s", "ok", "Tramo", "A-7", (37.0, -1.0), (37.1, -1.1))
    registry = {
        "ok": fake("ok", iter([SourceResult([radar("ok"), radar("ok", 1)], [stretch])] * 2)),
        "stale": fake("stale", iter([SourceResult([radar("stale", 5)]), OSError("HTTP 403")])),
        "missing": fake("missing", iter([OSError("TLS handshake")] * 2), spanish_ip=True),
    }
    monkeypatch.setattr(sources, "REGISTRY", registry)
    cli.collect(date(2026, 9, 28), save_history=False)  # "stale" succeeds once
    found = cli.collect(date(2026, 9, 28), save_history=False)
    report = cli.status(found, now=1_790_000_000.0)
    rows = {r["source"]: r for r in report["sources"]}
    assert report["generated"] == "2026-09-21T14:13:20+00:00"
    assert report["features"] == 4
    assert rows["ok"] | {"data_time": None} == {
        "source": "ok",
        "status": "ok",
        "radars": 2,
        "stretches": 1,
        "in_feed": 3,
        "data_time": None,
        "error": "",
        "attribution": "ok people",
        "licence": "ok licence",
        "spanish_ip": False,
    }
    assert rows["ok"]["data_time"].endswith("+00:00")
    assert (rows["stale"]["status"], rows["stale"]["radars"], rows["stale"]["in_feed"]) == (
        "stale",
        1,
        1,
    )
    assert rows["stale"]["data_time"] and "403" in rows["stale"]["error"]
    assert rows["missing"] | {"error": ""} == {
        "source": "missing",
        "status": "missing",
        "radars": 0,
        "stretches": 0,
        "in_feed": 0,
        "data_time": None,
        "error": "",
        "attribution": "missing people",
        "licence": "missing licence",
        "spanish_ip": True,
    }


def announced_this_week(source):
    monday = date.today() - timedelta(days=date.today().weekday())
    end = monday + timedelta(days=6)
    return [radar(source, valid_from=monday, valid_to=end)]


def test_feed_writes_the_feed_and_its_status(monkeypatch, tmp_path):
    answers = iter([SourceResult(announced_this_week("m"))] * 2)
    monkeypatch.setattr(sources, "REGISTRY", {"m": fake("m", answers)})
    out, status = tmp_path / "feed.geojson", tmp_path / "status.json"
    assert cli.main(["feed", "-o", str(out), "--status", str(status)]) == 0
    data = json.loads(out.read_text("utf-8"))
    report = json.loads(status.read_text("utf-8"))
    assert [f["id"] for f in data["features"]] == ["m-0"]
    assert report["features"] == 1 and report["sources"][0]["status"] == "ok"
    # a plain feed leaves the history alone; the published feed keeps its own
    assert store.load_announced() == []
    assert cli.main(["feed", "-o", str(out), "--save-history"]) == 0
    assert [r.id for r in store.load_announced()] == ["m-0"]


def test_an_empty_feed_still_writes_a_valid_status(monkeypatch, tmp_path):
    monkeypatch.setattr(sources, "REGISTRY", {"m": fake("m", iter([OSError("down")]))})
    out, status = tmp_path / "feed.geojson", tmp_path / "status.json"
    assert cli.main(["feed", "-o", str(out), "--status", str(status)]) == 0
    assert json.loads(out.read_text("utf-8")) == {"type": "FeatureCollection", "features": []}
    report = json.loads(status.read_text("utf-8"))
    assert report["features"] == 0 and report["sources"][0]["status"] == "missing"


class Tags(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags: list[tuple[str, dict]] = []

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))


def test_the_page_loads_only_pinned_files_with_an_integrity_hash():
    parser = Tags()
    parser.feed((ROOT / "site" / "index.html").read_text("utf-8"))
    external = [
        (tag, a)
        for tag, a in parser.tags
        if tag in ("script", "link") and (a.get("src") or a.get("href") or "").startswith("http")
    ]
    assert external, "the page loads its map library from a CDN"
    for _, a in external:
        url = a.get("src") or a["href"]
        assert re.search(r"@\d+\.\d+\.\d+/", url), f"{url} is not pinned to an exact version"
        assert re.fullmatch(r"sha(384|512)-[A-Za-z0-9+/=]{64,}", a.get("integrity", "")), url
        assert a.get("crossorigin") == "anonymous", url
    metas = [a for tag, a in parser.tags if tag == "meta"]
    csp = next(a["content"] for a in metas if a.get("http-equiv") == "Content-Security-Policy")
    assert "default-src 'none'" in csp and "connect-src 'self'" in csp
    assert "font-src" not in csp  # no external fonts


def test_the_data_license_credits_every_registered_source():
    text = (ROOT / "LICENSE-DATA.md").read_text("utf-8")
    for key in sources.REGISTRY:
        assert f"| `{key}` |" in text, f"LICENSE-DATA.md has no row for the {key} source"
