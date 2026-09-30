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


def _densify(line: list[tuple[float, float]], every_m: float) -> list[tuple[float, float]]:
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
        for point in _densify(line, 20.0):
            if all(distance_m(point, c) > reach for c in centres):
                centres.append(point)
    return centres
