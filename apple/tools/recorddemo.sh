#!/bin/sh
# Record the App Review video's screen half: builds a debug Drift for the booted iPhone
# simulator, launches it with -DriftDemo YES (on, mode changes, temperature, off) and
# records the screen to the given file. The simulator must already be set up with the AC.
#
# Usage: tools/recorddemo.sh [output.mp4]
set -eu
cd "$(dirname "$0")/.."
output="${1:-$HOME/Desktop/drift-demo.mp4}"
sim="${DRIFT_SIM:-C0E59A0B-B73E-45A2-BB4C-C978319B4EEB}"
build="${TMPDIR:-/tmp}/drift-demo-build"

xcrun simctl boot "$sim" 2>/dev/null || true
open -a Simulator 2>/dev/null || true
xcodebuild -quiet -project Drift.xcodeproj -scheme Drift -configuration Debug \
  -destination "id=$sim" -derivedDataPath "$build" build
xcrun simctl install "$sim" "$build/Build/Products/Debug-iphonesimulator/Drift.app"
xcrun simctl status_bar "$sim" override --time 9:41 --batteryState charged --batteryLevel 100
xcrun simctl terminate "$sim" cc.hafa.Drift 2>/dev/null || true

xcrun simctl io "$sim" recordVideo --force "$output" &
recorder=$!
sleep 2
xcrun simctl launch "$sim" cc.hafa.Drift -DriftDemo YES
# the demo takes about 50 seconds once connected
sleep 60
kill -INT "$recorder"
wait "$recorder" || true
xcrun simctl status_bar "$sim" clear
echo "saved $output"
