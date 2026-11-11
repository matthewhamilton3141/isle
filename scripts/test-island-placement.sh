#!/bin/zsh
# Builds and runs the island placement tests (scripts/island-placement-tests.swift)
# against the three files that decide how the island leaves its notch and
# comes back: the press-and-hold (IslandHold.swift), where it may be put and
# what's remembered (IslandPlacement.swift), and the path of the line round
# it (DetachTraceGeometry.swift). No app, no window, no pointer, no clock.
set -e
ROOT=${0:A:h:h}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/isle-island-placement.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
# Top-level test code has to be the module's main.swift.
cp $ROOT/scripts/island-placement-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  $ROOT/Isle/Notch/IslandHold.swift \
  $ROOT/Isle/Notch/IslandPlacement.swift \
  $ROOT/Isle/Notch/DetachTraceGeometry.swift \
  $OUT/main.swift \
  -o $OUT/run
$OUT/run
