#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Refreshes the feed bundled with the app (design 5.3), so the first drive after install works offline.
# Downloads the live feed.geojson, refuses a file that does not look like the feed, and writes the sidecar
# feed-snapshot.date with the feed's Last-Modified time in ISO 8601 (UTC). The release workflow fails when
# that date is older than 30 days, and the app uses it as the feed's age until the first download.
# Also downloads the road sidecar roads.json into roads-snapshot.json, refusing a file that fails the app's
# RoadsValidator rules. A 404 (the publisher has not shipped it yet) leaves the road snapshot as it is: the app runs
# the straight-line rules for every radar without one.
#
# Usage: scripts/update-snapshot.sh
set -euo pipefail

url="https://geiserx.github.io/radares-anunciados-ha/feed.geojson"
min_features=2000
dest_dir="$(cd "$(dirname "$0")/.." && pwd)/App/Sources/Resources"
feed="$dest_dir/feed-snapshot.geojson"
date_file="$dest_dir/feed-snapshot.date"
roads_url="https://geiserx.github.io/radares-anunciados-ha/roads.json"
roads_file="$dest_dir/roads-snapshot.json"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl --fail --silent --show-error --location --compressed --max-time 60 \
  --dump-header "$work/headers" --output "$work/feed.geojson" "$url"

# The app's FeedValidator checks: a FeatureCollection, enough features, id, kind and geometry on every
# feature, at least one fixed radar.
python3 -I - "$work/feed.geojson" "$min_features" <<'PY'
import json, sys
path, minimum = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
if doc.get("type") != "FeatureCollection":
    sys.exit("not a FeatureCollection")
features = doc.get("features") or []
if len(features) < minimum:
    sys.exit(f"only {len(features)} features, need {minimum}")
for index, feature in enumerate(features):
    properties = feature.get("properties") if isinstance(feature, dict) else None
    if not isinstance(properties, dict) or "id" not in feature or "geometry" not in feature or "kind" not in properties:
        sys.exit(f"feature {index} has no id, kind or geometry")
if not any((f.get("properties") or {}).get("kind") == "fixed" for f in features):
    sys.exit("no fixed radar")
print(f"{len(features)} features")
PY

last_modified=$(awk -F': ' 'tolower($1) == "last-modified" {sub(/\r$/, "", $2); print $2}' "$work/headers" | tail -1)
# The feed's own time, never the download time: a snapshot of unknown age must not pass the 30-day gate.
if [ -z "$last_modified" ]; then
  echo "no Last-Modified header: the feed's age is unknown, snapshot not replaced" >&2
  exit 1
fi
generated=$(python3 -I -c 'import sys, email.utils; d = email.utils.parsedate_to_datetime(sys.argv[1]); print(d.strftime("%Y-%m-%dT%H:%M:%SZ"))' "$last_modified")

mkdir -p "$dest_dir"
mv "$work/feed.geojson" "$feed"
printf '%s\n' "$generated" > "$date_file"
echo "snapshot $(wc -c < "$feed" | tr -d ' ') bytes, generated $generated"

# The road sidecar. curl writes the status code; anything but 200 and 404 is an error.
status=$(curl --silent --show-error --location --compressed --max-time 60 --output "$work/roads.json" --write-out '%{http_code}' "$roads_url")
if [ "$status" = 404 ]; then
  echo "no roads.json published yet: road snapshot left as it is" >&2
  exit 0
fi
if [ "$status" != 200 ]; then
  echo "roads.json: HTTP $status, road snapshot not replaced" >&2
  exit 1
fi
# The app's RoadsValidator checks: at most 4,000,000 bytes, version 1, at least 500 entries, every polyline
# (approaches, line, gates) decodes to at least two distinct vertices.
python3 -I - "$work/roads.json" <<'PY'
import json, os, sys
path = sys.argv[1]
if os.path.getsize(path) > 4_000_000:
    sys.exit("roads.json is over 4,000,000 bytes")
with open(path, encoding="utf-8") as f:
    doc = json.load(f)
if doc.get("version") != 1:
    sys.exit(f"roads.json version {doc.get('version')}, need 1")
features = doc.get("features") or {}
if len(features) < 500:
    sys.exit(f"only {len(features)} roads entries, need 500")

def decode(s):
    coords, lat, lon, i = [], 0, 0, 0
    while i < len(s):
        vals = []
        for _ in range(2):
            result = shift = 0
            while True:
                if i >= len(s):
                    raise ValueError("cut inside a value")
                b = ord(s[i]) - 63
                i += 1
                if b < 0 or b > 63:
                    raise ValueError("byte outside the alphabet")
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            vals.append(~(result >> 1) if result & 1 else result >> 1)
        lat += vals[0]
        lon += vals[1]
        coords.append((lat, lon))
    return coords

for fid, entry in features.items():
    strings = [a["polyline"] for a in entry.get("approaches") or []]
    if entry.get("line"):
        strings.append(entry["line"])
    gates = entry.get("gates") or {}
    strings += [a["polyline"] for a in (gates.get("start") or []) + (gates.get("end") or [])]
    if not strings:
        sys.exit(f"{fid} has no polyline")
    for s in strings:
        try:
            coords = decode(s)
        except ValueError as e:
            sys.exit(f"{fid}: {e}")
        if len(set(coords)) < 2:
            sys.exit(f"{fid}: a polyline with fewer than two distinct vertices")
print(f"{len(features)} roads entries")
PY
mv "$work/roads.json" "$roads_file"
echo "road snapshot $(wc -c < "$roads_file" | tr -d ' ') bytes"
