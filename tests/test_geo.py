import pytest

from radares_anunciados.geo import distance_m, utm_to_wgs84

# (zone, easting, northing) -> (lat, lon) from PROJ 9.8.1 (pyproj 3.8.0),
# EPSG:2582x -> EPSG:4326. The first four rows are radars published by the
# Servei Català de Trànsit (zone 31) and Trafikoa (zone 30); the rest are a
# known landmark and the edges of a zone.
KNOWN = [
    (31, 288075.4643, 4601625.063, 41.538228514451745, 0.45945671607984),  # A-2 PK 445.35
    (31, 415032.9514, 4589797.3114, 41.45526589388224, 1.9826831262215248),  # AP-7 PK 164
    (31, 482294.3992, 4648510.672, 41.98840257903288, 2.7862486010013447),  # AP-7 PK 60.77
    (30, 499983.69, 4792619.83, 43.28640001992144, -3.000201038449887),  # A-8 MAX CENTER
    (30, 546058.0, 4782306.0, 43.19212274225044, -2.433160389555822),  # AP-1 Maltzaga
    (30, 440291.0, 4474254.0, 40.41676957320929, -3.7037932950500605),  # Puerta del Sol
    (29, 537000.0, 4805000.0, 43.396965210449146, -8.543106769039449),  # A Coruña
    (30, 166021.44, 4000000.0, 36.08726734714362, -6.708910309721983),  # far west of zone 30
    (30, 833978.56, 4800000.0, 43.27873771689903, 1.1159149723226078),  # far east of zone 30
    (29, 166021.44, 0.0, 0.0, -12.00000002764579),  # the equator
]


@pytest.mark.parametrize(("zone", "e", "n", "lat", "lon"), KNOWN)
def test_utm_to_wgs84_matches_proj_to_the_centimetre(zone, e, n, lat, lon):
    got = utm_to_wgs84(e, n, zone)
    assert distance_m(got, (lat, lon)) < 0.01
    assert got == pytest.approx((lat, lon), abs=1e-7)


def test_the_zone_sets_the_central_meridian():
    # the same coordinates in another zone are 6 degrees away
    lat30, lon30 = utm_to_wgs84(500000, 4500000, 30)
    lat31, lon31 = utm_to_wgs84(500000, 4500000, 31)
    assert lon30 == pytest.approx(-3.0) and lon31 == pytest.approx(3.0)
    assert lat30 == pytest.approx(lat31)


def test_a_zone_that_does_not_exist_raises():
    with pytest.raises(ValueError):
        utm_to_wgs84(500000, 4500000, 0)
