"""The published feed: `radares feed --status`, the page and the data license."""

import json
import os
import re
import shutil
from datetime import date, timedelta
from html.parser import HTMLParser
from pathlib import Path

import pytest
import yaml

from radares_anunciados import cli, net, sources, store
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
        "ok": fake(
            "ok",
            iter(
                [SourceResult([radar("ok"), radar("ok", 1)], [stretch], updated="2026-09-17")] * 2
            ),
        ),
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
        "updated": "2026-09-17",
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
        "updated": None,
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


def kept_between_runs() -> list[list[str]]:
    """The paths of each actions/cache step in feed.yml, relative to the cache folder."""
    lines = (ROOT / ".github" / "workflows" / "feed.yml").read_text("utf-8").splitlines()
    blocks = []
    for i, line in enumerate(lines):
        if line.strip() == "path: |":
            indent = len(line) - len(line.lstrip()) + 2
            block = []
            for nxt in lines[i + 1 :]:
                if len(nxt) - len(nxt.lstrip()) < indent or not nxt.strip():
                    break
                block.append(nxt.strip())
            blocks.append(block)
        elif re.match(r"\s*path: .*radares-cache", line):
            blocks.append([line.split("path:", 1)[1].strip()])
    prefix = "${{ runner.temp }}/radares-cache"
    return [[p.removeprefix(prefix).lstrip("/") for p in block] for block in blocks]


def test_a_scheduled_run_never_calls_a_source_ok_from_a_download_it_did_not_make(
    monkeypatch, tmp_path
):
    """The published run keeps only what the fallback needs. A download younger than its
    max age is reused without a request; kept between runs, it would make a source whose
    site is down look `ok`, with this run's time, in status.json."""
    blocks = kept_between_runs()
    assert len(blocks) == 2 and blocks[0] == blocks[1], "restore and save must keep the same paths"
    kept = blocks[0]
    assert "" not in kept, "the whole cache folder, downloads included, is kept between runs"

    calls = []

    def get(url, data=None, headers=None):
        calls.append(url)
        if len(calls) > 1:
            raise OSError("HTTP 503")
        return b'{"n": 2}'

    def fetch(ctx):
        n = json.loads(net.cached_get("https://example.org/radars"))["n"]
        return SourceResult([radar("up", i) for i in range(n)])

    monkeypatch.setattr(net, "get", get)
    up = Source("up", fetch, "up people", "up licence")
    monkeypatch.setattr(sources, "REGISTRY", {"up": up})
    first = cli.status(cli.collect(date(2026, 9, 28), save_history=True), now=1_790_000_000.0)
    assert first["sources"][0]["status"] == "ok"

    # the next scheduled run starts on a fresh runner with only the kept paths restored
    old, new = tmp_path / "cache", tmp_path / "next-run"
    for rel in kept:
        src = old / rel
        assert src.exists(), f"{rel} is kept between runs but the feed never writes it"
        dst = new / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        (shutil.copytree if src.is_dir() else shutil.copy2)(src, dst)
    monkeypatch.setenv("RADARES_CACHE", str(new))
    second = cli.status(cli.collect(date(2026, 9, 28), save_history=True), now=1_790_021_600.0)
    row = second["sources"][0]
    assert len(calls) == 2, "the next run must ask the source again"
    assert (row["status"], row["radars"], "503" in row["error"]) == ("stale", 2, True)
    assert row["data_time"] == first["sources"][0]["data_time"]


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
    directives = {}
    for part in filter(None, (p.strip() for p in csp.split(";"))):
        name, *values = part.split()
        directives[name] = set(values)
    # No tracking and no external fonts: the page, the pinned Leaflet files and OSM tiles only.
    # Anything not listed (font-src, frame-src...) falls back to default-src 'none'.
    assert directives == {
        "default-src": {"'none'"},
        "script-src": {"'self'", "https://unpkg.com"},
        "style-src": {"'self'", "https://unpkg.com"},
        "img-src": {"'self'", "data:", "https://tile.openstreetmap.org"},
        "connect-src": {"'self'"},
        "base-uri": {"'none'"},
        "form-action": {"'none'"},
    }


def test_the_data_license_credits_every_registered_source():
    text = (ROOT / "LICENSE-DATA.md").read_text("utf-8")
    for key in sources.REGISTRY:
        assert f"| `{key}` |" in text, f"LICENSE-DATA.md has no row for the {key} source"


def test_every_source_row_in_the_data_license_names_its_attribution_and_terms():
    rows = {}
    for line in (ROOT / "LICENSE-DATA.md").read_text("utf-8").splitlines():
        if m := re.match(r"\| `(\w+)` \|", line):
            rows[m.group(1)] = [c.strip() for c in line.strip().strip("|").split("|")]
    for key in sources.REGISTRY:
        cells = rows.get(key)
        assert cells is not None, f"LICENSE-DATA.md has no row for the {key} source"
        # | Source | What it gives | Attribution | Terms |
        assert len(cells) == 4, f"the {key} row has {len(cells)} cells, not 4"
        assert cells[2], f"the {key} row names no attribution"
        assert cells[3], f"the {key} row names no terms"


def feed_jobs() -> dict:
    return yaml.safe_load((ROOT / ".github" / "workflows" / "feed.yml").read_text("utf-8"))["jobs"]


def test_no_pull_request_code_runs_on_the_self_hosted_runner():
    """The publishing job runs on a self-hosted runner in Spain, so it may run only on
    events a fork cannot trigger. The pull request build stays on a GitHub-hosted runner."""
    jobs = feed_jobs()
    trusted = "github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'"
    hosted = [k for k, job in jobs.items() if "self-hosted" in str(job["runs-on"])]
    assert hosted == ["publish"]
    assert jobs["publish"]["if"] == trusted
    assert jobs["check"]["if"] == "github.event_name == 'pull_request'"
    assert jobs["check"]["runs-on"] == "ubuntu-latest"
    # the runner is not wiped between runs: the downloads of the last run must go first
    steps = [step.get("name") for step in jobs["publish"]["steps"]]
    assert steps.index("Clear the cache folder") < steps.index("Restore the last good results")


def test_the_pull_request_build_gives_up_fast_on_spanish_only_sources(monkeypatch):
    jobs = feed_jobs()
    assert int(jobs["check"]["env"]["RADARES_SPANISH_IP_TIMEOUT"]) <= 30
    assert "RADARES_SPANISH_IP_TIMEOUT" not in str(jobs["publish"])

    seen = {}

    def fetch(key):
        def run(ctx):
            seen[key] = net.timeout_s(90)
            raise OSError("timed out")

        return run

    monkeypatch.setattr(
        sources,
        "REGISTRY",
        {
            "spain": Source("spain", fetch("spain"), "a", "l", spanish_ip=True),
            "abroad": Source("abroad", fetch("abroad"), "a", "l"),
        },
    )
    monkeypatch.setenv("RADARES_SPANISH_IP_TIMEOUT", "20")
    rows = cli.status(cli.collect(date(2026, 9, 28), save_history=False), now=1_790_000_000.0)
    assert seen == {"spain": 20, "abroad": 90}
    assert {r["source"]: r["status"] for r in rows["sources"]} == {
        "spain": "missing",
        "abroad": "missing",
    }
    monkeypatch.delenv("RADARES_SPANISH_IP_TIMEOUT")
    cli.collect(date(2026, 9, 28), save_history=False)
    assert seen == {"spain": 90, "abroad": 90}
