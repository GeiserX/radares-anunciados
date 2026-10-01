import pytest

from radares_anunciados import osm_limits


@pytest.fixture(autouse=True)
def no_speed_limit_queries(monkeypatch):
    """Every collect runs the OSM speed-limit lookup (``speed.LOOKUPS``). In a
    test it finds no network and leaves the limits unknown, as a failed query
    does; tests of the lookup give it fixtures instead."""

    def offline(points):
        raise OSError("tests never touch the network")

    monkeypatch.setattr(osm_limits, "_ask", offline)
