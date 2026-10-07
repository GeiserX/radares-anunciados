#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drive the iOS Simulator past a radar and print what the app logged (design, section 10).
#
#   scripts/sim-drive.sh <udid> <target> <km/h> <same|opposite> [options]
#
#   <target>   a feature id in Tests/RadaresCoreTests/Fixtures/feed-sample.geojson, or "lat,lon"
#   same       approach the target along its heading; opposite: approach it from the other side
#
# Options
#   --heading <deg>        the road heading at the target; default: the feature's bearing, the chord bearing of a
#                          LineString, else 90 (east)
#   --app <path.app>       install this build first (xcodebuild ... -derivedDataPath <dd>; the app is under
#                          <dd>/Build/Products/Debug-iphonesimulator/RadaresAnunciados.app)
#   --probe                do not pass -StartDriveForTest: let the significant-change delivery wake the idle app and
#                          watch the probe decide (idle -> probing -> driving)
#   --state-machine-only   pass -StateMachineOnlyForTest 1: no engine, no surfaces (while those lanes are stubs)
#   --no-live-activity     pass -NoLiveActivity 1 and -ProvisionalNotifications 1: the Time Sensitive notification
#                          instead of the activity (the Simulator cannot grant notifications; provisional
#                          authorization needs no prompt and delivers at the Time Sensitive level)
#   --before <m>           metres before the target the route starts (default 3000)
#   --after <m>            metres past the target the route ends (default 1000)
#   --settle <s>           extra seconds to wait after the route ends (default 15)
#
# Needs a booted simulator. Mutes the Mac first: the app may speak.

set -euo pipefail

usage() { sed -n '4,25p' "$0"; exit 2; }
[ $# -ge 4 ] || usage

UDID=$1; TARGET=$2; KMH=$3; SIDE=$4; shift 4
HEADING=""; APP=""; PROBE=0; SMO=0; NOLA=0; BEFORE=3000; AFTER=1000; SETTLE=15
while [ $# -gt 0 ]; do
  case $1 in
    --heading) HEADING=$2; shift 2 ;;
    --app) APP=$2; shift 2 ;;
    --probe) PROBE=1; shift ;;
    --state-machine-only) SMO=1; shift ;;
    --no-live-activity) NOLA=1; shift ;;
    --before) BEFORE=$2; shift 2 ;;
    --after) AFTER=$2; shift 2 ;;
    --settle) SETTLE=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; usage ;;
  esac
done
case $SIDE in same|opposite) ;; *) echo "fourth argument must be same or opposite" >&2; usage ;; esac

BUNDLE=io.github.geiserx.radares
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE=$ROOT/Tests/RadaresCoreTests/Fixtures/feed-sample.geojson
MPS=$(python3 -c "print(round($KMH / 3.6, 2))")

# The route: start BEFORE metres behind the gate along the approach heading, end AFTER metres past it. For a
# LineString the gate is the near vertex and "past" means past the far vertex, so the whole stretch is driven.
ROUTE=$(python3 - "$FIXTURE" "$TARGET" "$SIDE" "$HEADING" "$BEFORE" "$AFTER" <<'EOF'
import json, math, sys
fixture, target, side, heading, before, after = sys.argv[1:7]
before, after = float(before), float(after)

def bearing(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[1], a[0], b[1], b[0]))
    y = math.sin(lo2 - lo1) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(lo2 - lo1)
    return (math.degrees(math.atan2(y, x)) + 360) % 360

def offset(p, brg, metres):
    r = 6371000.0
    la1, lo1, b = math.radians(p[1]), math.radians(p[0]), math.radians(brg)
    d = metres / r
    la2 = math.asin(math.sin(la1) * math.cos(d) + math.cos(la1) * math.sin(d) * math.cos(b))
    lo2 = lo1 + math.atan2(math.sin(b) * math.sin(d) * math.cos(la1), math.cos(d) - math.sin(la1) * math.sin(la2))
    return [math.degrees(lo2), math.degrees(la2)]

if "," in target and target.replace(",", "").replace(".", "").replace("-", "").isdigit():
    lat, lon = map(float, target.split(","))
    first, last, feat_bearing = [lon, lat], None, None
else:
    feats = [f for f in json.load(open(fixture))["features"] if f.get("id") == target]
    if not feats:
        sys.exit(f"target {target!r} not in {fixture}")
    g = feats[0]["geometry"]
    coords = g["coordinates"]
    first, last = (coords, None) if g["type"] == "Point" else (coords[0], coords[-1])
    d = feats[0]["properties"].get("direction")
    try:
        feat_bearing = float(d) % 360
    except (TypeError, ValueError):
        feat_bearing = None

if heading:
    h = float(heading)
elif last is not None:
    h = bearing(first, last)
elif feat_bearing is not None:
    h = feat_bearing
else:
    h = 90.0

gate, far = (first, last) if side == "same" else ((last or first), (first if last is not None else None))
if side == "opposite":
    h = (bearing(gate, far) if far is not None else (h + 180)) % 360

start = offset(gate, (h + 180) % 360, before)
end = offset(far if far is not None else gate, h, after)
pts = [start, gate] + ([far] if far is not None else []) + [end]
total = 0.0
for a, b in zip(pts, pts[1:]):
    la1, lo1, la2, lo2 = map(math.radians, (a[1], a[0], b[1], b[0]))
    hav = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    total += 2 * 6371000.0 * math.asin(math.sqrt(hav))
print(f"{h:.1f}")
print(f"{total:.0f}")
for p in pts:
    print(f"{p[1]:.6f},{p[0]:.6f}")
EOF
)
HEADING_USED=$(echo "$ROUTE" | sed -n 1p)
LENGTH=$(echo "$ROUTE" | sed -n 2p)
WAYPOINTS=$(echo "$ROUTE" | sed -n '3,$p' | tr '\n' ' ')
DURATION=$(python3 -c "print(int($LENGTH / $MPS) + $SETTLE)")

echo "target $TARGET, $SIDE, heading $HEADING_USED, $KMH km/h ($MPS m/s), route $LENGTH m, about $DURATION s"
echo "waypoints: $WAYPOINTS"

# Mute for the run and put the Mac back the way it was, on success and on an early exit; the route stops too.
WAS_MUTED=$(osascript -e 'output muted of (get volume settings)' 2>/dev/null || echo true)
osascript -e 'set volume output muted true' >/dev/null 2>&1 || true
cleanup() {
  xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true
  osascript -e "set volume output muted $WAS_MUTED" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl bootstatus "$UDID" -b >/dev/null

if [ -n "$APP" ]; then
  xcrun simctl install "$UDID" "$APP"
fi
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true
xcrun simctl privacy "$UDID" grant location-always "$BUNDLE"
# Onboarding sets wantsAlways; the script stands in for it so the session and the wake-ups come up. The
# state-machine flag goes into the app's defaults too, not only the launch arguments: the Simulator relaunches the
# app on its own for a significant-change delivery, and a system launch carries no arguments. The app reads the
# plist inside its data container; `defaults write <bundle id>` lands in a file the app ignores, so write the path.
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)
PREFS="$CONTAINER/Library/Preferences/$BUNDLE.plist"
xcrun simctl spawn "$UDID" defaults write "$PREFS" wantsAlways -bool true
if [ "$SMO" -eq 1 ]; then
  xcrun simctl spawn "$UDID" defaults write "$PREFS" StateMachineOnlyForTest -bool true
else
  xcrun simctl spawn "$UDID" defaults delete "$PREFS" StateMachineOnlyForTest >/dev/null 2>&1 || true
fi
# Every run is one drive from idle: a drive persisted by an earlier run would be resumed at launch instead (the
# relaunch path has its own run in docs/VERIFY.md).
xcrun simctl spawn "$UDID" defaults delete "$PREFS" drive.persisted >/dev/null 2>&1 || true

ARGS=()
[ "$PROBE" -eq 1 ] || ARGS+=(-StartDriveForTest 1)
[ "$NOLA" -eq 1 ] && ARGS+=(-NoLiveActivity 1 -ProvisionalNotifications 1)
START_EPOCH=$(date +%s)
# Launch first, then place the car: a simulated position set before the launch makes the system launch the app in
# the background for significant change, and that process would not see the launch arguments.
xcrun simctl launch "$UDID" "$BUNDLE" ${ARGS[@]+"${ARGS[@]}"} >/dev/null
sleep 2
xcrun simctl location "$UDID" set "$(echo "$WAYPOINTS" | cut -d' ' -f1)"
sleep 2

# shellcheck disable=SC2086
xcrun simctl location "$UDID" start --speed="$MPS" --interval=1 $WAYPOINTS
echo "driving for $DURATION s..."
sleep "$DURATION"
xcrun simctl location "$UDID" clear >/dev/null 2>&1 || true

EVENTS="$CONTAINER/Library/Application Support/Radares/events.jsonl"
echo
echo "== events.jsonl: alert and state rows"
if [ -s "$EVENTS" ]; then
  grep -E 'launch|sessionTaken|wakeup|probe|driveStarted|drivePaused|driveResumed|driveEnded|alert|passed|stretchEntered|stretchExited|monitorEvent|notificationPosted|speech|activityStarted|activityFailed' "$EVENTS" || echo "(no matching rows)"
else
  echo "(empty or missing: $EVENTS)"
fi

echo
echo "== unified log, subsystem $BUNDLE, since launch (the same rows, from the process)"
xcrun simctl spawn "$UDID" log show --start "$(date -r "$START_EPOCH" '+%Y-%m-%d %H:%M:%S')" \
  --predicate "subsystem == \"$BUNDLE\"" --style compact --info 2>/dev/null \
  | grep -vE 'update speed' | tail -n 80
