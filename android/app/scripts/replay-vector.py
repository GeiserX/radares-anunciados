#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Print one `adb emu geo fix` command per fix of a route vector, with a sleep between them that follows the
vector's own timestamps, so `python3 replay-vector.py <vector.json> | sh` drives an emulator along the route.

`geo fix` takes longitude first, then latitude, altitude, satellites and speed in knots."""
import json
import sys
from datetime import datetime

vector = json.load(open(sys.argv[1]))
previous = None
for fix in vector["fixes"]:
    at = datetime.fromisoformat(fix["t"])
    if previous is not None:
        print(f"sleep {max(0.0, (at - previous).total_seconds()):.2f}")
    previous = at
    knots = (fix.get("speed") or 0.0) * 1.943844
    print(f"adb emu geo fix {fix['lon']} {fix['lat']} 650 8 {knots:.2f}")
