"""Spain's provinces by INE code, each with a bounding box.

The boxes are each province's OpenStreetMap boundary (admin_level 6, and the
autonomous cities of Ceuta and Melilla) rounded outward to 0.01 degrees, read
once on 2026-10-01. A bounding box is far cheaper for Overpass than an area
lookup, which answers 504 under load, so OpenStreetMap cameras are searched by
these boxes. A box reaches a little into its neighbours; that only adds cameras.
"""

from __future__ import annotations

Box = tuple[float, float, float, float]  # (south, west, north, east)

PROVINCES: dict[str, tuple[str, Box]] = {
    "01": ("Araba / Álava", (42.47, -3.29, 43.22, -2.23)),
    "02": ("Albacete", (38.02, -2.89, 39.43, -0.91)),
    "03": ("Alacant / Alicante", (37.84, -1.1, 38.89, 0.24)),
    "04": ("Almería", (35.93, -3.15, 37.92, -1.62)),
    "05": ("Ávila", (40.08, -5.74, 41.17, -4.16)),
    "06": ("Badajoz", (37.94, -7.34, 39.46, -4.64)),
    "07": ("Illes Balears", (38.64, 1.15, 40.1, 4.33)),
    "08": ("Barcelona", (41.19, 1.36, 42.33, 2.78)),
    "09": ("Burgos", (41.45, -4.34, 43.2, -2.51)),
    "10": ("Cáceres", (39.03, -7.55, 40.49, -4.95)),
    "11": ("Cádiz", (36.0, -6.45, 37.06, -5.08)),
    "12": ("Castelló / Castellón", (39.71, -0.85, 40.79, 0.7)),
    "13": ("Ciudad Real", (38.34, -5.05, 39.58, -2.63)),
    "14": ("Córdoba", (37.18, -5.59, 38.73, -4.0)),
    "15": ("A Coruña", (42.46, -9.31, 43.8, -7.66)),
    "16": ("Cuenca", (39.22, -3.18, 40.66, -1.14)),
    "17": ("Girona", (41.65, 1.72, 42.5, 3.33)),
    "18": ("Granada", (36.69, -4.33, 38.09, -2.2)),
    "19": ("Guadalajara", (40.15, -3.55, 41.33, -1.53)),
    "20": ("Gipuzkoa", (42.89, -2.61, 43.4, -1.72)),
    "21": ("Huelva", (36.79, -7.53, 38.21, -6.12)),
    "22": ("Huesca", (41.34, -0.94, 42.93, 0.78)),
    "23": ("Jaén", (37.37, -4.29, 38.54, -2.43)),
    "24": ("León", (42.02, -7.08, 43.24, -4.73)),
    "25": ("Lleida", (41.27, 0.32, 42.87, 1.86)),
    "26": ("La Rioja", (41.91, -3.14, 42.65, -1.67)),
    "27": ("Lugo", (42.32, -8.0, 43.77, -6.81)),
    "28": ("Comunidad de Madrid", (39.88, -4.58, 41.17, -3.05)),
    "29": ("Málaga", (36.31, -5.62, 37.29, -3.76)),
    "30": ("Región de Murcia", (37.37, -2.35, 38.76, -0.64)),
    "31": ("Navarra", (41.9, -2.5, 43.32, -0.72)),
    "32": ("Ourense", (41.8, -8.37, 42.58, -6.73)),
    "33": ("Asturias / Asturies", (42.88, -7.19, 43.67, -4.51)),
    "34": ("Palencia", (41.75, -5.04, 43.07, -3.88)),
    "35": ("Las Palmas", (27.73, -15.84, 29.42, -13.33)),
    "36": ("Pontevedra", (41.86, -8.95, 42.87, -7.86)),
    "37": ("Salamanca", (40.23, -6.94, 41.3, -5.08)),
    "38": ("Santa Cruz de Tenerife", (27.63, -18.17, 28.86, -16.11)),
    "39": ("Cantabria", (42.75, -4.86, 43.52, -3.14)),
    "40": ("Segovia", (40.63, -4.73, 41.59, -3.2)),
    "41": ("Sevilla", (36.84, -6.54, 38.2, -4.65)),
    "42": ("Soria", (41.05, -3.56, 42.15, -1.77)),
    "43": ("Tarragona", (40.52, 0.15, 41.59, 1.66)),
    "44": ("Teruel", (39.84, -1.81, 41.36, 0.3)),
    "45": ("Toledo", (39.25, -5.41, 40.32, -2.9)),
    "46": ("València / Valencia", (38.68, -1.53, 40.22, -0.02)),
    "47": ("Valladolid", (41.09, -5.53, 42.32, -3.98)),
    "48": ("Bizkaia", (42.96, -3.46, 43.46, -2.41)),
    "49": ("Zamora", (41.11, -7.04, 42.26, -5.22)),
    "50": ("Zaragoza", (40.93, -2.18, 42.75, 0.39)),
    "51": ("Ceuta", (35.87, -5.43, 35.92, -5.27)),
    "52": ("Melilla", (35.26, -2.98, 35.33, -2.92)),
}


def parse(raw: str) -> frozenset[str] | None:
    """INE codes from "30", "3,46" or "all" (None: the whole country)."""
    codes = [c.strip() for c in raw.split(",") if c.strip()]
    if any(c.lower() == "all" for c in codes):
        return None
    out = set()
    for code in codes:
        code = code.zfill(2)
        if code not in PROVINCES:
            raise ValueError(f"{code!r} is not an INE province code (01 to 52, or all)")
        out.add(code)
    return frozenset(out)


def boxes(codes: frozenset[str] | None) -> list[Box]:
    """The boxes that cover ``codes`` (every province, the islands, Ceuta and
    Melilla when None), in code order."""
    return [box for code, (_, box) in sorted(PROVINCES.items()) if codes is None or code in codes]
