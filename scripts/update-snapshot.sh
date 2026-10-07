#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Refreshes the feed bundled with the app (design 5.3), so the first drive after install works offline.
# Downloads the live feed.geojson, refuses a file that does not look like the feed, and writes the sidecar
# feed-snapshot.date with the feed's Last-Modified time in ISO 8601 (UTC). The release workflow fails when
# that date is older than 30 days, and the app uses it as the feed's age until the first download.
#
# Usage: scripts/update-snapshot.sh
set -euo pipefail

url="https://geiserx.github.io/radares-anunciados-ha/feed.geojson"
min_features=2000
dest_dir="$(cd "$(dirname "$0")/.." && pwd)/App/Sources/Resources"
feed="$dest_dir/feed-snapshot.geojson"
date_file="$dest_dir/feed-snapshot.date"

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
