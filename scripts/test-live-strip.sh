#!/bin/zsh
# Builds and runs the live strip's rule tests (scripts/live-strip-tests.swift)
# against Isle/Notch/LiveStrip.swift and the face list alone. No app, no window.
set -e
ROOT=${0:A:h:h}
OUT=${TMPDIR:-/tmp}/isle-live-strip-tests
mkdir -p $OUT
# Top-level test code has to be the module's main.swift.
cp $ROOT/scripts/live-strip-tests.swift $OUT/main.swift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcrun swiftc -swift-version 5 -O \
  $ROOT/Isle/Notch/LiveStrip.swift \
  $ROOT/Isle/Notch/IsleTab.swift \
  $OUT/main.swift \
  -o $OUT/run
$OUT/run
