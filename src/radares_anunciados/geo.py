"""Distances and covering a street with circles."""

from __future__ import annotations

import math

EARTH_M = 6_371_000.0


def distance_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Haversine distance between two (lat, lon) points, in metres."""
    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)
    h = (
        math.sin((lat2 - lat1) / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    )
    return 2 * EARTH_M * math.asin(math.sqrt(h))


def bearing_deg(a: tuple[float, float], b: tuple[float, float]) -> int:
    """The compass bearing from ``a`` to ``b``, (lat, lon) points, in whole degrees
    from north (0 to 359)."""
    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)
    y = math.sin(lon2 - lon1) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(lon2 - lon1)
    return round(math.degrees(math.atan2(y, x))) % 360


def densify(line: list[tuple[float, float]], every_m: float) -> list[tuple[float, float]]:
    points = [line[0]]
    for a, b in zip(line, line[1:], strict=False):
        steps = max(1, math.ceil(distance_m(a, b) / every_m))
        points += [
            (a[0] + (b[0] - a[0]) * i / steps, a[1] + (b[1] - a[1]) * i / steps)
            for i in range(1, steps + 1)
        ]
    return points


def cover(lines: list[list[tuple[float, float]]], radius_m: float) -> list[tuple[float, float]]:
    """Centres of circles of ``radius_m`` that together cover every line.

    Greedy: walk each line in 20 m steps and drop a new centre wherever the
    point is not already within ``0.9 * radius_m`` of one. The two halves of a
    dual carriageway and ways that overlap at their joins share circles.
    """
    reach = 0.9 * radius_m
    centres: list[tuple[float, float]] = []
    for line in lines:
        if not line:
            continue
        for point in densify(line, 20.0):
            if all(distance_m(point, c) > reach for c in centres):
                centres.append(point)
    return centres


# ETRS89 (GRS80 ellipsoid). ETRS89 and WGS84 differ by well under a metre in
# Spain, far below the size of a radar zone, so ETRS89 lat/lon is used as WGS84.
_GRS80_A = 6_378_137.0
_GRS80_F = 1 / 298.257222101
_UTM_K0 = 0.9996
_UTM_E0 = 500_000.0


def utm_to_wgs84(easting: float, northing: float, zone: int) -> tuple[float, float]:
    """(lat, lon) of an ETRS89 UTM point in a northern zone (29, 30 or 31 in Spain;
    EPSG:25829, 25830, 25831). The Canaries' zone 28 works the same way.

    Inverse transverse Mercator by Krüger's series in the third flattening ``n``
    (Karney 2011, eq. 11-15 to third order): sub-millimetre inside a zone.
    """
    if not 1 <= zone <= 60:
        raise ValueError(f"UTM zone {zone} does not exist")
    n = _GRS80_F / (2 - _GRS80_F)
    big_a = _GRS80_A / (1 + n) * (1 + n**2 / 4 + n**4 / 64)
    beta = (
        n / 2 - 2 * n**2 / 3 + 37 * n**3 / 96,
        n**2 / 48 + n**3 / 15,
        17 * n**3 / 480,
    )
    delta = (
        2 * n - 2 * n**2 / 3 - 2 * n**3,
        7 * n**2 / 3 - 8 * n**3 / 5,
        56 * n**3 / 15,
    )
    xi = northing / (_UTM_K0 * big_a)
    eta = (easting - _UTM_E0) / (_UTM_K0 * big_a)
    xi_p = xi - sum(
        b * math.sin(2 * j * xi) * math.cosh(2 * j * eta) for j, b in enumerate(beta, 1)
    )
    eta_p = eta - sum(
        b * math.cos(2 * j * xi) * math.sinh(2 * j * eta) for j, b in enumerate(beta, 1)
    )
    chi = math.asin(math.sin(xi_p) / math.cosh(eta_p))
    lat = chi + sum(d * math.sin(2 * j * chi) for j, d in enumerate(delta, 1))
    lon0 = math.radians(zone * 6 - 183)
    lon = lon0 + math.atan2(math.sinh(eta_p), math.cos(xi_p))
    return math.degrees(lat), math.degrees(lon)
