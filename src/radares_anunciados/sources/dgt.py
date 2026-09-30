"""DGT fixed radars and average-speed sections from the DGT NAP (DATEX II).

Dataset: https://nap.dgt.es/dataset/radares-fijos-dgt, license CC BY 4.0,
attribution "Dirección General de Tráfico". State roads only: the Basque
Country and Catalonia run their own.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET

from ..model import Radar

URL = "https://infocar.dgt.es/datex2/dgt/PredefinedLocationsPublication/radares/content.xml"
ATTRIBUTION = "Dirección General de Tráfico (CC BY 4.0)"

_D = "{http://datex2.eu/schema/1_0/1_0}"
_XSI_TYPE = "{http://www.w3.org/2001/XMLSchema-instance}type"


def _text(el: ET.Element, path: str) -> str | None:
    found = el.find(path)
    return found.text.strip() if found is not None and found.text else None


def _coords(point: ET.Element) -> tuple[float, float]:
    return (
        float(_text(point, f"{_D}pointCoordinates/{_D}latitude")),
        float(_text(point, f"{_D}pointCoordinates/{_D}longitude")),
    )


def _label(ref: ET.Element | None) -> str:
    """'A-7 km 580.3 (sentido ALMERIA)' from a DATEX referencePoint."""
    if ref is None:
        return ""
    road = _text(ref, f"{_D}roadNumber") or "?"
    label = road
    dist = _text(ref, f"{_D}referencePointDistance")
    if dist:
        label += f" km {float(dist) / 1000:.1f}"
    direction = _text(ref, f".//{_D}directionNamed")
    if direction:
        label += f" (sentido {direction})"
    return label


def parse(xml: bytes, provinces: set[str], radius_m: int = 500) -> list[Radar]:
    """Radars in the given INE province codes (e.g. {"30"} for Murcia)."""
    root = ET.fromstring(xml)
    radars: list[Radar] = []
    for loc_set in root.iter(f"{_D}predefinedLocationSet"):
        for loc in loc_set.findall(f"{_D}predefinedLocation"):
            province = _text(loc, f".//{_D}provinceINEIdentifier")
            if province not in provinces:
                continue
            inner = loc.find(f"{_D}predefinedLocation")
            if inner is None:
                continue
            source_id = loc.get("id", "").removeprefix("GUID_")
            kind = inner.get(_XSI_TYPE, "").split(":")[-1]
            if kind == "Point":
                point = inner.find(f"{_D}tpegpointLocation/{_D}point")
                lat, lon = _coords(point)
                label = _label(inner.find(f"{_D}referencePoint"))
                radars.append(
                    Radar(
                        id=f"dgt-{source_id}",
                        source="dgt",
                        kind="fixed",
                        name=f"Radar fijo {label}",
                        lat=lat,
                        lon=lon,
                        radius_m=radius_m,
                        url=URL,
                        attribution=ATTRIBUTION,
                    )
                )
            elif kind == "Linear":
                # An average-speed section has a camera at each end; direction
                # is "unknown" in the data, so both ends get a circle.
                linear = inner.find(f"{_D}tpeglinearLocation")
                primary = f".//{_D}referencePointPrimaryLocation/{_D}referencePoint"
                start = _label(inner.find(primary))
                for end in ("from", "to"):
                    point = linear.find(f"{_D}{end}")
                    if point is None:
                        continue
                    lat, lon = _coords(point)
                    radars.append(
                        Radar(
                            id=f"dgt-{source_id}-{end}",
                            source="dgt",
                            kind="section",
                            name=f"Radar de tramo {start}",
                            lat=lat,
                            lon=lon,
                            radius_m=radius_m,
                            url=URL,
                            attribution=ATTRIBUTION,
                        )
                    )
    return radars
