import logging
from dataclasses import replace
from datetime import UTC, datetime
from pathlib import Path

import pytest

from radares_anunciados.model import Radar, SourceResult, Stretch
from radares_anunciados.sources import Context, Source, dgt_freshness
from radares_anunciados.speed import Radius

FIX = Path(__file__).parent / "fixtures"
# The real HEAD answer for the fixed-radar file on 2026-10-01.
HEADERS = dict(
    line.split(": ", 1)
    for line in (FIX / "dgt_radares_head.txt").read_text().splitlines()
    if ": " in line
)
CHANGED = datetime(2025, 12, 18, 10, 56, 20, tzinfo=UTC).timestamp()
ASKED = datetime(2026, 10, 1, 17, 42, 50, tzinfo=UTC).timestamp()


@pytest.fixture(autouse=True)
def forget(monkeypatch):
    monkeypatch.setattr(dgt_freshness, "_last_modified", None)


def test_reads_the_files_last_modified():
    assert dgt_freshness.parse_last_modified(HEADERS["last-modified"]) == CHANGED
    assert dgt_freshness.parse_last_modified(None) is None
    assert dgt_freshness.parse_last_modified("not a date") is None


def test_a_file_unchanged_for_months_is_logged_as_stale(caplog):
    with caplog.at_level(logging.INFO):
        age = dgt_freshness.check(now=ASKED, get_headers=lambda url: HEADERS)
    assert age == ASKED - CHANGED
    assert round(age / 86_400) == 287
    assert "2025-12-18, 287 days ago: stale" in caplog.text
    assert [r.levelno for r in caplog.records] == [logging.WARNING]
    assert dgt_freshness.last_modified() == CHANGED
    assert dgt_freshness.age_s(now=ASKED + 3600) == ASKED - CHANGED + 3600


def test_a_fresh_file_is_logged_without_a_warning(caplog):
    headers = {"last-modified": "Thu, 01 Oct 2026 10:00:00 GMT"}
    with caplog.at_level(logging.INFO):
        dgt_freshness.check(now=ASKED, get_headers=lambda url: headers)
    assert [r.levelno for r in caplog.records] == [logging.INFO]


def test_a_failed_check_keeps_the_last_known_date_and_never_raises(caplog):
    dgt_freshness.check(now=ASKED, get_headers=lambda url: HEADERS)

    def down(url):
        raise OSError("connection refused")

    assert dgt_freshness.check(now=ASKED + 60, get_headers=down) == ASKED + 60 - CHANGED
    assert dgt_freshness.check(now=ASKED + 60, get_headers=lambda url: {}) == ASKED + 60 - CHANGED
    assert "connection refused" in caplog.text


def test_nothing_known_before_any_check():
    assert dgt_freshness.age_s() is None
    assert dgt_freshness.check(get_headers=lambda url: {}) is None


def test_watch_checks_before_each_fetch_and_never_fails_it(monkeypatch):
    asked = []
    monkeypatch.setattr(dgt_freshness, "head", lambda url: asked.append(url) or HEADERS)
    radar = Radar("dgt-1", "dgt", "fixed", "A-7 km 1", 37.0, -1.0, 500, attribution="DGT")
    stretch = Stretch("dgt-s", "dgt", "Tramo", "A-7", (37.0, -1.0), (37.1, -1.1), attribution="DGT")
    result = SourceResult([radar], [stretch])
    source = dgt_freshness.watch(Source("dgt", lambda ctx: result, "a", "l"))
    ctx = Context(day=None, provinces=None, boxes=(), radius=Radius())
    # the reuse terms ask for the date of the last update: each record and status.json carry it
    dated = SourceResult(
        [replace(radar, attribution="DGT, actualizado 2025-12-18")],
        [replace(stretch, attribution="DGT, actualizado 2025-12-18")],
        updated="2025-12-18",
    )
    assert source.fetch(ctx) == dated
    assert asked == [dgt_freshness.dgt.URL]
    assert dgt_freshness.last_modified() == CHANGED

    def down(url):
        raise OSError("timed out")

    monkeypatch.setattr(dgt_freshness, "head", down)
    assert source.fetch(ctx) == dated  # the date of the latest check that got one


def test_a_file_never_dated_is_credited_without_a_date(monkeypatch):
    monkeypatch.setattr(dgt_freshness, "head", lambda url: {})
    result = SourceResult(
        [Radar("dgt-1", "dgt", "fixed", "A-7", 37.0, -1.0, 500, attribution="DGT")]
    )
    source = dgt_freshness.watch(Source("dgt", lambda ctx: result, "a", "l"))
    ctx = Context(day=None, provinces=None, boxes=(), radius=Radius())
    assert source.fetch(ctx) is result
