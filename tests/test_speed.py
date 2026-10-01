import pytest

from radares_anunciados import speed
from radares_anunciados.model import Radar


def fixed(name="Radar fijo A-7 km 580.3", maxspeed=None, kind="fixed"):
    return Radar(name, "dgt", kind, name, 37.0, -1.0, 500, maxspeed=maxspeed)


def test_auto_radius_is_200_m_plus_seconds_of_travel():
    auto = speed.Radius()
    assert auto.point(fixed(maxspeed=100)) == 1311  # 200 + 40 s at 100 km/h
    assert auto.point(fixed(maxspeed=50)) == 756
    assert auto.street_m(50) == 478  # 200 + 20 s at 50 km/h
    assert auto.street_m(30) == 367


@pytest.mark.parametrize(
    ("name", "kind", "kmh"),
    [
        ("Radar fijo A-7 km 580.3 (sentido ALMERIA)", "fixed", 120),
        ("Radar de tramo AP-7 km 12.0", "section", 120),
        ("Radar fijo N-340 km 2.0", "fixed", 90),
        ("Radar RM-11 km 18.3", "fixed", 90),
        ("Radar", "fixed", 90),  # no road, no limit: interurban
        ("Radar anunciado Calle Mayor (El Raal)", "mobile_announced", 50),
        ("Radar anunciado A-30 (Murcia)", "mobile_announced", 50),  # a street list is urban
    ],
)
def test_fallback_limit_by_road(name, kind, kmh):
    assert speed.fallback_kmh(fixed(name, kind=kind)) == kmh


def test_a_published_limit_beats_the_fallback():
    assert speed.Radius().point(fixed("Radar fijo A-7 km 1", maxspeed=80)) == speed.auto_radius(
        80, 40
    )


def test_never_under_100_m():
    from radares_anunciados.ha import ZoneSpec

    assert speed.Radius().street_m(1) >= 100
    tiny = speed.size([fixed()], speed.Radius(fixed=40))[0]
    assert tiny.radius_m == 40 and ZoneSpec.from_radar(tiny).radius == 100


def test_a_number_keeps_working(monkeypatch):
    monkeypatch.setenv("RADARES_FIXED_RADIUS", "500")
    monkeypatch.setenv("RADARES_STREET_RADIUS", "300")
    r = speed.Radius.from_env()
    assert r.point(fixed(maxspeed=120)) == 500 and r.street_m(30) == 300


@pytest.mark.parametrize("value", [None, "auto", "AUTO", ""])
def test_auto_is_the_default(monkeypatch, value):
    for name in ("RADARES_FIXED_RADIUS", "RADARES_STREET_RADIUS"):
        if value is None:
            monkeypatch.delenv(name, raising=False)
        else:
            monkeypatch.setenv(name, value)
    assert speed.Radius.from_env() == speed.Radius(None, None)


def test_a_bad_radius_setting_says_which(monkeypatch):
    monkeypatch.setenv("RADARES_FIXED_RADIUS", "big")
    with pytest.raises(ValueError, match="RADARES_FIXED_RADIUS"):
        speed.Radius.from_env()


def test_size_sets_points_and_leaves_street_circles_alone():
    street = fixed("Radar anunciado Calle X", kind="mobile_announced")
    sized = speed.size([fixed(maxspeed=100), street], speed.Radius())
    assert [r.radius_m for r in sized] == [1311, 500]


def test_limit_lookups_run_before_sizing(monkeypatch):
    def lookup(radars):
        return [r if r.maxspeed else Radar(**{**r.__dict__, "maxspeed": 60}) for r in radars]

    monkeypatch.setattr(speed, "LOOKUPS", [lookup])
    filled = speed.fill_limits([fixed(), fixed(maxspeed=100)])
    assert [r.maxspeed for r in filled] == [60, 100]
