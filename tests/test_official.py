"""feed.merge reads "official" from the registry, never from a list of names."""

from datetime import date

from radares_anunciados import feed, sources
from radares_anunciados.model import Radar, SourceResult
from radares_anunciados.sources import Source

DAY = date(2026, 10, 1)


def _radar(source: str, lat: float, kind: str = "fixed") -> Radar:
    return Radar(
        id=f"{source}-1", source=source, kind=kind, name="Radar", lat=lat, lon=2.0, radius_m=500
    )


def _register(monkeypatch, key: str, official: bool) -> None:
    source = Source(
        key=key,
        fetch=lambda ctx: SourceResult(),
        attribution="",
        licence="",
        official=official,
    )
    monkeypatch.setitem(sources.REGISTRY, key, source)


def test_only_the_crowd_map_is_not_official():
    assert [k for k, s in sources.REGISTRY.items() if not s.official] == ["osm"]


def test_any_official_source_wins_over_a_mapped_copy(monkeypatch):
    _register(monkeypatch, "city", official=True)
    copy = _radar("osm", 41.0009)  # 100 m north
    assert [r.id for r in feed.merge([_radar("city", 41.0), copy], DAY)] == ["city-1"]
    away = _radar("osm", 41.0027)  # 300 m north: another camera
    assert len(feed.merge([_radar("city", 41.0), away], DAY)) == 2


def test_the_rule_follows_the_flag_not_the_name(monkeypatch):
    _register(monkeypatch, "city", official=False)
    _register(monkeypatch, "crowd", official=False)
    # "city" marked not official: an OSM camera beside it stays
    assert len(feed.merge([_radar("city", 41.0), _radar("osm", 41.0009)], DAY)) == 2
    # any source marked not official gives way to an official radar, not only OSM
    merged = feed.merge([_radar("dgt", 41.0), _radar("crowd", 41.0009)], DAY)
    assert [r.id for r in merged] == ["dgt-1"]


def test_a_radar_of_an_unknown_source_is_neither():
    # e.g. a remembered street of a source since removed from the registry
    merged = feed.merge([_radar("gone", 41.0), _radar("osm", 41.0009)], DAY)
    assert len(merged) == 2
    merged = feed.merge([_radar("dgt", 41.0), _radar("gone", 41.0009)], DAY)
    assert len(merged) == 2
