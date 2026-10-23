#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fails unless a built RadaresAnunciados.app is signed with the entitlements the car-screen warning needs.
#
#   scripts/check-entitlements.sh path/to/RadaresAnunciados.app
#
# Checks the entitlements in the code signature and, when the app embeds a provisioning profile (a device or App
# Store build), the profile's own Entitlements too: a profile made before a capability was enabled is the usual
# way a key goes missing. PlistBuddy, not plutil -extract, because the key names contain dots.
set -euo pipefail

app=${1:?usage: check-entitlements.sh path/to/App.app}
keys=(
  com.apple.developer.carplay-driving-task
  com.apple.developer.usernotifications.time-sensitive
)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check() { # check <plist> <what>
  local plist=$1 what=$2 missing=0 key value
  for key in "${keys[@]}"; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)
    if [ "$value" = true ]; then
      echo "ok: $what has $key"
    else
      echo "::error::$what lacks $key"
      missing=1
    fi
  done
  return $missing
}

status=0
codesign -d --entitlements - --xml "$app" > "$work/signed.plist" 2>/dev/null || true
if [ ! -s "$work/signed.plist" ]; then
  echo "::error::$app has no entitlements in its signature"
  exit 1
fi
check "$work/signed.plist" "the signature" || status=1

if [ -f "$app/embedded.mobileprovision" ]; then
  security cms -D -i "$app/embedded.mobileprovision" > "$work/profile.plist"
  /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$work/profile.plist" > "$work/profile-entitlements.plist"
  check "$work/profile-entitlements.plist" "the provisioning profile" || status=1
fi
exit $status
